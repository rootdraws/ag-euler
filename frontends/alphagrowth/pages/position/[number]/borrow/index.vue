<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { FixedPoint } from '~/utils/fixed-point'
import { useModal } from '~/components/ui/composables/useModal'
import { OperationReviewModal } from '#components'
import { useTermsOfUseGate } from '~/composables/useTermsOfUseGate'
import { useToast } from '~/components/ui/composables/useToast'
import { POLL_INTERVAL_5S_MS } from '~/entities/tuning-constants'
import { type BorrowVaultPair, getNetAPY, type VaultAsset } from '~/entities/vault'
import { getUtilisationWarning, getBorrowCapWarning } from '~/composables/useVaultWarnings'
import { getAssetUsdValueOrZero, getAssetOraclePrice, getCollateralOraclePrice, conservativePriceRatio } from '~/services/pricing/priceProvider'
import { useEulerProductOfVault } from '~/composables/useEulerLabels'
import { isAnyVaultBlockedByCountry, isVaultRestrictedByCountry } from '~/composables/useGeoBlock'
import type { AccountBorrowPosition } from '~/entities/account'
import type { TxPlan } from '~/entities/txPlan'
import { formatNumber, formatSmartAmount, formatHealthScore, trimTrailingZeros } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'

const router = useRouter()
const _route = useRoute()
const modal = useModal()
const { error } = useToast()
const { getSubmitLabel, getSubmitDisabled, guardWithTerms } = useTermsOfUseGate()
const reviewBorrowLabel = getSubmitLabel('Review Borrow')
const { buildBorrowPlan, executeTxPlan } = useEulerOperations()
const { getBorrowVaultPair, updateVault } = useVaults()
const { isConnected, address } = useAccount()
const { isPositionsLoading, isPositionsLoaded, getPositionBySubAccountIndex } = useEulerAccount()
const positionIndex = usePositionIndex()
const { fetchSingleBalance } = useWallets()
const { runSimulation, simulationError, clearSimulationError } = useTxPlanSimulation()
const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()
const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()

const priceInvert = usePriceInvert(
  () => collateralVault.value?.asset.symbol,
  () => borrowVault.value?.asset.symbol,
)

const ltv = ref(0)
const borrowAmount = ref('')
const collateralAmount = ref('')
const balance = ref(0n)
const isLoading = ref(false)
const isSubmitting = ref(false)
const isPreparing = ref(false)
const isBalanceLoading = ref(false)
const isEstimatesLoading = ref(false)
const plan = ref<TxPlan | null>(null)
const pair: Ref<BorrowVaultPair | undefined> = ref()
const health = ref()
const netAPY = ref()
const liquidationPrice = ref()
const position: Ref<AccountBorrowPosition | undefined> = ref()
const userLTV = ref(0)
const currentNetAPY = ref<number>()
const currentHealth = ref<number>()
const currentLiquidationPrice = ref<number>()
const currentUserLTV = ref(0)

const errorText = computed(() => {
  if (isBalanceLoading.value) {
    return null
  }

  const currentSupplied = position.value?.supplied || 0n
  const newCollateralAmount = valueToNano(collateralAmount.value, collateralVault.value?.asset?.decimals)
  const additionalCollateralNeeded = newCollateralAmount > currentSupplied
    ? newCollateralAmount - currentSupplied
    : 0n

  if (additionalCollateralNeeded > 0n && balance.value < additionalCollateralNeeded) {
    return 'Not enough balance'
  }
  else if ((borrowVault.value?.supply || 0n) < valueToNano(borrowAmount.value, borrowVault.value?.decimals)) {
    return 'Not enough liquidity in the vault'
  }
  return null
})
const isSubmitDisabled = computed(() => {
  if (!isConnected.value) return false

  const currentSupplied = position.value?.supplied || 0n
  const newCollateralAmount = valueToNano(collateralAmount.value, collateralVault.value?.asset?.decimals)
  const additionalCollateralNeeded = newCollateralAmount > currentSupplied
    ? newCollateralAmount - currentSupplied
    : 0n

  return (additionalCollateralNeeded > 0n && balance.value < additionalCollateralNeeded)
    || isLoading.value || !(+collateralAmount.value)
    || ((borrowVault.value?.supply || 0n) < valueToNano(borrowAmount.value, borrowVault.value?.decimals))
})
const isGeoBlocked = computed(() => {
  const addresses: string[] = []
  if (pair.value?.borrow) addresses.push(pair.value.borrow.address)
  if (pair.value?.collateral) addresses.push(pair.value.collateral.address)
  return isAnyVaultBlockedByCountry(...addresses)
})
const isBorrowRestricted = computed(() =>
  pair.value?.borrow ? isVaultRestrictedByCountry(pair.value.borrow.address) : false)
