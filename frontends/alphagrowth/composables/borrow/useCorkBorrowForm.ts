import { useAccount } from '@wagmi/vue'
import { formatUnits, type Address, erc20Abi } from 'viem'
import { logWarn } from '~/utils/errorHandling'
import { useModal } from '~/components/ui/composables/useModal'
import { OperationReviewModal } from '#components'
import { useToast } from '~/components/ui/composables/useToast'
import type { TxPlan } from '~/entities/txPlan'
import { getPublicClient } from '~/utils/public-client'
import { isForkChain } from '~/entities/forkChainMap'

const CORK_ADDRESSES = {
  vbUSDC: '0x53E82ABbb12638F09d9e624578ccB666217a765e',
  sUSDe: '0x9D39A5DE30e57443BfF2A8307A4256c8797A3497',
  cST: '0x1b42544f897b7ab236c111a4f800a54d94840688',
  refVault: '0xadF7aFDAdaA4cBb0aDAf47C7fD7a9789C0128C6b',
  cstVault: '0xd0f8aC1782d5B80f722bd6aCA4dEf8571A9ddA4c',
  borrowVault: '0x53FDab35Fd3aA26577bAc29f098084fCBAbE502f',
} as const

const VBUSDC_DECIMALS = 6
const CST_DECIMALS = 18
const SUSDE_DECIMALS = 18
const DECIMAL_NORMALIZATION = 10n ** 12n

