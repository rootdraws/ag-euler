import type { Ref, ComputedRef } from 'vue'
import { useAccount } from '@wagmi/vue'
import { formatUnits } from 'viem'
import { FixedPoint } from '~/utils/fixed-point'
import { logWarn } from '~/utils/errorHandling'
import { useModal } from '~/components/ui/composables/useModal'
import { OperationReviewModal } from '#components'
import { useToast } from '~/components/ui/composables/useToast'
import { getNetAPY } from '~/entities/vault'
import { getAssetUsdValue, getAssetUsdValueOrZero } from '~/services/pricing/priceProvider'
import type { AccountBorrowPosition } from '~/entities/account'
import type { TxPlan } from '~/entities/txPlan'
import { valueToNano } from '~/utils/crypto-utils'
import { trimTrailingZeros } from '~/utils/string-utils'
import { amountToPercent, percentToAmountNano } from '~/utils/repayUtils'

interface UseWalletRepayOptions {
  position: Ref<AccountBorrowPosition | undefined>
  borrowVault: ComputedRef<AccountBorrowPosition['borrow'] | undefined>
  collateralVault: ComputedRef<AccountBorrowPosition['collateral'] | undefined>
  formTab: Ref<string>
  walletBalance: Ref<bigint>
  plan: Ref<TxPlan | null>
  isSubmitting: Ref<boolean>
  isPreparing: Ref<boolean>
  clearSimulationError: () => void
  runSimulation: (plan: TxPlan) => Promise<boolean>
  netAPY: Ref<number>
  collateralSupplyApy: ComputedRef<number>
  borrowApy: ComputedRef<number>
  collateralSupplyRewardApy: ComputedRef<number>
  borrowRewardApy: ComputedRef<number>
}

