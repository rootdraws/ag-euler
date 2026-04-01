<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { zeroAddress, type Address, type Abi } from 'viem'
import { getPublicClient } from '~/utils/public-client'
import type { AccountBorrowPosition } from '~/entities/account'
import { eulerAccountLensABI } from '~/entities/euler/abis'
import type {
  Vault,
  SecuritizeVault,
  VaultAsset,
} from '~/entities/vault'
import {
  getAssetUsdValue,
  getAssetOraclePrice,
  getCollateralOraclePrice,
  getCollateralUsdPrice,
  conservativePriceRatioNumber,
  getCollateralUsdValueOrZero,
} from '~/services/pricing/priceProvider'
import { useSwapCollateralOptions } from '~/composables/useSwapCollateralOptions'
import { SwapperMode } from '~/entities/swap'
import type { SwapApiQuote } from '~/entities/swap'
import type { TxPlan } from '~/entities/txPlan'
import { useIntrinsicApy } from '~/composables/useIntrinsicApy'
import { useVaultRegistry } from '~/composables/useVaultRegistry'
import { formatNumber, formatSmartAmount, formatHealthScore } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import { useSwapPageLogic } from '~/composables/useSwapPageLogic'

const route = useRoute()
const { isConnected, address } = useAccount()
const { isPositionsLoaded, isPositionsLoading, getPositionBySubAccountIndex } = useEulerAccount()
const { buildSwapPlan, buildSameAssetSwapPlan } = useEulerOperations()
const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()
const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()
const { isReady: isVaultsReady } = useVaults()
const { getOrFetch } = useVaultRegistry()
const { eulerLensAddresses, isReady: isEulerAddressesReady, loadEulerConfig } = useEulerAddresses()
const { EVM_PROVIDER_URL } = useEulerConfig()

const positionIndex = usePositionIndex()

// ── Vaults & position ────────────────────────────────────────────────────
const position: Ref<AccountBorrowPosition | null> = ref(null)
const selectedCollateral = ref<Vault | SecuritizeVault | null>(null)
const selectedCollateralAssets = ref(0n)
const lastCollateralAddress = ref('')

const fromVault = computed(() => selectedCollateral.value || position.value?.collateral)
const borrowVault = computed(() => position.value?.borrow)
const toVault: Ref<Vault | undefined> = ref()

const isFromSecuritize = computed(() => fromVault.value && 'type' in fromVault.value && fromVault.value.type === 'securitize')
const fromVaultAsRegular = computed(() => {
  if (!fromVault.value || isFromSecuritize.value) return undefined
  return fromVault.value as Vault
})
const { collateralOptions, collateralVaults } = useSwapCollateralOptions({
  currentVault: fromVaultAsRegular,
  liabilityVault: computed(() => borrowVault.value as Vault | undefined),
})

const balance = computed(() => selectedCollateralAssets.value)
const targetVaultAddress = computed(() => typeof route.query.to === 'string' ? route.query.to : '')

const isMaxSwap = computed(() => {
  if (!fromVault.value?.asset || !fromAmount.value) return false
  try {
    const amount = valueToNano(fromAmount.value, fromVault.value.asset.decimals)
    return balance.value > 0n && amount >= balance.value
  }
  catch { return false }
})