export const useCorkBorrowForm = () => {
  const modal = useModal()
  const { error: toastError } = useToast()
  const { buildDualCollateralBorrowPlan, executeTxPlan } = useEulerOperations()
  const { address, isConnected } = useAccount()
  const { refreshAllPositions } = useEulerAccount()
  const { eulerLensAddresses, chainId: eulerChainId } = useEulerAddresses()
  const { EVM_PROVIDER_URL } = useEulerConfig()
  const { guardWithTerms } = useTermsOfUseGate()
  const router = useRouter()

  const vbUsdcAmount = ref('')
  const borrowAmount = ref('')
  const isSubmitting = ref(false)
  const isPreparing = ref(false)
  const simulationError = ref('')
  const plan = ref<TxPlan | null>(null)

  const vbUsdcBalance = ref(0n)
  const cstBalance = ref(0n)

  const vbUsdcAmountBigInt = computed(() => {
    if (!vbUsdcAmount.value) return 0n
    return valueToNano(vbUsdcAmount.value, VBUSDC_DECIMALS)
  })

  const cstAmountBigInt = computed(() => {
    return vbUsdcAmountBigInt.value * DECIMAL_NORMALIZATION
  })

  const cstAmountDisplay = computed(() => {
    if (vbUsdcAmountBigInt.value === 0n) return ''
    return formatUnits(cstAmountBigInt.value, CST_DECIMALS)
  })

  const borrowAmountBigInt = computed(() => {
    if (!borrowAmount.value) return 0n
    return valueToNano(borrowAmount.value, SUSDE_DECIMALS)
  })

  const friendlyVbUsdcBalance = computed(() =>
    nanoToValue(vbUsdcBalance.value, VBUSDC_DECIMALS),
  )
  const friendlyCstBalance = computed(() =>
    nanoToValue(cstBalance.value, CST_DECIMALS),
  )

  const hasInsufficientVbUsdc = computed(() =>
    vbUsdcAmountBigInt.value > 0n && vbUsdcAmountBigInt.value > vbUsdcBalance.value,
  )
  const hasInsufficientCst = computed(() =>
    cstAmountBigInt.value > 0n && cstAmountBigInt.value > cstBalance.value,
  )

  const errorText = computed(() => {
    if (hasInsufficientVbUsdc.value) return 'Insufficient vbUSDC balance'
    if (hasInsufficientCst.value) return 'Insufficient cST balance'
    if (vbUsdcAmountBigInt.value === 0n && borrowAmountBigInt.value > 0n) return 'Enter collateral amount'
    return ''
  })

  const canSubmit = computed(() =>
    isConnected.value
    && vbUsdcAmountBigInt.value > 0n
    && borrowAmountBigInt.value > 0n
    && !hasInsufficientVbUsdc.value
    && !hasInsufficientCst.value
    && !isSubmitting.value
    && !isPreparing.value,
  )

  const refreshBalances = async () => {
    if (!address.value || !EVM_PROVIDER_URL) return
    try {
      const client = getPublicClient(EVM_PROVIDER_URL)
      const [vb, cs] = await Promise.all([
        client.readContract({ address: CORK_ADDRESSES.vbUSDC as Address, abi: erc20Abi, functionName: 'balanceOf', args: [address.value as Address] }),
        client.readContract({ address: CORK_ADDRESSES.cST as Address, abi: erc20Abi, functionName: 'balanceOf', args: [address.value as Address] }),
      ])
      vbUsdcBalance.value = vb
      cstBalance.value = cs
    }
    catch (e) {
      console.error('[cork-borrow] refreshBalances failed:', e)
    }
  }

  const onMaxVbUsdc = () => {
    vbUsdcAmount.value = formatUnits(vbUsdcBalance.value, VBUSDC_DECIMALS)
  }

  const getSubAccount = (): Address => {
    if (!address.value) throw new Error('Wallet not connected')
    const hex = BigInt(address.value) ^ 2n
    return `0x${hex.toString(16).padStart(40, '0')}` as Address
  }

  const prepare = async () => {
    if (!canSubmit.value) return
    isPreparing.value = true
    try {
      await guardWithTerms(async () => {
        const subAccount = getSubAccount()

        try {
          plan.value = await buildDualCollateralBorrowPlan({
            refVaultAddress: CORK_ADDRESSES.refVault,
            refAssetAddress: CORK_ADDRESSES.vbUSDC,
            refAmount: vbUsdcAmountBigInt.value,
            cstVaultAddress: CORK_ADDRESSES.cstVault,
            cstAssetAddress: CORK_ADDRESSES.cST,
            cstAmount: cstAmountBigInt.value,
            borrowVaultAddress: CORK_ADDRESSES.borrowVault,
            borrowAmount: borrowAmountBigInt.value,
            subAccount,
          })
        }
        catch (e) {
          console.error('[cork-borrow] prepare: buildPlan FAILED:', e)
          logWarn('cork-borrow/buildPlan', e)
          plan.value = null
        }

        if (plan.value && !isForkChain(eulerChainId.value)) {
          const { runSimulation } = useTxPlanSimulation()
          const ok = await runSimulation(plan.value)
          if (!ok) return
        }
        modal.open(OperationReviewModal, {
          props: {
            type: 'borrow',
            asset: { address: CORK_ADDRESSES.sUSDe, symbol: 'sUSDe', name: 'Staked USDe', decimals: SUSDE_DECIMALS },
            amount: borrowAmount.value,
            plan: plan.value || undefined,
            supplyingAssetForBorrow: { address: CORK_ADDRESSES.vbUSDC, symbol: 'vbUSDC', name: 'vbUSDC', decimals: VBUSDC_DECIMALS },
            supplyingAmount: vbUsdcAmount.value,
            onConfirm: () => {
              setTimeout(() => {
                send()
              }, 400)
            },
          },
        })
      })
    }
    catch (e) {
      console.error('[cork-borrow] prepare: UNCAUGHT ERROR:', e)
      toastError('Failed to prepare transaction')
    }
    finally {
      isPreparing.value = false
    }
  }

  const send = async () => {
    try {
      isSubmitting.value = true
      const subAccount = getSubAccount()

      const txPlan = await buildDualCollateralBorrowPlan({
        refVaultAddress: CORK_ADDRESSES.refVault,
        refAssetAddress: CORK_ADDRESSES.vbUSDC,
        refAmount: vbUsdcAmountBigInt.value,
        cstVaultAddress: CORK_ADDRESSES.cstVault,
        cstAssetAddress: CORK_ADDRESSES.cST,
        cstAmount: cstAmountBigInt.value,
        borrowVaultAddress: CORK_ADDRESSES.borrowVault,
        borrowAmount: borrowAmountBigInt.value,
        subAccount,
      })

      await executeTxPlan(txPlan)
      modal.close()
      refreshAllPositions(eulerLensAddresses.value, address.value || '')
      refreshBalances()
      setTimeout(() => {
        router.replace('/portfolio')
      }, 400)
    }
    catch (e) {
      console.error('[cork-borrow] send: FAILED:', e)
      logWarn('cork-borrow/send', e)
      toastError('Transaction failed')
    }
    finally {
      isSubmitting.value = false
    }
  }

  watch(() => address.value, (addr) => {
    if (addr) refreshBalances()
  }, { immediate: true })

  return {
    vbUsdcAmount,
    borrowAmount,
    cstAmountDisplay,
    vbUsdcBalance,
    cstBalance,
    friendlyVbUsdcBalance,
    friendlyCstBalance,
    hasInsufficientVbUsdc,
    hasInsufficientCst,
    errorText,
    canSubmit,
    isSubmitting,
    isPreparing,
    simulationError,
    onMaxVbUsdc,
    prepare,
    refreshBalances,
  }
}