export const useWalletRepay = (options: UseWalletRepayOptions) => {
  const {
    position,
    borrowVault,
    collateralVault,
    formTab,
    walletBalance,
    plan,
    isSubmitting,
    isPreparing,
    clearSimulationError,
    runSimulation,
    netAPY,
    collateralSupplyApy,
    borrowApy,
    collateralSupplyRewardApy,
    borrowRewardApy,
  } = options

  const router = useRouter()
  const modal = useModal()
  const { error } = useToast()
  const { buildRepayPlan, buildFullRepayPlan, executeTxPlan } = useEulerOperations()
  const { refreshAllPositions } = useEulerAccount()
  const { eulerLensAddresses } = useEulerAddresses()
  const { isConnected, address } = useAccount()

  const amount = ref('')
  const walletRepayPercent = ref(0)
  const balance = ref(0n)
  const estimateNetAPY = ref(0)
  const estimateUserLTV = ref(0n)
  const estimateHealth = ref(0n)
  const estimatesError = ref('')
  const isEstimatesLoading = ref(false)

  const amountFixed = computed(() => FixedPoint.fromValue(
    valueToNano(amount.value || '0', borrowVault.value?.decimals),
    Number(borrowVault.value?.decimals),
  ))
  const borrowedFixed = computed(() => FixedPoint.fromValue(position.value?.borrowed || 0n, position.value?.borrow.decimals || 18))
  const suppliedFixed = computed(() => FixedPoint.fromValue(position.value?.supplied || 0n, position.value?.collateral.decimals || 18))
  const priceFixed = computed(() => FixedPoint.fromValue(position.value?.price || 0n, 18))
  const balanceFixed = computed(() => FixedPoint.fromValue(balance.value, borrowVault.value?.decimals || 18))

  const isSubmitDisabled = computed(() => {
    if (!isConnected.value) return false
    return !(+amount.value) || !!estimatesError.value || isEstimatesLoading.value
  })

  const updateBalance = async () => {
    if (!isConnected.value || !position.value || !borrowVault.value) {
      balance.value = 0n
      return
    }
    const borrowedUsd = (await getAssetUsdValue(position.value.borrowed, borrowVault.value, 'off-chain')) ?? 0.01
    const factor = Math.pow(10, 2)
    const borrowedRounded = Math.ceil(borrowedUsd * factor) / factor
    balance.value = FixedPoint.fromValue(valueToNano(borrowedRounded, 4), 4)
      .div(FixedPoint.fromValue(borrowVault.value.liabilityPriceInfo.amountOutMid, Number(borrowVault.value.decimals)))
      .value
  }

  const submit = async () => {
    if (isPreparing.value || isSubmitting.value || !position.value || !borrowVault.value || !collateralVault.value) {
      return
    }

    isPreparing.value = true
    try {
      const amountNano = valueToNano(amount.value || '0', borrowVault.value.asset.decimals)
      const shouldFullRepay = balance.value <= amountNano

      try {
        plan.value = shouldFullRepay
          ? await buildFullRepayPlan(
            borrowVault.value.address,
            borrowVault.value.asset.address,
            amountNano,
            position.value.subAccount,
            position.value.collaterals ?? [collateralVault.value.address],
            { includePermit2Call: false },
          )
          : await buildRepayPlan(
            borrowVault.value.address,
            borrowVault.value.asset.address,
            amountNano,
            position.value.subAccount,
            { includePermit2Call: false },
          )
      }
      catch (e) {
        logWarn('walletRepay/buildPlan', e)
        plan.value = null
      }

      if (plan.value) {
        const ok = await runSimulation(plan.value)
        if (!ok) return
      }

      modal.open(OperationReviewModal, {
        props: {
          type: 'repay',
          asset: position.value!.borrow.asset,
          amount: amount.value,
          plan: plan.value || undefined,
          subAccount: position.value?.subAccount,
          hasBorrows: (position.value?.borrowed || 0n) > 0n,
          onConfirm: () => {
            setTimeout(() => {
              send()
            }, 400)
          },
        },
      })
    }
    finally {
      isPreparing.value = false
    }
  }

  const send = async () => {
    try {
      isSubmitting.value = true
      if (!position.value || !borrowVault.value || !collateralVault.value) return

      const amountNano = valueToNano(amount.value, borrowVault.value.asset.decimals)
      const isFullRepay = balance.value <= amountNano
      const txPlan = isFullRepay
        ? await buildFullRepayPlan(
          borrowVault.value.address,
          borrowVault.value.asset.address,
          amountNano,
          position.value.subAccount,
          position.value.collaterals ?? [collateralVault.value.address],
          { includePermit2Call: true },
        )
        : await buildRepayPlan(
          borrowVault.value.address,
          borrowVault.value.asset.address,
          amountNano,
          position.value.subAccount,
          { includePermit2Call: true },
        )
      await executeTxPlan(txPlan)

      modal.close()
      refreshAllPositions(eulerLensAddresses.value, address.value as string)
      setTimeout(() => {
        router.replace('/portfolio')
      }, 400)
    }
    catch (e) {
      error('Transaction failed')
      logWarn('walletRepay/send', e)
    }
    finally {
      isSubmitting.value = false
    }
  }

  const updateEstimates = useDebounceFn(async () => {
    clearSimulationError()
    estimatesError.value = ''
    if (!position.value || !collateralVault.value || !borrowVault.value) return
    try {
      if (walletBalance.value < valueToNano(amount.value, borrowVault.value.decimals)) {
        throw new Error('Not enough balance')
      }
      if (borrowedFixed.value.lt(amountFixed.value)) {
        throw new Error('You repaying more than required')
      }
      const [supplyUsd, borrowUsd] = await Promise.all([
        getAssetUsdValueOrZero((position.value.supplied || 0n), collateralVault.value, 'off-chain'),
        getAssetUsdValueOrZero((position.value.borrowed || 0n) - valueToNano(amount.value, borrowVault.value.decimals), borrowVault.value, 'off-chain'),
      ])
      estimateNetAPY.value = getNetAPY(
        supplyUsd,
        collateralSupplyApy.value,
        borrowUsd,
        borrowApy.value,
        collateralSupplyRewardApy.value || null,
        borrowRewardApy.value || null,
      )
      const collateralValue = suppliedFixed.value.mul(priceFixed.value)
      const userLtvFixed = collateralValue.isZero()
        ? FixedPoint.fromValue(0n, 18)
        : (borrowedFixed.value.sub(amountFixed.value))
            .div(collateralValue)
            .mul(FixedPoint.fromValue(100n, 0))
      estimateUserLTV.value = userLtvFixed.value
      estimateHealth.value = (userLtvFixed.isZero() || userLtvFixed.isNegative())
        ? 0n
        : FixedPoint.fromValue(position.value!.liquidationLTV, 2).div(userLtvFixed).value

      if (userLtvFixed.gte(FixedPoint.fromValue(position.value!.liquidationLTV, 2))) {
        throw new Error('Not enough liquidity for the vault, LTV is too large')
      }
    }
    catch (e: unknown) {
      logWarn('walletRepay/estimates', e)
      estimateNetAPY.value = netAPY.value
      estimateUserLTV.value = position.value!.userLTV
      estimateHealth.value = position.value!.health
      estimatesError.value = (e as { message: string }).message
    }
    finally {
      isEstimatesLoading.value = false
    }
  }, 500)

  const onWalletRepayPercentInput = () => {
    clearSimulationError()
    if (!borrowVault.value || !position.value) {
      amount.value = ''
      walletRepayPercent.value = 0
      return
    }
    const currentDebt = position.value.borrowed || 0n
    if (currentDebt <= 0n) {
      amount.value = ''
      return
    }
    const amountNano = percentToAmountNano(walletRepayPercent.value, currentDebt)
    amount.value = trimTrailingZeros(formatUnits(amountNano, Number(borrowVault.value.asset.decimals)))
  }

  // Watch amount changes: sync percent slider + trigger estimates
  watch(amount, () => {
    clearSimulationError()
    if (formTab.value !== 'wallet') return

    if (position.value && borrowVault.value) {
      const currentDebt = position.value.borrowed || 0n
      if (currentDebt > 0n) {
        let amountNano = 0n
        try {
          amountNano = valueToNano(amount.value || '0', borrowVault.value.asset.decimals)
        }
        catch {
          amountNano = 0n
        }
        walletRepayPercent.value = amountToPercent(amountNano, currentDebt)
      }
      else {
        walletRepayPercent.value = 0
      }
    }
    if (!collateralVault.value) return
    if (!isEstimatesLoading.value) {
      isEstimatesLoading.value = true
    }
    updateEstimates()
  })

  const initEstimates = (currentNetAPY: number, currentUserLTV: bigint, currentHealth: bigint) => {
    estimateNetAPY.value = currentNetAPY
    estimateUserLTV.value = currentUserLTV
    estimateHealth.value = currentHealth
  }

  const resetOnTabSwitch = () => {
    amount.value = ''
    walletRepayPercent.value = 0
  }

  return {
    amount,
    walletRepayPercent,
    balance,
    estimateNetAPY,
    estimateUserLTV,
    estimateHealth,
    estimatesError,
    isEstimatesLoading,
    isSubmitDisabled,
    amountFixed,
    borrowedFixed,
    suppliedFixed,
    priceFixed,
    balanceFixed,
    updateBalance,
    submit,
    send,
    onWalletRepayPercentInput,
    initEstimates,
    resetOnTabSwitch,
  }
}
