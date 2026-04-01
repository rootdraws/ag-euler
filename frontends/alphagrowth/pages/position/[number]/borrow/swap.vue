<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { formatUnits, zeroAddress, type Address } from 'viem'
import type { AccountBorrowPosition } from '~/entities/account'
import type { Vault, VaultAsset } from '~/entities/vault'
import { getAssetUsdValue, getAssetOraclePrice, getCollateralOraclePrice, conservativePriceRatioNumber } from '~/services/pricing/priceProvider'
import { useSwapDebtOptions } from '~/composables/useSwapDebtOptions'
import { SwapperMode } from '~/entities/swap'
import type { TxPlan } from '~/entities/txPlan'
import { useIntrinsicApy } from '~/composables/useIntrinsicApy'
import { formatNumber, formatSmartAmount, formatHealthScore } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import { useSwapPageLogic } from '~/composables/useSwapPageLogic'

const route = useRoute()
const { isConnected, address } = useAccount()
const { isPositionsLoaded, isPositionsLoading, getPositionBySubAccountIndex } = useEulerAccount()
const { buildSwapPlan, buildSameAssetDebtSwapPlan } = useEulerOperations()
const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()
const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()

const positionIndex = usePositionIndex()

// ── Position & vaults ────────────────────────────────────────────────────
const position: Ref<AccountBorrowPosition | null> = ref(null)

const fromVault = computed(() => position.value?.borrow)
const collateralVault = computed(() => position.value?.collateral)
const toVault: Ref<Vault | undefined> = ref()

const { borrowOptions, borrowVaults } = useSwapDebtOptions({
  collateralVault: computed(() => collateralVault.value as Vault | undefined),
  currentBorrowVault: computed(() => fromVault.value as Vault | undefined),
})

const currentDebt = computed(() => position.value?.borrowed || 0n)
const balance = computed(() => currentDebt.value)
const targetVaultAddress = computed(() => typeof route.query.to === 'string' ? route.query.to : '')

const setFromAmountToMax = () => {
  if (!fromVault.value) {
    fromAmount.value = ''
    return
  }
  const exact = formatUnits(currentDebt.value, Number(fromVault.value.decimals))
  const [intPart, decPart = ''] = exact.split('.')
  const sigDigitsInInt = intPart.replace(/^0+/, '').length
  if (sigDigitsInInt >= 6) {
    fromAmount.value = intPart
  }
  else {
    const decLen = Math.max(0, 6 - sigDigitsInInt)
    fromAmount.value = decPart.length > 0
      ? `${intPart}.${decPart.slice(0, decLen)}`
      : intPart
  }
}

// ── APY & ROE ────────────────────────────────────────────────────────────
const liqPriceInvert = usePriceInvert(
  () => collateralVault.value?.asset.symbol,
  () => toVault.value?.asset.symbol,
)
const currentLiqDisplaySymbol = computed(() => {
  const a = collateralVault.value?.asset.symbol || ''
  const b = fromVault.value?.asset.symbol || ''
  return liqPriceInvert.isInverted ? `${b}/${a}` : `${a}/${b}`
})

const collateralSupplyApy = computed(() => {
  if (!collateralVault.value) return null
  const base = nanoToValue(collateralVault.value.interestRateInfo.supplyAPY || 0n, 25)
  return withIntrinsicSupplyApy(base, collateralVault.value.asset.address) + getSupplyRewardApy(collateralVault.value.address)
})
const fromBorrowApy = computed(() => {
  if (!fromVault.value) return null
  const base = nanoToValue(fromVault.value.interestRateInfo.borrowAPY || 0n, 25)
  return withIntrinsicBorrowApy(base, fromVault.value.asset.address) - getBorrowRewardApy(fromVault.value.address, collateralVault.value?.address)
})
const toBorrowApy = computed(() => {
  if (!toVault.value) return null
  const base = nanoToValue(toVault.value.interestRateInfo.borrowAPY || 0n, 25)
  return withIntrinsicBorrowApy(base, toVault.value.asset.address) - getBorrowRewardApy(toVault.value.address, collateralVault.value?.address)
})

const supplyValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (!collateralVault.value || !position.value) {
    supplyValueUsd.value = null
    return
  }
  supplyValueUsd.value = (await getAssetUsdValue(position.value.supplied, collateralVault.value, 'off-chain')) ?? null
})
const currentBorrowValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (!fromVault.value || !position.value) {
    currentBorrowValueUsd.value = null
    return
  }
  currentBorrowValueUsd.value = (await getAssetUsdValue(position.value.borrowed, fromVault.value, 'off-chain')) ?? null
})
const nextBorrowValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (!quote.value || !toVault.value) {
    nextBorrowValueUsd.value = null
    return
  }
  nextBorrowValueUsd.value = (await getAssetUsdValue(BigInt(quote.value.amountIn), toVault.value, 'off-chain')) ?? null
})

const calculateRoe = (
  supplyUsd: number | null,
  borrowUsd: number | null,
  supplyApy: number | null,
  borrowApy: number | null,
) => {
  if (supplyUsd === null || borrowUsd === null || supplyApy === null || borrowApy === null) return null
  const equity = supplyUsd - borrowUsd
  if (!Number.isFinite(equity) || equity <= 0) return null
  const net = supplyUsd * supplyApy - borrowUsd * borrowApy
  if (!Number.isFinite(net)) return null
  return net / equity
}

const roeBefore = computed(() => calculateRoe(supplyValueUsd.value, currentBorrowValueUsd.value, collateralSupplyApy.value, fromBorrowApy.value))
const roeAfter = computed(() => calculateRoe(supplyValueUsd.value, nextBorrowValueUsd.value, collateralSupplyApy.value, toBorrowApy.value))

// ── Health metrics ───────────────────────────────────────────────────────
const priceRatio = computed(() => {
  if (!collateralVault.value || !toVault.value) return null
  const collateralPrice = getCollateralOraclePrice(toVault.value, collateralVault.value)
  const borrowPrice = getAssetOraclePrice(toVault.value)
  return conservativePriceRatioNumber(collateralPrice, borrowPrice)
})
const collateralAmount = computed(() => {
  if (!collateralVault.value || !position.value) return null
  return nanoToValue(position.value.supplied, collateralVault.value.decimals)
})
const nextBorrowAmount = computed(() => {
  if (!quote.value || !toVault.value) return null
  return nanoToValue(BigInt(quote.value.amountIn), toVault.value.decimals)
})

const currentLtv = computed(() => position.value ? nanoToValue(position.value.userLTV, 18) : null)
const _currentLiquidationLtv = computed(() => position.value ? nanoToValue(position.value.liquidationLTV, 2) : null)
const nextLiquidationLtv = computed(() => {
  if (!toVault.value || !collateralVault.value) return null
  const match = toVault.value.collateralLTVs.find(
    ltv => normalizeAddress(ltv.collateral) === normalizeAddress(collateralVault.value?.address),
  )
  return match ? nanoToValue(match.liquidationLTV, 2) : null
})
const nextLtv = computed(() => {
  if (!nextBorrowAmount.value || !collateralAmount.value || !priceRatio.value) return null
  if (priceRatio.value <= 0 || collateralAmount.value <= 0) return null
  return (nextBorrowAmount.value / (collateralAmount.value * priceRatio.value)) * 100
})
const currentHealth = computed(() => position.value ? nanoToValue(position.value.health, 18) : null)
const nextHealth = computed(() => {
  if (!nextLiquidationLtv.value || !nextLtv.value) return null
  if (nextLtv.value <= 0) return null
  return nextLiquidationLtv.value / nextLtv.value
})
const currentPriceRatio = computed(() => {
  if (!collateralVault.value || !fromVault.value) return null
  const collateralPrice = getCollateralOraclePrice(fromVault.value, collateralVault.value)
  const borrowPrice = getAssetOraclePrice(fromVault.value)
  return conservativePriceRatioNumber(collateralPrice, borrowPrice)
})
const currentLiquidationPrice = computed(() => {
  if (!currentPriceRatio.value || !currentHealth.value) return null
  if (currentHealth.value <= 0) return null
  return currentPriceRatio.value / currentHealth.value
})
const nextLiquidationPrice = computed(() => {
  if (!priceRatio.value || !nextHealth.value) return null
  if (nextHealth.value <= 0) return null
  return priceRatio.value / nextHealth.value
})