// ── Shared swap logic (must be before any code that uses its outputs) ────
const swap = useSwapPageLogic({
  amountField: 'amountOut',
  compare: 'max',
  fromVault,
  toVault,
  balance,
  vaultOptions: collateralVaults,
  displayAmountField: 'amountOut',
  quoteDiffPrefix: '-',
  redirectPath: '/portfolio',
  targetVaultAddress,

  buildQuoteRequest(amount) {
    if (!fromVault.value || !toVault.value || !position.value) return null
    const account = (position.value.subAccount || address.value || zeroAddress) as Address
    return {
      params: {
        tokenIn: fromVault.value.asset.address as Address,
        tokenOut: toVault.value.asset.address as Address,
        accountIn: account,
        accountOut: account,
        amount,
        vaultIn: fromVault.value.address as Address,
        receiver: toVault.value.address as Address,
        slippage: slippage.value,
        swapperMode: SwapperMode.EXACT_IN,
        isRepay: false,
        targetDebt: 0n,
        currentDebt: 0n,
      },
      logContext: {
        fromVault: fromVault.value.address,
        toVault: toVault.value.address,
        amount: fromAmount.value,
        slippage: slippage.value,
        swapperMode: SwapperMode.EXACT_IN,
        isRepay: false,
      },
    }
  },

  async buildPlan(): Promise<TxPlan> {
    if (!fromVault.value || !toVault.value || !position.value) throw new Error('Vaults or position not loaded')
    if (isSameAsset.value) {
      const amount = valueToNano(fromAmount.value, fromVault.value.asset.decimals)
      return buildSameAssetSwapPlan({
        fromVaultAddress: fromVault.value.address,
        toVaultAddress: toVault.value.address,
        amount,
        isMax: isMaxSwap.value,
        subAccount: position.value.subAccount,
        enableCollateral: true,
        disableCollateral: isMaxSwap.value,
        liabilityVault: borrowVault.value?.address,
        enabledCollaterals: position.value.collaterals,
      })
    }
    if (!selectedQuote.value) throw new Error('No quote selected')
    return buildSwapPlan({
      quote: selectedQuote.value,
      swapperMode: SwapperMode.EXACT_IN,
      isRepay: false,
      targetDebt: 0n,
      currentDebt: 0n,
      enableCollateral: true,
      disableCollateral: isMaxSwap.value ? fromVault.value.address : undefined,
      liabilityVault: borrowVault.value?.address,
      enabledCollaterals: position.value.collaterals,
    })
  },

  getBalanceError: amountNano => balance.value < amountNano ? 'Not enough balance' : null,

  getGeoBlockedAddresses() {
    const addresses: string[] = []
    if (fromVault.value) addresses.push(fromVault.value.address)
    if (borrowVault.value) addresses.push(borrowVault.value.address)
    return addresses
  },

  async computePriceImpact(q: SwapApiQuote) {
    if (!fromVault.value || !toVault.value || !borrowVault.value) return null
    const amountInUsd = await getCollateralValueUsdLocal(BigInt(q.amountIn))
    const amountOutUsd = await getAssetUsdValue(BigInt(q.amountOut), toVault.value, 'off-chain')
    if (!amountInUsd || !amountOutUsd) return null
    const impact = (amountOutUsd / amountInUsd - 1) * 100
    return Number.isFinite(impact) ? impact : null
  },
})

const {
  isLoading, isSubmitting, isPreparing, fromAmount, toAmount, slippage,
  isSameAsset, sameVaultError, errorText, quote,
  isGeoBlocked, reviewSwapDisabled, reviewSwapLabel, simulationError,
  isQuoteLoading, quoteError, quotesStatusLabel, selectedProvider, selectedQuote,
  fromProduct, toProduct, swapPriceInvert, currentPrice, swapSummary, priceImpact, routedVia,
  swapRouteItems, swapRouteEmptyMessage,
  selectProvider, onFromInput, onToVaultChange, onRefreshQuotes, submit, openSlippageSettings,
  normalizeAddress, resetQuoteState,
} = swap

// ── Position loading ─────────────────────────────────────────────────────
const getSelectedCollateralAddress = () =>
  (typeof route.query.collateral === 'string' ? route.query.collateral : '')