const reviewBorrowDisabled = getSubmitDisabled(computed(() => isGeoBlocked.value || isBorrowRestricted.value || isSubmitDisabled.value))
const borrowVault = computed(() => pair.value?.borrow)
const collateralVault = computed(() => pair.value?.collateral)
const borrowWarnings = computed(() => {
  if (!borrowVault.value) return []
  return [
    getUtilisationWarning(borrowVault.value, 'borrow'),
    getBorrowCapWarning(borrowVault.value),
  ]
})
const pairAssets = computed(() => [collateralVault.value?.asset, borrowVault.value?.asset])
const priceFixed = computed(() => {
  const collateralPrice = borrowVault.value && collateralVault.value
    ? getCollateralOraclePrice(borrowVault.value, collateralVault.value)
    : undefined
  const borrowPrice = borrowVault.value ? getAssetOraclePrice(borrowVault.value) : undefined
  return FixedPoint.fromValue(conservativePriceRatio(collateralPrice, borrowPrice), 18)
})
const collateralAmountFixed = computed(() => FixedPoint.fromValue(
  valueToNano(collateralAmount.value || '0', collateralVault.value?.decimals),
  Number(collateralVault.value?.decimals),
))
const borrowAmountFixed = computed(() => FixedPoint.fromValue(
  valueToNano(borrowAmount.value || '0', borrowVault.value?.decimals),
  Number(borrowVault.value?.decimals),
))
const ltvFixed = computed(() => {
  const fn = FixedPoint.fromValue(valueToNano(ltv.value, 4), 4)
  if (fn.gte(FixedPoint.fromValue(pair.value?.borrowLTV || 0n, 2))) {
    return fn.sub(FixedPoint.fromValue(100n, 4))
  }
  return fn
})
const borrowProduct = useEulerProductOfVault(computed(() => borrowVault.value?.address || ''))
const _collateralProduct = useEulerProductOfVault(computed(() => collateralVault.value?.address || ''))

const collateralSupplyRewardApy = computed(() => getSupplyRewardApy(collateralVault.value?.address || ''))
const borrowRewardApy = computed(() => getBorrowRewardApy(borrowVault.value?.address || '', collateralVault.value?.address || ''))
const collateralSupplyApy = computed(() => withIntrinsicSupplyApy(
  nanoToValue(collateralVault.value?.interestRateInfo.supplyAPY || 0n, 25),
  collateralVault.value?.asset.address,
))
const borrowApy = computed(() => withIntrinsicBorrowApy(
  nanoToValue(borrowVault.value?.interestRateInfo.borrowAPY || 0n, 25),
  borrowVault.value?.asset.address,
))