const healthError = computed(() => {
  if (!quote.value || nextHealth.value === null) return null
  if (!Number.isFinite(nextHealth.value)) return null
  return nextHealth.value <= 1 ? 'Swap would make position unhealthy' : null
})

// ── Shared swap logic ────────────────────────────────────────────────────
const swap = useSwapPageLogic({
  amountField: 'amountIn',
  compare: 'min',
  fromVault,
  toVault,
  balance,
  vaultOptions: borrowVaults,
  displayAmountField: 'amountIn',
  quoteDiffPrefix: '+',
  redirectPath: '/portfolio',
  targetVaultAddress,
  additionalErrors: [healthError],
  sameAssetModalType: 'swap',

  buildQuoteRequest(amount) {
    if (!fromVault.value || !toVault.value || !position.value) return null
    if (amount > currentDebt.value) return null
    const accountIn = (address.value || zeroAddress) as Address
    const accountOut = (position.value.subAccount || accountIn) as Address
    return {
      params: {
        tokenIn: toVault.value.asset.address as Address,
        tokenOut: fromVault.value.asset.address as Address,
        accountIn,
        accountOut,
        amount,
        vaultIn: toVault.value.address as Address,
        receiver: fromVault.value.address as Address,
        slippage: slippage.value,
        swapperMode: SwapperMode.TARGET_DEBT,
        isRepay: true,
        targetDebt: 0n,
        currentDebt: currentDebt.value,
      },
      logContext: {
        fromVault: fromVault.value.address,
        toVault: toVault.value.address,
        amount: fromAmount.value,
        slippage: slippage.value,
        swapperMode: SwapperMode.TARGET_DEBT,
        isRepay: true,
      },
    }
  },

  async buildPlan(): Promise<TxPlan> {
    if (!fromVault.value || !toVault.value) throw new Error('Vaults not loaded')
    if (isSameAsset.value) {
      const amount = valueToNano(fromAmount.value, fromVault.value.asset.decimals)
      return buildSameAssetDebtSwapPlan({
        oldVaultAddress: fromVault.value.address,
        newVaultAddress: toVault.value.address,
        amount,
        subAccount: position.value?.subAccount || address.value!,
        enabledCollaterals: position.value?.collaterals,
      })
    }
    if (!selectedQuote.value) throw new Error('No quote selected')
    return buildSwapPlan({
      quote: selectedQuote.value,
      swapperMode: SwapperMode.TARGET_DEBT,
      isRepay: true,
      isDebtSwap: true,
      targetDebt: 0n,
      currentDebt: currentDebt.value,
      liabilityVault: fromVault.value.address,
      enabledCollaterals: position.value?.collaterals,
    })
  },

  getBalanceError(amountNano) {
    if (!fromAmount.value) return null
    return amountNano > currentDebt.value ? 'Amount exceeds current debt' : null
  },

  getGeoBlockedAddresses() {
    const addresses: string[] = []
    if (fromVault.value) addresses.push(fromVault.value.address)
    if (collateralVault.value) addresses.push(collateralVault.value.address)
    return addresses
  },
})

