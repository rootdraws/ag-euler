<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { type Vault, type VaultAsset, getNetAPY } from '~/entities/vault'
import { getAssetUsdValueOrZero, getCollateralOraclePrice, getAssetOraclePrice, conservativePriceRatioNumber } from '~/services/pricing/priceProvider'
import { type AccountBorrowPosition, isPositionEligibleForLiquidation } from '~/entities/account'
import type { TxPlan } from '~/entities/txPlan'
import { useTermsOfUseGate } from '~/composables/useTermsOfUseGate'
import { useEulerProductOfVault } from '~/composables/useEulerLabels'
import { useModal } from '~/components/ui/composables/useModal'
import { SlippageSettingsModal } from '#components'
import { POLL_INTERVAL_5S_MS } from '~/entities/tuning-constants'
import { nanoToValue } from '~/utils/crypto-utils'
import { createRaceGuard } from '~/utils/race-guard'
import { formatNumber, formatSmartAmount, formatHealthScore } from '~/utils/string-utils'
import { useWalletRepay } from '~/composables/repay/useWalletRepay'
import { useCollateralSwapRepay } from '~/composables/repay/useCollateralSwapRepay'
import { useSavingsRepay } from '~/composables/repay/useSavingsRepay'

const _route = useRoute()
const _router = useRouter()
const modal = useModal()
const { isConnected, address } = useAccount()
const positionIndex = usePositionIndex()
const { isPositionsLoading, isPositionsLoaded, isDepositsLoaded, refreshAllPositions: _refreshAllPositions, getPositionBySubAccountIndex } = useEulerAccount()
const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()
const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()
const { eulerLensAddresses: _eulerLensAddresses } = useEulerAddresses()
const { fetchSingleBalance } = useWallets()
const { runSimulation, simulationError, clearSimulationError } = useTxPlanSimulation()
const { slippage } = useSlippage()
const { getSubmitLabel, getSubmitDisabled, guardWithTerms } = useTermsOfUseGate()

// --- Shared state ---
const isLoading = ref(false)
const isSubmitting = ref(false)
const isPreparing = ref(false)
const formTab = ref<'wallet' | 'collateral' | 'savings'>('wallet')
const plan = ref<TxPlan | null>(null)
const position: Ref<AccountBorrowPosition | undefined> = ref()
const walletBalance = ref(0n)

// --- Shared computeds ---
const borrowVault = computed(() => position.value?.borrow)
const collateralVault = computed(() => position.value?.collateral)
const assets = computed(() => [collateralVault.value?.asset, borrowVault.value?.asset])
const isEligibleForLiquidation = computed(() => isPositionEligibleForLiquidation(position.value))
const getCurrentDebt = () => position.value?.borrowed || 0n

const { name } = useEulerProductOfVault(borrowVault.value?.address || '')

const walletPriceInvert = usePriceInvert(
  () => collateralVault.value?.asset.symbol,
  () => borrowVault.value?.asset.symbol,
)

const oraclePriceRatio = computed(() => {
  if (!borrowVault.value || !collateralVault.value) return null
  const collateralPrice = getCollateralOraclePrice(borrowVault.value, collateralVault.value as Vault)
  const borrowPrice = getAssetOraclePrice(borrowVault.value)
  return conservativePriceRatioNumber(collateralPrice, borrowPrice)
})

const liquidationPrice = computed(() => {
  const health = nanoToValue(position.value?.health || 0n, 18)
  if (!oraclePriceRatio.value || health < 0.1) return null
  return oraclePriceRatio.value / health
})

// --- APYs ---
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

const netApyGuard = createRaceGuard()
const netAPY = ref(0)
watchEffect(async () => {
  if (!position.value || !collateralVault.value || !borrowVault.value) {
    netAPY.value = 0
    return
  }
  const gen = netApyGuard.next()
  const [supplyUsd, borrowUsd] = await Promise.all([
    getAssetUsdValueOrZero(position.value.supplied || 0n, collateralVault.value, 'off-chain'),
    getAssetUsdValueOrZero(position.value.borrowed ?? 0n, borrowVault.value, 'off-chain'),
  ])
  if (netApyGuard.isStale(gen)) return
  netAPY.value = getNetAPY(
    supplyUsd,
    collateralSupplyApy.value,
    borrowUsd,
    borrowApy.value,
    collateralSupplyRewardApy.value || null,
    borrowRewardApy.value || null,
  )
})