const load = async () => {
  if (!isConnected.value) {
    position.value = undefined
    return
  }
  isLoading.value = true
  position.value = getPositionBySubAccountIndex(+positionIndex)
  if (!position.value) {
    isLoading.value = false
    return
  }
  const collateralAddress = position.value.collateral.address
  const borrowAddress = position.value.borrow.address
  userLTV.value = Number(formatNumber(nanoToValue(position.value.userLTV, 18)))
  currentUserLTV.value = userLTV.value
  ltv.value = userLTV.value
  try {
    pair.value = await getBorrowVaultPair(collateralAddress as string, borrowAddress as string) as BorrowVaultPair
    // Set collateral amount from existing position supply so LTV slider and borrow input work
    const suppliedFixed = FixedPoint.fromValue(
      position.value!.supplied,
      Number(collateralVault.value!.asset.decimals),
    )
    collateralAmount.value = trimTrailingZeros(suppliedFixed.toString())
    // Fetch fresh underlying asset balance for this specific vault
    await updateBalance()
    // Compute current position values for before→after display
    const currentLtvFloat = nanoToValue(position.value!.userLTV, 18)
    currentHealth.value = currentLtvFloat <= 0
      ? Infinity
      : (Number(pair.value?.liquidationLTV || 0n) / 100) / currentLtvFloat
    currentLiquidationPrice.value = currentHealth.value < 0.1 ? Infinity : priceFixed.value.toUnsafeFloat() / currentHealth.value
    const [collUsd, borUsd] = await Promise.all([
      getAssetUsdValueOrZero(position.value!.supplied || 0, collateralVault.value!, 'off-chain'),
      getAssetUsdValueOrZero(position.value!.borrowed || 0, borrowVault.value!, 'off-chain'),
    ])
    currentNetAPY.value = getNetAPY(
      collUsd,
      collateralSupplyApy.value,
      borUsd,
      borrowApy.value,
      collateralSupplyRewardApy.value || null,
      borrowRewardApy.value || null,
    )
  }
  catch (e) {
    showError('Unable to load Vault')
    console.warn(e)
  }
  finally {
    isLoading.value = false
  }
}
const updateBalance = async () => {
  if (!isConnected.value || !collateralVault.value?.asset.address) {
    balance.value = 0n
    isBalanceLoading.value = false
    return
  }

  balance.value = await fetchSingleBalance(collateralVault.value.asset.address)
  isBalanceLoading.value = false
}
const submit = async () => {
  if (isPreparing.value || isGeoBlocked.value || isBorrowRestricted.value) return
  isPreparing.value = true
  try {
    await guardWithTerms(async () => {
      if (!borrowVault.value || !collateralVault.value) {
        return
      }

      try {
        plan.value = await buildBorrowPlan(
          collateralVault.value.address,
          collateralVault.value.asset.address,
          0n,
          borrowVault.value.address,
          valueToNano(borrowAmount.value || '0', borrowVault.value.decimals),
          position.value?.subAccount,
          { includePermit2Call: false, enabledCollaterals: position.value?.collaterals },
        )
      }
      catch (e) {
        console.warn('[OperationReviewModal] failed to build plan', e)
        plan.value = null
      }

      if (plan.value) {
        const ok = await runSimulation(plan.value)
        if (!ok) {
          return
        }
      }

      modal.open(OperationReviewModal, {
        props: {
          type: 'borrow',
          asset: borrowVault.value?.asset,
          amount: borrowAmount.value,
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
    })
  }
  finally {
    isPreparing.value = false
  }
}
const send = async () => {
  try {
    isSubmitting.value = true
    if (!collateralVault.value || !borrowVault.value || !position.value) {
      return
    }
    const txPlan = await buildBorrowPlan(
      collateralVault.value.address,
      collateralVault.value.asset.address,
      0n,
      borrowVault.value.address,
      borrowAmountFixed.value.toFormat({ decimals: Number(borrowVault.value.decimals) }).value,
      position.value.subAccount,
      { includePermit2Call: true, enabledCollaterals: position.value?.collaterals },
    )
    await executeTxPlan(txPlan)

    modal.close()
    updateBalance()
    setTimeout(() => {
      router.replace('/portfolio')
    }, 400)
  }
  catch (e) {
    console.warn(e)
    error('Transaction failed')
  }
  finally {
    isSubmitting.value = false
  }
}
const onCollateralInput = async () => {
  await nextTick()
  const result = collateralAmountFixed.value
    .mul(priceFixed.value)
    .mul(ltvFixed.value)
    .div(FixedPoint.fromValue(100n, 0)).round(Number(borrowVault.value?.decimals || 18))
    .subUnsafe(FixedPoint.fromValue(position.value?.borrowed || 0n, position.value?.borrow.decimals || 18))
  const zero = FixedPoint.fromValue(0n, Number(borrowVault.value?.decimals || 18))
  borrowAmount.value = result.lt(zero) ? zero.toString() : trimTrailingZeros(result.toString())
}
const onBorrowInput = async () => {
  await nextTick()
  if (!collateralAmount.value) {
    return
  }
  ltv.value = +borrowAmountFixed.value
    .addUnsafe(FixedPoint.fromValue(position.value?.borrowed || 0n, position.value?.borrow.decimals || 18))
    .div(collateralAmountFixed.value.mul(priceFixed.value))
    .mul(FixedPoint.fromValue(100n, 0))
    .toUnsafeFloat().toFixed(2)
}
const onLtvInput = async () => {
  await nextTick()
  onCollateralInput()
}
const updateEstimates = useDebounceFn(async () => {
  if (!pair.value) {
    return
  }
  await Promise.all([updateVault(collateralVault.value!.address), updateVault(borrowVault.value!.address)])
  try {
    health.value = ltvFixed.value.toUnsafeFloat() <= 0
      ? Infinity
      : (Number(pair.value?.liquidationLTV || 0n) / 100) / ltvFixed.value.toUnsafeFloat()
    liquidationPrice.value = health.value < 0.1 ? Infinity : priceFixed.value.toUnsafeFloat() / health.value
    const [collateralUsd, borrowUsd] = await Promise.all([
      getAssetUsdValueOrZero(+collateralAmount.value || 0, collateralVault.value!, 'off-chain'),
      getAssetUsdValueOrZero(+borrowAmount.value || 0, borrowVault.value!, 'off-chain'),
    ])
    netAPY.value = getNetAPY(
      collateralUsd,
      collateralSupplyApy.value,
      borrowUsd,
      borrowApy.value,
      collateralSupplyRewardApy.value || null,
      borrowRewardApy.value || null,
    )
  }
  catch (e) {
    console.warn(e)
    health.value = undefined
    liquidationPrice.value = undefined
    netAPY.value = undefined
  }
  finally {
    isEstimatesLoading.value = false
  }
}, 1000)

watch(isPositionsLoaded, (val) => {
  if (val) {
    load()
  }
}, { immediate: true })
watch(isConnected, () => {
  updateBalance()
})
watch(address, () => {
  updateBalance()
})
watch([collateralAmount, borrowAmount], async () => {
  clearSimulationError()
  if (!pair.value) {
    return
  }
  if (!isEstimatesLoading.value) {
    isEstimatesLoading.value = true
  }
  updateEstimates()
})

const interval = setInterval(() => {
  updateBalance()
}, POLL_INTERVAL_5S_MS)

onUnmounted(() => {
  clearInterval(interval)
})
</script>

<template>
  <VaultForm
    title="Borrow"
    :loading="isLoading || isPositionsLoading"
    class="flex flex-col gap-16"
    @submit.prevent="submit"
  >
    <template v-if="pair">
      <VaultLabelsAndAssets
        v-if="collateralVault && borrowVault"
        :vault="collateralVault"
        :pair-vault="borrowVault"
        :assets="pairAssets as VaultAsset[]"
        size="large"
      />

      <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
        <div class="flex flex-col gap-16 w-full">
          <AssetInput
            v-if="borrowVault"
            v-model="borrowAmount"
            :desc="borrowProduct.name"
            :label="`Borrow ${borrowVault.asset.symbol}`"
            :asset="borrowVault.asset"
            :vault="borrowVault"
            @input="onBorrowInput"
          />

          <UiRange
            v-model="ltv"
            label="LTV"
            :step="0.1"
            :max="Number(pair.borrowLTV / 100n)"
            :min="userLTV"
            :number-filter="(n: number) => `${formatNumber(n, 2, 0)}%`"
            @update:model-value="onLtvInput"
          />

          <UiToast
            v-if="isGeoBlocked"
            title="Region restricted"
            description="This operation is not available in your region. You can still repay existing debt."
            variant="warning"
            size="compact"
          />
          <UiToast
            v-if="!isGeoBlocked && isBorrowRestricted"
            title="Asset restricted"
            description="Borrowing this asset is not available in your region."
            variant="warning"
            size="compact"
          />
          <UiToast
            v-show="errorText"
            title="Error"
            variant="error"
            :description="errorText || ''"
            size="compact"
          />
          <UiToast
            v-if="simulationError"
            title="Error"
            variant="error"
            :description="simulationError"
            size="compact"
          />

          <VaultWarningBanner :warnings="borrowWarnings" />
        </div>

        <VaultFormInfoBlock
          v-if="pair"
          :loading="isEstimatesLoading"
          variant="card"
          class="w-full laptop:max-w-[360px]"
        >
          <SummaryRow label="Net APY">
            <SummaryValue
              :before="currentNetAPY != null ? formatNumber(currentNetAPY) : undefined"
              :after="netAPY != null ? formatNumber(netAPY) : undefined"
              suffix="%"
            />
          </SummaryRow>
          <SummaryRow label="Oracle price">
            <SummaryPriceValue
              :value="!priceFixed.isZero() ? formatSmartAmount(priceInvert.invertValue(priceFixed.toUnsafeFloat())) : undefined"
              :symbol="priceInvert.displaySymbol"
              invertible
              @invert="priceInvert.toggle"
            />
          </SummaryRow>
          <SummaryRow label="Liquidation price">
            <SummaryPriceValue
              :before="priceInvert.invertValue(currentLiquidationPrice) != null ? formatSmartAmount(priceInvert.invertValue(currentLiquidationPrice)!) : undefined"
              :after="priceInvert.invertValue(liquidationPrice) != null ? formatSmartAmount(priceInvert.invertValue(liquidationPrice)!) : undefined"
              :symbol="priceInvert.displaySymbol"
              invertible
              @invert="priceInvert.toggle"
            />
          </SummaryRow>
          <SummaryRow label="LTV">
            <SummaryValue
              :before="formatNumber(currentUserLTV)"
              :after="formatNumber(ltv)"
              suffix="%"
            />
          </SummaryRow>
          <SummaryRow label="Health score">
            <SummaryValue
              :before="currentHealth != null ? formatHealthScore(currentHealth) : undefined"
              :after="formatHealthScore(health)"
            />
          </SummaryRow>
        </VaultFormInfoBlock>

        <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
          <VaultFormSubmit
            :disabled="reviewBorrowDisabled"
            :loading="isSubmitting || isPreparing"
          >
            {{ reviewBorrowLabel }}
          </VaultFormSubmit>
        </div>
      </div>
    </template>
  </VaultForm>
</template>