const {
  isLoading, isSubmitting, isPreparing, fromAmount, toAmount, slippage,
  isSameAsset, sameVaultError, errorText, quote,
  isGeoBlocked, reviewSwapDisabled, reviewSwapLabel, simulationError,
  isQuoteLoading, quoteError, quotesStatusLabel, selectedProvider, selectedQuote,
  fromProduct, toProduct, swapPriceInvert, currentPrice, swapSummary, priceImpact, routedVia,
  swapRouteItems, swapRouteEmptyMessage,
  selectProvider, onFromInput: _onFromInput, onRefreshQuotes, submit, openSlippageSettings,
  normalizeAddress, clearSimulationError, requestQuote,
} = swap

// ── Position loading ─────────────────────────────────────────────────────
const loadPosition = async () => {
  if (!isConnected.value) {
    position.value = null
    return
  }
  isLoading.value = true
  await until(isPositionsLoaded).toBe(true)

  position.value = getPositionBySubAccountIndex(+positionIndex) || null
  isLoading.value = false
}

watch([isPositionsLoaded, () => route.params.number], ([loaded]) => {
  if (loaded) {
    loadPosition()
  }
}, { immediate: true })

// ── Debt auto-fill ───────────────────────────────────────────────────────
watch([currentDebt, fromVault], () => {
  clearSimulationError()
  if (!position.value) return
  setFromAmountToMax()
  if (toVault.value) {
    requestQuote()
  }
})

const onToVaultChange = (selectedIndex: number) => {
  clearSimulationError()
  const nextVault = borrowVaults.value[selectedIndex]
  if (!nextVault) return
  if (!toVault.value || normalizeAddress(toVault.value.address) !== normalizeAddress(nextVault.address)) {
    toVault.value = nextVault
  }
}
</script>