// --- Tab composables ---
const wallet = useWalletRepay({
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
})

const collateral = useCollateralSwapRepay({
  position,
  borrowVault,
  collateralVault,
  formTab,
  plan,
  isSubmitting,
  isPreparing,
  slippage,
  clearSimulationError,
  runSimulation,
  getCurrentDebt,
  isEligibleForLiquidation,
})

const savings = useSavingsRepay({
  position,
  borrowVault,
  collateralVault,
  formTab,
  plan,
  isSubmitting,
  isPreparing,
  slippage,
  oraclePriceRatio,
  clearSimulationError,
  runSimulation,
  getCurrentDebt,
  collateralSupplyApy,
  borrowApy,
})

// --- Form tabs ---
const formTabs = computed(() => {
  const tabs = [
    { label: 'From wallet', value: 'wallet' },
    { label: 'Swap collateral', value: 'collateral' },
  ]
  if (savings.savingsPositions.value.length > 0) {
    tabs.push({ label: 'From savings', value: 'savings' })
  }
  return tabs
})

// --- Submit ---
const reviewRepayLabel = getSubmitLabel('Review Repay')
const reviewRepayDisabled = getSubmitDisabled(computed(() => {
  if (formTab.value === 'wallet') return wallet.isSubmitDisabled.value
  if (formTab.value === 'savings') return savings.isSubmitDisabled.value
  return collateral.isSubmitDisabled.value
}))

const onSubmitForm = async () => {
  await guardWithTerms(async () => {
    if (formTab.value === 'wallet') {
      await wallet.submit()
    }
    else if (formTab.value === 'savings') {
      await savings.submit()
    }
    else {
      await collateral.submit()
    }
  })
}

const openSlippageSettings = () => {
  modal.open(SlippageSettingsModal)
}

// --- Load / Fetch ---
const fetchWalletBalance = async () => {
  if (!isConnected.value || !borrowVault.value?.asset.address) {
    walletBalance.value = 0n
    return
  }
  walletBalance.value = await fetchSingleBalance(borrowVault.value.asset.address)
}

const load = async () => {
  if (!isConnected.value) {
    position.value = undefined
    return
  }
  isLoading.value = true
  await until(isPositionsLoaded).toBe(true)
  await until(isDepositsLoaded).toBe(true)

  try {
    position.value = getPositionBySubAccountIndex(+positionIndex)
    await fetchWalletBalance()
    await wallet.updateBalance()
    wallet.initEstimates(netAPY.value, position.value?.userLTV || 0n, position.value?.health || 0n)
    collateral.initVault(position.value?.collateral as Vault | undefined)
    savings.initVault()
  }
  catch (e) {
    showError('Unable to load Vault')
    console.warn(e)
  }
  finally {
    isLoading.value = false
  }
}

// --- Watchers ---
watch(isPositionsLoaded, (val) => {
  if (val) load()
}, { immediate: true })

watch(isConnected, () => {
  wallet.updateBalance()
})

watch(address, () => {
  fetchWalletBalance()
  wallet.updateBalance()
})

watch(formTab, () => {
  clearSimulationError()
  wallet.resetOnTabSwitch()
  collateral.resetOnTabSwitch()
  savings.resetOnTabSwitch()
})

// --- Polling ---
const interval = setInterval(() => {
  wallet.updateBalance()
}, POLL_INTERVAL_5S_MS)

onUnmounted(() => {
  clearInterval(interval)
})
</script>