const loadSelectedCollateral = async () => {
  if (!position.value) {
    selectedCollateral.value = null
    selectedCollateralAssets.value = 0n
    return
  }

  const primaryAddress = normalizeAddress(position.value.collateral.address)
  const targetAddress = normalizeAddress(getSelectedCollateralAddress()) || primaryAddress

  if (targetAddress !== lastCollateralAddress.value) {
    fromAmount.value = ''
    lastCollateralAddress.value = targetAddress
    resetQuoteState()
  }

  selectedCollateralAssets.value = targetAddress === primaryAddress ? position.value.supplied : 0n

  try {
    if (!isEulerAddressesReady.value) {
      await loadEulerConfig()
    }

    await until(isVaultsReady).toBe(true)

    const vault = await getOrFetch(targetAddress) as Vault | SecuritizeVault | undefined
    selectedCollateral.value = vault || null

    const lensAddress = eulerLensAddresses.value?.accountLens
    if (!lensAddress) {
      throw new Error('Account lens address is not available')
    }

    const client = getPublicClient(EVM_PROVIDER_URL)
    const res = await client.readContract({
      address: lensAddress as Address,
      abi: eulerAccountLensABI as Abi,
      functionName: 'getVaultAccountInfo',
      args: [position.value.subAccount, targetAddress],
    }) as Record<string, any>
    selectedCollateralAssets.value = res.assets
  }
  catch (e) {
    console.warn('[Collateral swap] failed to load collateral', e)
    if (!selectedCollateral.value) {
      selectedCollateral.value = position.value.collateral
    }
  }
}

const loadPosition = async () => {
  if (!isConnected.value) {
    position.value = null
    return
  }
  isLoading.value = true
  await until(isPositionsLoaded).toBe(true)

  position.value = getPositionBySubAccountIndex(+positionIndex) || null
  await loadSelectedCollateral()
  isLoading.value = false
}

watch([isPositionsLoaded, () => route.params.number], ([loaded]) => {
  if (loaded) {
    loadPosition()
  }
}, { immediate: true })
watch(() => route.query.collateral, async () => {
  if (!position.value) return
  await loadSelectedCollateral()
})

// ── Supply & borrow APY ──────────────────────────────────────────────────
const fromSupplyApy = computed(() => {
  if (!fromVault.value) return null
  const base = nanoToValue(fromVault.value.interestRateInfo.supplyAPY || 0n, 25)
  return withIntrinsicSupplyApy(base, fromVault.value.asset.address) + getSupplyRewardApy(fromVault.value.address)
})
const toSupplyApy = computed(() => {
  if (!toVault.value) return null
  const base = nanoToValue(toVault.value.interestRateInfo.supplyAPY || 0n, 25)
  return withIntrinsicSupplyApy(base, toVault.value.asset.address) + getSupplyRewardApy(toVault.value.address)
})
const borrowApy = computed(() => {
  if (!borrowVault.value) return null
  const base = nanoToValue(borrowVault.value.interestRateInfo.borrowAPY || 0n, 25)
  return withIntrinsicBorrowApy(base, borrowVault.value.asset.address) - getBorrowRewardApy(borrowVault.value.address, fromVault.value?.address)
})

// ── Collateral USD valuation (from liability vault's perspective) ─────────
const getCollateralValueUsdLocal = async (amount: bigint) => {
  if (!borrowVault.value || !fromVault.value) return 0
  return getCollateralUsdValueOrZero(amount, borrowVault.value, fromVault.value as Vault, 'off-chain')
}
const collateralPricePerUnit = ref<number | undefined>(undefined)
watchEffect(async () => {
  if (!borrowVault.value || !fromVault.value) {
    collateralPricePerUnit.value = undefined
    return
  }
  const priceInfo = await getCollateralUsdPrice(borrowVault.value, fromVault.value as Vault, 'off-chain')
  if (!priceInfo?.amountOutMid) {
    collateralPricePerUnit.value = undefined
    return
  }
  collateralPricePerUnit.value = nanoToValue(priceInfo.amountOutMid, 18)
})