<template>
  <div class="flex gap-32">
    <VaultForm
      title="Debt swap"
      class="flex flex-col gap-16 w-full"
      :loading="isLoading || isPositionsLoading"
      @submit.prevent="submit"
    >
      <template v-if="fromVault && toVault">
        <VaultLabelsAndAssets
          :vault="fromVault"
          :assets="[fromVault.asset] as VaultAsset[]"
          size="large"
        />
        <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
          <div class="flex flex-col gap-16 w-full">
            <AssetInput
              v-model="fromAmount"
              :desc="fromProduct.name"
              label="From"
              :asset="fromVault.asset"
              :vault="fromVault"
              :balance="balance"
              :readonly="true"
              class="opacity-60 pointer-events-none"
            />

            <UiToast
              title="Full amount required"
              description="The entire debt amount must be swapped at once. Only one debt is allowed per sub-account."
              variant="info"
              size="compact"
            />

            <SwapRouteSelector
              v-if="!isSameAsset"
              :items="swapRouteItems"
              :selected-provider="selectedProvider"
              :status-label="quotesStatusLabel"
              :is-loading="isQuoteLoading"
              :empty-message="swapRouteEmptyMessage"
              @select="selectProvider"
              @refresh="onRefreshQuotes"
            />

            <AssetInput
              v-model="toAmount"
              :desc="toProduct.name"
              label="To"
              :asset="toVault.asset"
              :vault="toVault"
              :collateral-options="borrowOptions"
              collateral-modal-title="Select debt"
              :readonly="true"
              @change-collateral="onToVaultChange"
            />

            <UiToast
              v-if="isGeoBlocked"
              title="Region restricted"
              description="This operation is not available in your region. You can still repay existing debt."
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
              v-if="sameVaultError"
              title="Error"
              variant="error"
              :description="sameVaultError"
              size="compact"
            />
            <UiToast
              v-if="healthError"
              title="Unhealthy position"
              variant="error"
              :description="healthError"
              size="compact"
            />
            <UiToast
              v-if="simulationError"
              title="Error"
              variant="error"
              :description="simulationError"
              size="compact"
            />

            <UiToast
              v-if="quoteError && !isSameAsset"
              title="Swap quote"
              variant="warning"
              :description="quoteError"
              size="compact"
            />

            <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
              <VaultFormSubmit
                :disabled="reviewSwapDisabled"
                :loading="isSubmitting || isPreparing"
              >
                {{ reviewSwapLabel }}
              </VaultFormSubmit>
            </div>
          </div>

          <VaultFormInfoBlock
            :loading="!isSameAsset && isQuoteLoading"
            variant="card"
            class="w-full laptop:max-w-[360px]"
          >
            <SummaryRow label="ROE">
              <SummaryValue
                :before="roeBefore !== null ? formatNumber(roeBefore) : undefined"
                :after="roeAfter !== null && quote ? formatNumber(roeAfter) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow
              v-if="!isSameAsset"
              label="Swap price"
              align-top
            >
              <SummaryPriceValue
                :value="currentPrice ? formatSmartAmount(swapPriceInvert.invertValue(currentPrice.value)) : undefined"
                :symbol="swapPriceInvert.displaySymbol"
                invertible
                @invert="swapPriceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow
              label="Liquidation price"
              align-top
            >
              <!-- Borrow swap changes the borrow vault, so before/after symbols may differ -->
              <p class="text-p2 text-right inline-flex items-center flex-wrap justify-end gap-x-4">
                <template v-if="currentLiquidationPrice !== null && nextLiquidationPrice !== null && quote">
                  <span class="text-content-tertiary">{{ formatSmartAmount(liqPriceInvert.invertValue(currentLiquidationPrice)) }}<span class="text-p3 ml-2">{{ currentLiqDisplaySymbol }}</span></span>
                  &rarr; <span class="text-content-primary">{{ formatSmartAmount(liqPriceInvert.invertValue(nextLiquidationPrice)) }}<span class="text-content-tertiary text-p3 ml-2">{{ liqPriceInvert.displaySymbol }}</span></span>
                </template>
                <template v-else>
                  {{ liqPriceInvert.invertValue(currentLiquidationPrice) != null ? formatSmartAmount(liqPriceInvert.invertValue(currentLiquidationPrice)!) : '-' }}
                  <span
                    v-if="liqPriceInvert.invertValue(currentLiquidationPrice) != null"
                    class="text-content-tertiary text-p3"
                  >{{ currentLiqDisplaySymbol }}</span>
                </template>
                <button
                  type="button"
                  class="text-content-tertiary hover:text-content-primary transition-colors inline-flex"
                  @click.stop="liqPriceInvert.toggle"
                >
                  <SvgIcon
                    name="swap-horizontal"
                    class="!w-12 !h-12"
                  />
                </button>
              </p>
            </SummaryRow>
            <SummaryRow label="LTV">
              <SummaryValue
                :before="currentLtv !== null ? formatNumber(currentLtv) : undefined"
                :after="nextLtv !== null && quote ? formatNumber(nextLtv) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Health score">
              <SummaryValue
                :before="currentHealth !== null ? formatHealthScore(currentHealth) : undefined"
                :after="nextHealth !== null && quote ? formatHealthScore(nextHealth) : undefined"
              />
            </SummaryRow>
            <template v-if="!isSameAsset">
              <SummaryRow
                label="Swap"
                align-top
              >
                <p class="text-p2 text-right flex flex-col items-end">
                  <span>{{ swapSummary ? swapSummary.from : '-' }}</span>
                  <span
                    v-if="swapSummary"
                    class="text-content-tertiary text-p3"
                  >
                    {{ swapSummary.to }}
                  </span>
                </p>
              </SummaryRow>
              <SummaryRow label="Price impact">
                <p class="text-p2">
                  {{ priceImpact !== null ? `${formatNumber(priceImpact, 2, 2)}%` : '-' }}
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
                  {{ routedVia || '-' }}
                </p>
              </SummaryRow>
            </template>
          </VaultFormInfoBlock>
        </div>
      </template>
    </VaultForm>
  </div>
</template>