<template>
  <VaultForm
    :loading="isLoading || isPositionsLoading"
    title="Repay position"
    @submit.prevent="onSubmitForm"
  >
    <div v-if="!isConnected">
      Connect your wallet to see your positions
    </div>

    <div v-else-if="!position">
      Position not found
    </div>

    <template v-else>
      <VaultLabelsAndAssets
        :vault="position.borrow"
        :assets="assets as VaultAsset[]"
        size="large"
      />

      <UiTabs
        v-model="formTab"
        class="mb-12"
        rounded
        pills
        :list="formTabs"
      />

      <template v-if="formTab === 'wallet'">
        <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
          <div class="flex flex-col gap-16 w-full">
            <AssetInput
              v-if="position.borrow.asset"
              v-model="wallet.amount.value"
              label="Pay from wallet"
              :desc="name"
              :asset="position.borrow.asset"
              :vault="position.borrow"
              :balance="walletBalance"
              maxable
            />

            <AssetInput
              v-if="position.borrow.asset"
              v-model="wallet.amount.value"
              label="Debt to repay"
              :asset="position.borrow.asset"
              :vault="position.borrow"
              :balance="position.borrowed"
              maxable
            />

            <UiRange
              v-if="borrowVault"
              v-model="wallet.walletRepayPercent.value"
              label="Percent of debt to repay"
              :min="0"
              :max="100"
              :step="1"
              :number-filter="(n: number) => `${n}%`"
              @update:model-value="wallet.onWalletRepayPercentInput"
            />

            <UiToast
              v-show="wallet.estimatesError.value"
              title="Error"
              variant="error"
              :description="wallet.estimatesError.value"
              size="compact"
            />
            <UiToast
              v-if="simulationError"
              title="Error"
              variant="error"
              :description="simulationError"
              size="compact"
            />
          </div>

          <VaultFormInfoBlock
            v-if="collateralVault && borrowVault"
            :loading="wallet.isEstimatesLoading.value"
            variant="card"
            class="w-full laptop:max-w-[360px]"
          >
            <SummaryRow label="Net APY">
              <SummaryValue
                :before="formatNumber(netAPY)"
                :after="formatNumber(wallet.estimateNetAPY.value)"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Oracle price">
              <SummaryPriceValue
                :value="oraclePriceRatio != null ? formatSmartAmount(walletPriceInvert.invertValue(oraclePriceRatio)!) : undefined"
                :symbol="walletPriceInvert.displaySymbol"
                invertible
                @invert="walletPriceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow label="Liquidation price">
              <SummaryPriceValue
                :value="walletPriceInvert.invertValue(liquidationPrice) != null ? formatSmartAmount(walletPriceInvert.invertValue(liquidationPrice)!) : undefined"
                :symbol="walletPriceInvert.displaySymbol"
                invertible
                @invert="walletPriceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow label="LTV">
              <SummaryValue
                :before="formatNumber(nanoToValue(position.userLTV, 18))"
                :after="formatNumber(nanoToValue(wallet.estimateUserLTV.value, 18))"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Health score">
              <SummaryValue
                :before="formatHealthScore(nanoToValue(position.health, 18))"
                :after="formatHealthScore(nanoToValue(wallet.estimateHealth.value, 18))"
              />
            </SummaryRow>
          </VaultFormInfoBlock>

          <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
            <VaultFormInfoButton
              :pair="position"
              :disabled="isLoading || isSubmitting"
            >
              Pair information
            </VaultFormInfoButton>
            <VaultFormSubmit
              :disabled="reviewRepayDisabled"
              :loading="isSubmitting || isPreparing"
            >
              {{ reviewRepayLabel }}
            </VaultFormSubmit>
          </div>
        </div>
      </template>

      <template v-else-if="formTab === 'collateral'">
        <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
          <div class="flex flex-col gap-16 w-full">
            <UiToast
              v-if="isEligibleForLiquidation"
              title="Position in violation"
              variant="warning"
              description="This position is eligible for liquidation. Collateral swaps that don't fully clear the debt will fail. If repaying partially, consider repaying from your wallet instead."
              size="compact"
            />

            <AssetInput
              v-if="collateral.sourceVault.value"
              v-model="collateral.amount.value"
              label="Collateral to swap"
              :desc="collateral.sourceProduct.name"
              :asset="collateral.sourceVault.value.asset"
              :vault="collateral.sourceVault.value"
              :collateral-options="collateral.repayCollateralOptions.value"
              :balance="collateral.sourceBalance.value"
              maxable
              @input="collateral.onAmountInput"
              @change-collateral="collateral.onSourceVaultChange"
            />
            <AssetInput
              v-if="borrowVault"
              v-model="collateral.debtAmount.value"
              label="Debt to repay"
              :desc="name"
              :asset="borrowVault.asset"
              :vault="borrowVault"
              :balance="collateral.debtBalance.value"
              maxable
              @input="collateral.onDebtInput"
            />
            <UiRange
              v-if="borrowVault"
              v-model="collateral.debtPercent.value"
              label="Percent of debt to repay"
              :min="0"
              :max="100"
              :step="1"
              :number-filter="(n: number) => `${n}%`"
              @update:model-value="collateral.onPercentInput"
            />

            <SwapRouteSelector
              v-if="!collateral.isSameAsset.value"
              :items="collateral.routeItems.value"
              :selected-provider="collateral.quotes.selectedProvider.value"
              :status-label="collateral.quotes.statusLabel.value"
              :is-loading="collateral.quotes.isLoading.value"
              :empty-message="collateral.routeEmptyMessage.value"
              @select="collateral.quotes.selectProvider"
              @refresh="collateral.onRefreshQuotes"
            />

            <UiToast
              v-if="collateral.quotes.quoteError.value && !collateral.isSameAsset.value"
              title="Swap quote"
              variant="warning"
              :description="collateral.quotes.quoteError.value"
              size="compact"
            />
            <UiToast
              v-if="collateral.disabledReason.value"
              title="Cannot submit"
              variant="warning"
              :description="collateral.disabledReason.value"
              size="compact"
            />
            <UiToast
              v-if="simulationError"
              title="Error"
              variant="error"
              :description="simulationError"
              size="compact"
            />
          </div>

          <VaultFormInfoBlock
            :loading="!collateral.isSameAsset.value && collateral.quotes.isLoading.value"
            variant="card"
            class="w-full laptop:max-w-[360px]"
          >
            <SummaryRow label="ROE">
              <SummaryValue
                :before="collateral.roeBefore.value !== null ? formatNumber(collateral.roeBefore.value) : undefined"
                :after="collateral.roeAfter.value !== null && (collateral.quotes.quote.value || collateral.isSameAsset.value) ? formatNumber(collateral.roeAfter.value) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <template v-if="!collateral.isSameAsset.value">
              <SummaryRow
                label="Swap price"
                align-top
              >
                <SummaryPriceValue
                  :value="collateral.currentPrice.value ? formatSmartAmount(collateral.priceInvert.invertValue(collateral.currentPrice.value.value)) : undefined"
                  :symbol="collateral.priceInvert.displaySymbol"
                  invertible
                  @invert="collateral.priceInvert.toggle"
                />
              </SummaryRow>
            </template>
            <template v-else>
              <SummaryRow label="Transfer">
                <p class="text-p2">
                  1:1 (same asset, no slippage)
                </p>
              </SummaryRow>
            </template>
            <SummaryRow label="Liquidation price">
              <SummaryPriceValue
                :before="collateral.currentLiquidationPrice.value !== null ? formatSmartAmount(collateral.priceInvert.invertValue(collateral.currentLiquidationPrice.value)) : undefined"
                :after="collateral.nextLiquidationPrice.value !== null && (collateral.quotes.quote.value || collateral.isSameAsset.value) ? formatSmartAmount(collateral.priceInvert.invertValue(collateral.nextLiquidationPrice.value)) : undefined"
                :symbol="collateral.priceInvert.displaySymbol"
                invertible
                @invert="collateral.priceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow label="LTV">
              <SummaryValue
                :before="collateral.currentLtv.value !== null ? formatNumber(collateral.currentLtv.value) : undefined"
                :after="collateral.nextLtv.value !== null && (collateral.quotes.quote.value || collateral.isSameAsset.value) ? formatNumber(collateral.nextLtv.value) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Health score">
              <SummaryValue
                :before="collateral.currentHealth.value !== null ? formatHealthScore(collateral.currentHealth.value) : undefined"
                :after="collateral.nextHealth.value !== null && (collateral.quotes.quote.value || collateral.isSameAsset.value) ? formatHealthScore(collateral.nextHealth.value) : undefined"
              />
            </SummaryRow>
            <template v-if="!collateral.isSameAsset.value">
              <SummaryRow
                label="Swap"
                align-top
              >
                <p class="text-p2 text-right flex flex-col items-end">
                  <span>{{ collateral.summary.value ? collateral.summary.value.from : '-' }}</span>
                  <span
                    v-if="collateral.summary.value"
                    class="text-content-tertiary text-p3"
                  >
                    {{ collateral.summary.value.to }}
                  </span>
                </p>
              </SummaryRow>
              <SummaryRow label="Price impact">
                <p class="text-p2">
                  {{ collateral.priceImpact.value !== null ? `${formatNumber(collateral.priceImpact.value, 2, 2)}%` : '-' }}
                </p>
              </SummaryRow>
              <SummaryRow label="Leveraged price impact">
                <p class="text-p2">
                  {{ collateral.leveragedPriceImpact.value !== null ? `${formatNumber(collateral.leveragedPriceImpact.value, 2, 2)}%` : '-' }}
                </p>
              </SummaryRow>
              <SummaryRow label="Slippage tolerance">
                <button
                  type="button"
                  class="flex items-center gap-6 text-p2"
                  @click="openSlippageSettings"
                >
                  <span>{{ formatNumber(slippage, 2, 0) }}%</span>
                  <SvgIcon
                    name="edit"
                    class="!w-16 !h-16 text-accent-600"
                  />
                </button>
              </SummaryRow>
              <SummaryRow label="Routed via">
                <p class="text-p2 text-right">
                  {{ collateral.routedVia.value || '-' }}
                </p>
              </SummaryRow>
            </template>
          </VaultFormInfoBlock>

          <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
            <VaultFormInfoButton
              :pair="position"
              :disabled="isLoading || isSubmitting"
            >
              Pair information
            </VaultFormInfoButton>
            <VaultFormSubmit
              :disabled="reviewRepayDisabled"
              :loading="isSubmitting || isPreparing"
            >
              {{ reviewRepayLabel }}
            </VaultFormSubmit>
          </div>
        </div>
      </template>

      <template v-else-if="formTab === 'savings'">
        <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
          <div class="flex flex-col gap-16 w-full">
            <AssetInput
              v-if="savings.sourceVault.value"
              v-model="savings.amount.value"
              label="Savings to use"
              :desc="savings.sourceProduct.name"
              :asset="savings.sourceVault.value.asset"
              :vault="savings.sourceVault.value"
              :collateral-options="savings.savingsOptions.value"
              :balance="savings.sourceBalance.value"
              maxable
              @input="savings.onAmountInput"
              @change-collateral="savings.onSourceVaultChange"
            />
            <AssetInput
              v-if="borrowVault"
              v-model="savings.debtAmount.value"
              label="Debt to repay"
              :desc="name"
              :asset="borrowVault.asset"
              :vault="borrowVault"
              :balance="savings.debtBalance.value"
              maxable
              @input="savings.onDebtInput"
            />
            <UiRange
              v-if="borrowVault"
              v-model="savings.debtPercent.value"
              label="Percent of debt to repay"
              :min="0"
              :max="100"
              :step="1"
              :number-filter="(n: number) => `${n}%`"
              @update:model-value="savings.onPercentInput"
            />

            <SwapRouteSelector
              v-if="!savings.isSameAsset.value"
              :items="savings.routeItems.value"
              :selected-provider="savings.quotes.selectedProvider.value"
              :status-label="savings.quotes.statusLabel.value"
              :is-loading="savings.quotes.isLoading.value"
              :empty-message="savings.routeEmptyMessage.value"
              @select="savings.quotes.selectProvider"
              @refresh="savings.onRefreshQuotes"
            />

            <UiToast
              v-if="savings.quotes.quoteError.value && !savings.isSameAsset.value"
              title="Swap quote"
              variant="warning"
              :description="savings.quotes.quoteError.value"
              size="compact"
            />
            <UiToast
              v-if="savings.disabledReason.value"
              title="Cannot submit"
              variant="warning"
              :description="savings.disabledReason.value"
              size="compact"
            />
            <UiToast
              v-if="simulationError"
              title="Error"
              variant="error"
              :description="simulationError"
              size="compact"
            />
          </div>

          <VaultFormInfoBlock
            :loading="!savings.isSameAsset.value && savings.quotes.isLoading.value"
            variant="card"
            class="w-full laptop:max-w-[360px]"
          >
            <SummaryRow label="ROE">
              <SummaryValue
                :before="savings.roeBefore.value !== null ? formatNumber(savings.roeBefore.value) : undefined"
                :after="savings.roeAfter.value !== null && (savings.quotes.quote.value || savings.isSameAsset.value) ? formatNumber(savings.roeAfter.value) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <template v-if="!savings.isSameAsset.value">
              <SummaryRow
                label="Swap price"
                align-top
              >
                <SummaryPriceValue
                  :value="savings.currentPrice.value ? formatSmartAmount(savings.priceInvert.invertValue(savings.currentPrice.value.value)) : undefined"
                  :symbol="savings.priceInvert.displaySymbol"
                  invertible
                  @invert="savings.priceInvert.toggle"
                />
              </SummaryRow>
            </template>
            <template v-else>
              <SummaryRow label="Transfer">
                <p class="text-p2">
                  1:1 (same asset, no slippage)
                </p>
              </SummaryRow>
            </template>
            <SummaryRow label="Liquidation price">
              <SummaryPriceValue
                :before="savings.currentLiquidationPrice.value !== null ? formatSmartAmount(walletPriceInvert.invertValue(savings.currentLiquidationPrice.value)) : undefined"
                :after="savings.nextLiquidationPrice.value !== null && (savings.quotes.quote.value || savings.isSameAsset.value) ? formatSmartAmount(walletPriceInvert.invertValue(savings.nextLiquidationPrice.value)) : undefined"
                :symbol="walletPriceInvert.displaySymbol"
                invertible
                @invert="walletPriceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow label="LTV">
              <SummaryValue
                :before="savings.currentLtv.value !== null ? formatNumber(savings.currentLtv.value) : undefined"
                :after="savings.nextLtv.value !== null && (savings.quotes.quote.value || savings.isSameAsset.value) ? formatNumber(savings.nextLtv.value) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Health score">
              <SummaryValue
                :before="savings.currentHealth.value !== null ? formatHealthScore(savings.currentHealth.value) : undefined"
                :after="savings.nextHealth.value !== null && (savings.quotes.quote.value || savings.isSameAsset.value) ? formatHealthScore(savings.nextHealth.value) : undefined"
              />
            </SummaryRow>
            <template v-if="!savings.isSameAsset.value">
              <SummaryRow
                label="Swap"
                align-top
              >
                <p class="text-p2 text-right flex flex-col items-end">
                  <span>{{ savings.summary.value ? savings.summary.value.from : '-' }}</span>
                  <span
                    v-if="savings.summary.value"
                    class="text-content-tertiary text-p3"
                  >
                    {{ savings.summary.value.to }}
                  </span>
                </p>
              </SummaryRow>
              <SummaryRow label="Price impact">
                <p class="text-p2">
                  {{ savings.priceImpact.value !== null ? `${formatNumber(savings.priceImpact.value, 2, 2)}%` : '-' }}
                </p>
              </SummaryRow>
              <SummaryRow label="Leveraged price impact">
                <p class="text-p2">
                  {{ savings.leveragedPriceImpact.value !== null ? `${formatNumber(savings.leveragedPriceImpact.value, 2, 2)}%` : '-' }}
                </p>
              </SummaryRow>
              <SummaryRow label="Slippage tolerance">
                <button
                  type="button"
                  class="flex items-center gap-6 text-p2"
                  @click="openSlippageSettings"
                >
                  <span>{{ formatNumber(slippage, 2, 0) }}%</span>
                  <SvgIcon
                    name="edit"
                    class="!w-16 !h-16 text-accent-600"
                  />
                </button>
              </SummaryRow>
              <SummaryRow label="Routed via">
                <p class="text-p2 text-right">
                  {{ savings.routedVia.value || '-' }}
                </p>
              </SummaryRow>
            </template>
          </VaultFormInfoBlock>

          <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
            <VaultFormInfoButton
              :pair="position"
              :disabled="isLoading || isSubmitting"
            >
              Pair information
            </VaultFormInfoButton>
            <VaultFormSubmit
              :disabled="reviewRepayDisabled"
              :loading="isSubmitting || isPreparing"
            >
              {{ reviewRepayLabel }}
            </VaultFormSubmit>
          </div>
        </div>
      </template>
    </template>
  </VaultForm>
</template>