// ── ROE ──────────────────────────────────────────────────────────────────
const supplyValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (!fromVault.value || !position.value || !borrowVault.value) {
    supplyValueUsd.value = null
    return
  }
  supplyValueUsd.value = await getCollateralValueUsdLocal(selectedCollateralAssets.value)
})
const nextSupplyValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (isSameAsset.value && toVault.value && fromAmount.value) {
    try {
      const amount = valueToNano(fromAmount.value, toVault.value.asset.decimals)
      nextSupplyValueUsd.value = (await getAssetUsdValue(amount, toVault.value, 'off-chain')) ?? null
    }
    catch {
      nextSupplyValueUsd.value = null
    }
    return
  }
  if (!quote.value || !toVault.value) {
    nextSupplyValueUsd.value = null
    return
  }
  nextSupplyValueUsd.value = (await getAssetUsdValue(BigInt(quote.value.amountOut), toVault.value, 'off-chain')) ?? null
})
const borrowValueUsd = ref<number | null>(null)
watchEffect(async () => {
  if (!borrowVault.value || !position.value) {
    borrowValueUsd.value = null
    return
  }
  borrowValueUsd.value = (await getAssetUsdValue(position.value.borrowed, borrowVault.value, 'off-chain')) ?? null
})

const calculateRoe = (
  supplyUsd: number | null,
  borrowUsd: number | null,
  supplyApy: number | null,
  borrowApyValue: number | null,
) => {
  if (supplyUsd === null || borrowUsd === null || supplyApy === null || borrowApyValue === null) return null
  const equity = supplyUsd - borrowUsd
  if (!Number.isFinite(equity) || equity <= 0) return null
  const net = supplyUsd * supplyApy - borrowUsd * borrowApyValue
  if (!Number.isFinite(net)) return null
  return net / equity
}

const roeBefore = computed(() => calculateRoe(supplyValueUsd.value, borrowValueUsd.value, fromSupplyApy.value, borrowApy.value))
const roeAfter = computed(() => calculateRoe(nextSupplyValueUsd.value, borrowValueUsd.value, toSupplyApy.value, borrowApy.value))

// ── Health metrics ───────────────────────────────────────────────────────
const liqPriceInvert = usePriceInvert(
  () => toVault.value?.asset.symbol,
  () => borrowVault.value?.asset.symbol,
)

const priceRatio = computed(() => {
  if (!toVault.value || !borrowVault.value) return null
  const collateralPrice = getCollateralOraclePrice(borrowVault.value, toVault.value)
  const borrowPrice = getAssetOraclePrice(borrowVault.value)
  return conservativePriceRatioNumber(collateralPrice, borrowPrice)
})
const nextCollateralAmount = computed(() => {
  if (isSameAsset.value && toVault.value && fromAmount.value) {
    try {
      return nanoToValue(valueToNano(fromAmount.value, toVault.value.asset.decimals), toVault.value.decimals)
    }
    catch { return null }
  }
  if (!quote.value || !toVault.value) return null
  return nanoToValue(BigInt(quote.value.amountOut), toVault.value.decimals)
})
const borrowAmount = computed(() => {
  if (!borrowVault.value || !position.value) return null
  return nanoToValue(position.value.borrowed, borrowVault.value.decimals)
})

const currentLtv = computed(() => position.value ? nanoToValue(position.value.userLTV, 18) : null)
const fromLiquidationLtv = computed(() => {
  if (!borrowVault.value || !fromVault.value) return null
  const match = borrowVault.value.collateralLTVs.find(
    ltv => normalizeAddress(ltv.collateral) === normalizeAddress(fromVault.value?.address),
  )
  return match ? nanoToValue(match.liquidationLTV, 2) : null
})
const nextLiquidationLtv = computed(() => {
  if (!borrowVault.value || !toVault.value) return null
  const match = borrowVault.value.collateralLTVs.find(
    ltv => normalizeAddress(ltv.collateral) === normalizeAddress(toVault.value?.address),
  )
  return match ? nanoToValue(match.liquidationLTV, 2) : null
})
// Remaining FROM collateral value after partial swap
const remainingFromValue = computed(() => {
  if (!fromVault.value || !fromAmount.value || !currentPriceRatio.value) return 0
  try {
    const swapped = valueToNano(fromAmount.value, fromVault.value.asset.decimals)
    const remaining = selectedCollateralAssets.value - swapped
    if (remaining <= 0n) return 0
    return nanoToValue(remaining, fromVault.value.decimals) * currentPriceRatio.value
  }
  catch { return 0 }
})
// New TO collateral value from swap output
const newToValue = computed(() => {
  if (!nextCollateralAmount.value || !priceRatio.value) return 0
  if (priceRatio.value <= 0 || nextCollateralAmount.value <= 0) return 0
  return nextCollateralAmount.value * priceRatio.value
})
const nextLtv = computed(() => {
  if (!borrowAmount.value) return null
  const totalValue = remainingFromValue.value + newToValue.value
  if (totalValue <= 0) return null
  return (borrowAmount.value / totalValue) * 100
})
const currentHealth = computed(() => position.value ? nanoToValue(position.value.health, 18) : null)
const nextHealth = computed(() => {
  if (!nextLtv.value || nextLtv.value <= 0) return null
  const totalValue = remainingFromValue.value + newToValue.value
  if (totalValue <= 0) return null
  // Weighted average liquidation LTV across both collateral types
  const weightedLiqLtv = (
    remainingFromValue.value * (fromLiquidationLtv.value ?? 0)
    + newToValue.value * (nextLiquidationLtv.value ?? 0)
  ) / totalValue
  return weightedLiqLtv / nextLtv.value
})
const currentPriceRatio = computed(() => {
  if (!fromVault.value || !borrowVault.value) return null
  const collateralPrice = getCollateralOraclePrice(borrowVault.value, fromVault.value as Vault)
  const borrowPrice = getAssetOraclePrice(borrowVault.value)
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
</script>

<template>
  <div class="flex gap-32">
    <VaultForm
      title="Collateral swap"
      class="flex flex-col gap-16 w-full"
      :loading="isLoading || isPositionsLoading"
      @submit.prevent="submit"
    >
      <template v-if="fromVault">
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
              :vault="isFromSecuritize ? undefined : (fromVault as Vault)"
              :balance="balance"
              :price-override="isFromSecuritize ? collateralPricePerUnit : undefined"
              maxable
              @input="onFromInput"
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
              v-if="toVault"
              v-model="toAmount"
              :desc="toProduct.name"
              label="To"
              :asset="toVault.asset"
              :vault="toVault"
              :collateral-options="collateralOptions"
              :readonly="true"
              @change-collateral="onToVaultChange"
            />
            <div
              v-else
              class="bg-euler-dark-400 rounded-16 p-16 text-euler-dark-900"
            >
              No collateral swap options available
            </div>

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
              v-if="simulationError"
              title="Error"
              variant="error"
              :description="simulationError"
              size="compact"
            />

            <UiToast
              v-if="quoteError"
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
                :after="roeAfter !== null && (quote || isSameAsset) ? formatNumber(roeAfter) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <template v-if="!isSameAsset">
              <SummaryRow
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
            </template>
            <template v-else>
              <SummaryRow label="Transfer">
                <p class="text-p2">
                  1:1 (same asset, no slippage)
                </p>
              </SummaryRow>
            </template>
            <SummaryRow
              label="Liquidation price"
              align-top
            >
              <SummaryPriceValue
                :before="liqPriceInvert.invertValue(currentLiquidationPrice) != null ? formatSmartAmount(liqPriceInvert.invertValue(currentLiquidationPrice)!) : undefined"
                :after="nextLiquidationPrice !== null && (quote || isSameAsset) ? formatSmartAmount(liqPriceInvert.invertValue(nextLiquidationPrice)) : undefined"
                :symbol="liqPriceInvert.displaySymbol"
                invertible
                @invert="liqPriceInvert.toggle"
              />
            </SummaryRow>
            <SummaryRow label="LTV">
              <SummaryValue
                :before="currentLtv !== null ? formatNumber(currentLtv) : undefined"
                :after="nextLtv !== null && (quote || isSameAsset) ? formatNumber(nextLtv) : undefined"
                suffix="%"
              />
            </SummaryRow>
            <SummaryRow label="Health score">
              <SummaryValue
                :before="currentHealth !== null ? formatHealthScore(currentHealth) : undefined"
                :after="nextHealth !== null && (quote || isSameAsset) ? formatHealthScore(nextHealth) : undefined"
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
