import type { Ref, ComputedRef } from 'vue'
import { useAccount, useConfig } from '@wagmi/vue'
import { formatUnits, type Address } from 'viem'
import { logWarn } from '~/utils/errorHandling'
import { normalizeAddressOrEmpty } from '~/utils/accountPositionHelpers'
import { useModal } from '~/components/ui/composables/useModal'
import { OperationReviewModal } from '#components'
import { useToast } from '~/components/ui/composables/useToast'
import {
  type AnyBorrowVaultPair,
  type Vault,
  convertAssetsToShares,
} from '~/entities/vault'
import {
  getAssetUsdValue,
  getAssetUsdValueOrZero,
  getAssetOraclePrice,
  getCollateralOraclePrice,
  getCollateralShareOraclePrice,
  conservativePriceRatioNumber,
} from '~/services/pricing/priceProvider'
import { type SwapApiQuote, SwapperMode } from '~/entities/swap'
import { buildSwapRouteItems } from '~/utils/swapRouteItems'
import { formatNumber, formatSmartAmount, trimTrailingZeros } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import type { TxPlan } from '~/entities/txPlan'
import { getUtilisationWarning, getBorrowCapWarning } from '~/composables/useVaultWarnings'
import { useMultiplyCollateralOptions } from '~/composables/useMultiplyCollateralOptions'
import { useSwapQuotesParallel } from '~/composables/useSwapQuotesParallel'
import { useEulerProductOfVault } from '~/composables/useEulerLabels'
import { useEnsoRoute, encodeAdapterZapIn, previewAdapterZapIn, type BptAdapterConfigEntry } from '~/composables/useEnsoRoute'
import { previewArmDeposit, useArmRoute } from '~/composables/useArmRoute'
import type { ArmAdapterEntry } from '~/composables/useDeployConfig'

type MultiplyPlanParams = {
  supplyVaultAddress: string
  supplyAssetAddress: string
  supplyAmount: bigint
  supplySharesAmount?: bigint
  supplyIsSavings?: boolean
  longVaultAddress: string
  longAssetAddress: string
  borrowVaultAddress: string
  debtAmount: bigint
  quote?: SwapApiQuote
  swapperMode: SwapperMode
  subAccount: string
}

export interface UseMultiplyFormOptions {
  pair: Ref<AnyBorrowVaultPair | undefined>
  borrowVault: ComputedRef<Vault | undefined>
  collateralVault: ComputedRef<Vault | undefined>
  formTab: Ref<'borrow' | 'multiply'>

  resolvePendingSubAccount: () => Promise<string>
  isPendingSubAccountLoading: Ref<boolean>

  isGeoBlocked: ComputedRef<boolean>
  isMultiplyRestricted: ComputedRef<boolean>
}

const normalizeAddress = normalizeAddressOrEmpty

const calculateRoe = (
  supplyUsd: number | null,
  borrowUsd: number | null,
  supplyApyValue: number | null,
  borrowApyValue: number | null,
) => {
  if (supplyUsd === null || borrowUsd === null || supplyApyValue === null || borrowApyValue === null) {
    return null
  }
  const equity = supplyUsd - borrowUsd
  if (!Number.isFinite(equity) || equity <= 0) {
    return null
  }
  const net = supplyUsd * supplyApyValue - borrowUsd * borrowApyValue
  if (!Number.isFinite(net)) {
    return null
  }
  return net / equity
}

export const useMultiplyForm = (options: UseMultiplyFormOptions) => {
  const {
    pair: _pair,
    borrowVault,
    collateralVault,
    formTab: _formTab,
    resolvePendingSubAccount,
    isPendingSubAccountLoading,
    isGeoBlocked,
    isMultiplyRestricted,
  } = options

  const router = useRouter()
  const modal = useModal()
  const { error } = useToast()
  const { buildMultiplyPlan, executeTxPlan } = useEulerOperations()
  const wagmiConfig = useConfig()
  const { address, isConnected } = useAccount()
  const { refreshAllPositions, depositPositions } = useEulerAccount()
  const { eulerLensAddresses, eulerPeripheryAddresses, chainId: currentChainId } = useEulerAddresses()
  const { fetchSingleBalance } = useWallets()
  const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()
  const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()
  const { guardWithTerms } = useTermsOfUseGate()
  const { enableEnsoMultiply, bptAdapterConfig, armAdapterConfig } = useDeployConfig()
  const { getEnsoRoute, buildEnsoSwapQuote, buildAdapterSwapQuote } = useEnsoRoute()
  const { buildArmSwapQuote } = useArmRoute()

  const {
    runSimulation: runMultiplySimulation,
    simulationError: multiplySimulationError,
    clearSimulationError: clearMultiplySimulationError,
  } = useTxPlanSimulation()

  const multiplyPriceInvert = usePriceInvert(
    () => multiplyShortVault.value?.asset.symbol,
    () => multiplyLongVault.value?.asset.symbol,
  )

  const { slippage: multiplySlippage } = useSlippage()
  const {
    sortedQuoteCards: multiplyQuoteCardsSorted,
    selectedProvider: multiplySelectedProvider,
    selectedQuote: multiplySelectedQuote,
    effectiveQuote: multiplyEffectiveQuote,
    providersCount: multiplyProvidersCount,
    isLoading: isMultiplyQuoteLoading,
    quoteError: multiplyQuoteError,
    statusLabel: multiplyQuotesStatusLabel,
    getQuoteDiffPct,
    reset: resetMultiplyQuoteStateInternal,
    requestQuotes: requestMultiplyQuotes,
    requestCustomQuote: requestMultiplyCustomQuote,
    selectProvider: selectMultiplyQuote,
  } = useSwapQuotesParallel({ amountField: 'amountOut', compare: 'max' })

  // --- Form state ---
  const multiplyInputAmount = ref('')
  const multiplier = ref(1)
  const multiplyLongAmount = ref('')
  const multiplyShortAmount = ref('')
  const multiplySupplyVault: Ref<Vault | undefined> = ref()
  const multiplyAssetBalance: Ref<bigint> = ref(0n)
  const isMultiplySavingCollateral = ref(false)
  const isMultiplySubmitting = ref(false)
  const isMultiplyPreparing = ref(false)
  const multiplyPlan = ref<TxPlan | null>(null)
  const multiplyPlanParams = ref<MultiplyPlanParams | null>(null)

  // --- Vault aliases ---
  const multiplyLongVault = computed(() => collateralVault.value)
  const multiplyShortVault = computed(() => borrowVault.value)

  // --- Collateral options ---
  const { collateralOptions: multiplyCollateralOptions, collateralVaults: multiplyCollateralVaults } = useMultiplyCollateralOptions({
    currentVault: multiplySupplyVault,
    liabilityVault: multiplyShortVault,
  })

  // --- Product labels ---
  const multiplySupplyProduct = useEulerProductOfVault(computed(() => multiplySupplyVault.value?.address || ''))
  const multiplyLongProduct = useEulerProductOfVault(computed(() => multiplyLongVault.value?.address || ''))
  const multiplyShortProduct = useEulerProductOfVault(computed(() => multiplyShortVault.value?.address || ''))

  // --- Savings position ---
  const multiplySavingPosition = computed(() => {
    if (!multiplySupplyVault.value) return null
    return depositPositions.value.find(
      position => normalizeAddress(position.vault.address) === normalizeAddress(multiplySupplyVault.value?.address),
    ) || null
  })
  const multiplySavingBalance = computed(() => multiplySavingPosition.value?.shares || 0n)

  const multiplyBalance = computed(() => {
    if (!multiplySupplyVault.value) return 0n
    if (isMultiplySavingCollateral.value) return multiplySavingPosition.value?.assets || 0n
    return multiplyAssetBalance.value
  })

  // --- Debt calculation ---
  const multiplyDebtAmountNano = computed(() => {
    if (!multiplySupplyVault.value || !multiplyShortVault.value) return 0n
    if (!multiplyInputAmount.value || multiplier.value <= 1) return 0n

    let suppliedCollateral: bigint
    try {
      suppliedCollateral = valueToNano(multiplyInputAmount.value, multiplySupplyVault.value.asset.decimals)
    }
    catch {
      return 0n
    }
    if (!suppliedCollateral) return 0n

    const rawSharePrice = getCollateralShareOraclePrice(multiplyShortVault.value, multiplySupplyVault.value)
    const collateralPriceInfo = getCollateralOraclePrice(multiplyShortVault.value, multiplySupplyVault.value)
    const liabilityPrice = multiplyShortVault.value.liabilityPriceInfo

    if (!rawSharePrice || !rawSharePrice.amountIn || rawSharePrice.amountIn <= 0n) return 0n
    if (!collateralPriceInfo || collateralPriceInfo.amountOutMid <= 0n) return 0n
    if (!liabilityPrice || liabilityPrice.queryFailure || !liabilityPrice.amountOutAsk || liabilityPrice.amountOutAsk <= 0n || !liabilityPrice.amountIn || liabilityPrice.amountIn <= 0n) return 0n

    const collateralOutBid = collateralPriceInfo.amountOutBid || collateralPriceInfo.amountOutMid
    const collateralAmountIn = rawSharePrice.amountIn
    const suppliedCollateralValue = (suppliedCollateral * collateralOutBid) / collateralAmountIn
    if (!suppliedCollateralValue) return 0n

    const scaledMultiple = BigInt(Math.floor(multiplier.value * 1000))
    if (scaledMultiple <= 1000n) return 0n

    const multipliedCollateral = (suppliedCollateralValue * scaledMultiple) / 1000n
    if (multipliedCollateral <= suppliedCollateralValue) return 0n

    const totalDebtValue = multipliedCollateral - suppliedCollateralValue
    const liabilityOutAsk = liabilityPrice.amountOutAsk || liabilityPrice.amountOutMid
    const liabilityIn = liabilityPrice.amountIn
    const rawDebt = (totalDebtValue * liabilityIn) / liabilityOutAsk
    // Reduce borrow by slippage + buffer to keep position within LTV after
    // swap price impact (especially relevant for Enso routes on non-stable pools)
    const slippageBps = Math.round(multiplySlippage.value * 100)
    const safetyBps = Math.max(slippageBps * 3, 100) // 3× slippage or 1% min
    return rawDebt * BigInt(10000 - safetyBps) / 10000n
  })

  // --- LTV / multiplier bounds ---
  const multiplyBorrowLtv = computed(() => {
    if (!multiplySupplyVault.value || !multiplyShortVault.value) return 0
    const match = multiplyShortVault.value.collateralLTVs.find(
      ltv => normalizeAddress(ltv.collateral) === normalizeAddress(multiplySupplyVault.value?.address),
    )
    return match ? nanoToValue(match.borrowLTV, 2) : 0
  })

  const multiplyMaxMultiplier = computed(() => {
    const ltvPercent = multiplyBorrowLtv.value
    if (!ltvPercent || !Number.isFinite(ltvPercent)) return 1
    const ltv = ltvPercent / 100
    if (ltv <= 0 || ltv >= 0.99) return 1
    const max = 1 / (1 - ltv)
    return Math.max(1, Math.floor(max * 100) / 100)
  })

  const multiplyMinMultiplier = computed(() => {
    return multiplyMaxMultiplier.value <= 1 ? 0 : 1
  })

  const multiplySupplyAmountNano = computed(() => {
    if (!multiplySupplyVault.value || !multiplyInputAmount.value) return 0n
    try {
      return valueToNano(multiplyInputAmount.value, multiplySupplyVault.value.asset.decimals)
    }
    catch {
      return 0n
    }
  })

  // --- Same-asset detection ---
  const multiplyIsSameAsset = computed(() => {
    if (!multiplyShortVault.value || !multiplyLongVault.value) return false
    return normalizeAddress(multiplyShortVault.value.asset.address) === normalizeAddress(multiplyLongVault.value.asset.address)
  })

  // --- Swap amounts ---
  const multiplySwapAmountIn = computed(() => {
    if (multiplyEffectiveQuote.value) return BigInt(multiplyEffectiveQuote.value.amountIn || 0)
    if (multiplyIsSameAsset.value && multiplyDebtAmountNano.value > 0n) return multiplyDebtAmountNano.value
    return 0n
  })

  const multiplySwapAmountOut = computed(() => {
    if (multiplyEffectiveQuote.value) return BigInt(multiplyEffectiveQuote.value.amountOut || 0)
    if (multiplyIsSameAsset.value && multiplyDebtAmountNano.value > 0n) return multiplyDebtAmountNano.value
    return 0n
  })

  const multiplySwapReady = computed(() => {
    if (isMultiplyQuoteLoading.value) return false
    return Boolean(multiplyEffectiveQuote.value || (multiplyIsSameAsset.value && multiplyDebtAmountNano.value > 0n))
  })

  // --- USD values (async) ---
  const multiplySupplyValueUsd = ref<number | null>(null)
  const multiplyLongValueUsd = ref<number | null>(null)
  const multiplyBorrowValueUsd = ref<number | null>(null)

  watchEffect(async () => {
    if (!multiplySupplyVault.value || !multiplySupplyAmountNano.value) {
      multiplySupplyValueUsd.value = null
      return
    }
    multiplySupplyValueUsd.value = await getAssetUsdValueOrZero(multiplySupplyAmountNano.value, multiplySupplyVault.value, 'off-chain')
  })

  watchEffect(async () => {
    if (!multiplyLongVault.value || !multiplySwapAmountOut.value) {
      multiplyLongValueUsd.value = null
      return
    }
    multiplyLongValueUsd.value = await getAssetUsdValueOrZero(multiplySwapAmountOut.value, multiplyLongVault.value, 'off-chain')
  })

  watchEffect(async () => {
    if (!multiplyShortVault.value || !multiplyDebtAmountNano.value) {
      multiplyBorrowValueUsd.value = null
      return
    }
    multiplyBorrowValueUsd.value = await getAssetUsdValueOrZero(multiplyDebtAmountNano.value, multiplyShortVault.value, 'off-chain')
  })

  const multiplyTotalSupplyUsd = computed(() => {
    if (multiplySupplyValueUsd.value === null) return null
    return multiplySupplyValueUsd.value + (multiplyLongValueUsd.value || 0)
  })

  // --- APYs ---
  const multiplySupplyApy = computed(() => {
    if (!multiplySupplyVault.value) return null
    const base = nanoToValue(multiplySupplyVault.value.interestRateInfo.supplyAPY || 0n, 25)
    return withIntrinsicSupplyApy(base, multiplySupplyVault.value.asset.address) + getSupplyRewardApy(multiplySupplyVault.value.address)
  })

  const multiplyLongApy = computed(() => {
    if (!multiplyLongVault.value) return null
    const base = nanoToValue(multiplyLongVault.value.interestRateInfo.supplyAPY || 0n, 25)
    return withIntrinsicSupplyApy(base, multiplyLongVault.value.asset.address) + getSupplyRewardApy(multiplyLongVault.value.address)
  })

  const multiplyBorrowApy = computed(() => {
    if (!multiplyShortVault.value) return null
    const base = nanoToValue(multiplyShortVault.value.interestRateInfo.borrowAPY || 0n, 25)
    return withIntrinsicBorrowApy(base, multiplyShortVault.value.asset.address) - getBorrowRewardApy(multiplyShortVault.value.address, multiplySupplyVault.value?.address)
  })

  const multiplyWeightedSupplyApy = computed(() => {
    if (multiplySupplyValueUsd.value === null || multiplySupplyApy.value === null) return null
    const longUsd = multiplyLongValueUsd.value
    const longApy = multiplyLongApy.value
    if (!longUsd || longUsd <= 0 || longApy === null) return multiplySupplyApy.value
    const total = multiplySupplyValueUsd.value + longUsd
    if (!Number.isFinite(total) || total <= 0) return null
    return (multiplySupplyValueUsd.value * multiplySupplyApy.value + longUsd * longApy) / total
  })

  // --- ROE ---
  const multiplyRoeBefore = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (multiplySupplyValueUsd.value === null) return null
    return 0
  })

  const multiplyRoeAfter = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (
      multiplyTotalSupplyUsd.value === null
      || multiplyBorrowValueUsd.value === null
      || multiplyWeightedSupplyApy.value === null
      || multiplyBorrowApy.value === null
    ) return null
    return calculateRoe(
      multiplyTotalSupplyUsd.value,
      multiplyBorrowValueUsd.value,
      multiplyWeightedSupplyApy.value,
      multiplyBorrowApy.value,
    )
  })

  // --- Health / LTV ---
  const multiplyLiquidationLtv = computed(() => {
    if (!multiplySupplyVault.value || !multiplyShortVault.value) return null
    const match = multiplyShortVault.value.collateralLTVs.find(
      ltv => normalizeAddress(ltv.collateral) === normalizeAddress(multiplySupplyVault.value?.address),
    )
    return match ? nanoToValue(match.liquidationLTV, 2) : null
  })

  const multiplyCurrentLtv = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (multiplySupplyValueUsd.value === null || multiplySupplyValueUsd.value <= 0) return null
    return 0
  })

  const multiplyNextLtv = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (multiplyTotalSupplyUsd.value === null || multiplyBorrowValueUsd.value === null) return null
    if (multiplyTotalSupplyUsd.value <= 0) return null
    return (multiplyBorrowValueUsd.value / multiplyTotalSupplyUsd.value) * 100
  })

  const multiplyCurrentLiquidationLtv = computed(() => null as number | null)
  const multiplyNextLiquidationLtv = computed(() => multiplyLiquidationLtv.value)

  const multiplyNextHealth = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (multiplyNextLtv.value === null || multiplyLiquidationLtv.value === null) return null
    if (multiplyNextLtv.value <= 0) return null
    return multiplyLiquidationLtv.value / multiplyNextLtv.value
  })

  const multiplyCurrentHealth = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (multiplyLiquidationLtv.value === null || multiplyCurrentLtv.value === null) return null
    if (multiplyCurrentLtv.value <= 0) return Number.POSITIVE_INFINITY
    return multiplyLiquidationLtv.value / multiplyCurrentLtv.value
  })

  // --- Price ratio ---
  const multiplyPriceRatio = computed(() => {
    if (!multiplyLongVault.value || !multiplyShortVault.value) return null
    const collateralPrice = getCollateralOraclePrice(multiplyShortVault.value, multiplyLongVault.value)
    const borrowPrice = getAssetOraclePrice(multiplyShortVault.value)
    return conservativePriceRatioNumber(collateralPrice, borrowPrice)
  })

  const multiplyCurrentLiquidationPrice = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (!multiplyPriceRatio.value || !multiplyCurrentHealth.value) return null
    if (!Number.isFinite(multiplyCurrentHealth.value)) return null
    if (multiplyCurrentHealth.value <= 0) return null
    return multiplyPriceRatio.value / multiplyCurrentHealth.value
  })

  const multiplyNextLiquidationPrice = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (!multiplyPriceRatio.value || !multiplyNextHealth.value) return null
    if (multiplyNextHealth.value <= 0) return null
    return multiplyPriceRatio.value / multiplyNextHealth.value
  })

  // --- Display ---
  const multiplyCurrentPrice = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (!multiplySwapReady.value || !multiplyShortVault.value || !multiplyLongVault.value) return null
    const amountIn = Number(formatUnits(multiplySwapAmountIn.value, Number(multiplyShortVault.value.asset.decimals)))
    const amountOut = Number(formatUnits(multiplySwapAmountOut.value, Number(multiplyLongVault.value.asset.decimals)))
    if (!amountIn || !amountOut) return null
    return {
      value: amountIn / amountOut,
      symbol: `${multiplyShortVault.value.asset.symbol}/${multiplyLongVault.value.asset.symbol}`,
    }
  })

  const multiplySwapSummary = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (!multiplySwapReady.value || !multiplyShortVault.value || !multiplyLongVault.value) return null
    const amountIn = formatUnits(multiplySwapAmountIn.value, Number(multiplyShortVault.value.asset.decimals))
    const amountOut = formatUnits(multiplySwapAmountOut.value, Number(multiplyLongVault.value.asset.decimals))
    return {
      from: `${formatSmartAmount(amountIn)} ${multiplyShortVault.value.asset.symbol}`,
      to: `${formatSmartAmount(amountOut)} ${multiplyLongVault.value.asset.symbol}`,
    }
  })

  const multiplyPriceImpact = ref<number | null>(null)

  watchEffect(async () => {
    if (isMultiplyQuoteLoading.value) {
      multiplyPriceImpact.value = null
      return
    }
    if (!multiplySwapReady.value || !multiplyShortVault.value || !multiplyLongVault.value) {
      multiplyPriceImpact.value = null
      return
    }
    const swapIn = multiplySwapAmountIn.value
    const swapOut = multiplySwapAmountOut.value
    const shortVault = multiplyShortVault.value
    const longVault = multiplyLongVault.value
    const amountInUsd = await getAssetUsdValue(swapIn, shortVault, 'off-chain')
    const amountOutUsd = await getAssetUsdValue(swapOut, longVault, 'off-chain')
    if (!amountInUsd || !amountOutUsd) {
      multiplyPriceImpact.value = null
      return
    }
    const impact = (amountOutUsd / amountInUsd - 1) * 100
    if (!Number.isFinite(impact)) {
      multiplyPriceImpact.value = null
      return
    }
    multiplyPriceImpact.value = impact
  })

  const multiplyRoutedVia = computed(() => {
    if (isMultiplyQuoteLoading.value) return null
    if (!multiplyEffectiveQuote.value?.route?.length) return null
    return multiplyEffectiveQuote.value.route.map(route => route.providerName).join(', ')
  })

  const multiplyRouteItems = computed(() => {
    if (!multiplyLongVault.value) return []
    return buildSwapRouteItems({
      quoteCards: multiplyQuoteCardsSorted.value,
      getQuoteDiffPct,
      decimals: Number(multiplyLongVault.value.asset.decimals),
      symbol: multiplyLongVault.value.asset.symbol,
      formatAmount: formatNumber,
    })
  })

  const multiplyRouteEmptyMessage = computed(() => {
    if (!multiplyProvidersCount.value) return 'Enter amount to fetch quotes'
    return 'No quotes found'
  })

  // --- Validation ---
  const multiplyErrorText = computed(() => {
    if (!multiplySupplyVault.value || !multiplyShortVault.value) return null
    if (multiplyBalance.value < valueToNano(multiplyInputAmount.value, multiplySupplyVault.value.asset.decimals)) {
      return 'Not enough balance'
    }
    if (multiplyDebtAmountNano.value > 0n && (multiplyShortVault.value.supply || 0n) < multiplyDebtAmountNano.value) {
      return 'Not enough liquidity in the vault'
    }
    return null
  })

  const isMultiplySubmitDisabled = computed(() => {
    if (!isConnected.value) return false
    if (!multiplySupplyVault.value || !multiplyLongVault.value || !multiplyShortVault.value) return true
    if (!multiplyInputAmount.value || multiplyDebtAmountNano.value <= 0n) return true
    if (multiplyErrorText.value) return true
    if (isPendingSubAccountLoading.value) return true
    const isSameAsset = normalizeAddress(multiplyLongVault.value.asset.address) === normalizeAddress(multiplyShortVault.value.asset.address)
    if (!isSameAsset && !multiplySelectedQuote.value) return true
    return false
  })

  // --- Warnings ---
  const multiplyFormWarnings = computed(() => {
    if (!multiplyShortVault.value) return []
    return [
      getUtilisationWarning(multiplyShortVault.value, 'borrow'),
      getBorrowCapWarning(multiplyShortVault.value),
    ]
  })

  // --- Swap quote ---
  const requestMultiplyQuote = useDebounceFn(async () => {
    multiplyQuoteError.value = null

    if (!multiplySupplyVault.value || !multiplyLongVault.value || !multiplyShortVault.value || !multiplyInputAmount.value) {
      resetMultiplyQuoteState()
      return
    }

    const debtAmount = multiplyDebtAmountNano.value
    if (!debtAmount || debtAmount <= 0n) {
      resetMultiplyQuoteState()
      return
    }

    if (normalizeAddress(multiplyLongVault.value.asset.address) === normalizeAddress(multiplyShortVault.value.asset.address)) {
      resetMultiplyQuoteState()
      setMultiplyAmounts(debtAmount, debtAmount)
      return
    }

    let account: Address
    try {
      account = (await resolvePendingSubAccount()) as Address
    }
    catch {
      resetMultiplyQuoteState()
      multiplyQuoteError.value = 'Unable to resolve position'
      return
    }

    setMultiplyAmounts(null, null)

    const logContext = {
      fromVault: multiplyShortVault.value?.address,
      toVault: multiplyLongVault.value?.address,
      amount: formatUnits(debtAmount, Number(multiplyShortVault.value.asset.decimals)),
      slippage: multiplySlippage.value,
      swapperMode: SwapperMode.EXACT_IN,
      isRepay: false,
    }

    const collateralVaultAddr = multiplyLongVault.value.address as Address
    const armEntry: ArmAdapterEntry | undefined = armAdapterConfig[collateralVaultAddr.toLowerCase()]
      || armAdapterConfig[collateralVaultAddr]

    if (armEntry && eulerPeripheryAddresses.value?.swapper && eulerPeripheryAddresses.value?.swapVerifier) {
      const swapperAddr = eulerPeripheryAddresses.value.swapper as Address
      const swapVerifierAddr = eulerPeripheryAddresses.value.swapVerifier as Address
      const tokenIn = multiplyShortVault.value.asset.address as Address
      const tokenOut = multiplyLongVault.value.asset.address as Address
      const borrowVaultAddr = multiplyShortVault.value.address as Address

      await requestMultiplyCustomQuote('arm-deposit', async () => {
        const deadline = Math.floor(Date.now() / 1000) + 1800
        const { expectedArmOut, minArmOut } = await previewArmDeposit(
          wagmiConfig,
          armEntry.armContract as Address,
          debtAmount,
          multiplySlippage.value,
        )

        const quote = buildArmSwapQuote({
          swapperAddress: swapperAddr,
          swapVerifierAddress: swapVerifierAddr,
          collateralVault: collateralVaultAddr,
          borrowVault: borrowVaultAddr,
          subAccount: account,
          tokenIn,
          tokenOut,
          borrowAmount: debtAmount,
          deadline,
          armAddress: armEntry.armContract as Address,
          minAmountOut: minArmOut,
        })

        quote.amountOut = expectedArmOut.toString()
        quote.amountOutMin = minArmOut.toString()
        return quote
      }, { logContext })
    }
    else if (enableEnsoMultiply && eulerPeripheryAddresses.value?.swapper && currentChainId.value) {
      const swapperAddr = eulerPeripheryAddresses.value.swapper as Address
      const swapVerifierAddr = eulerPeripheryAddresses.value.swapVerifier as Address
      const tokenIn = multiplyShortVault.value.asset.address as Address
      const tokenOut = multiplyLongVault.value.asset.address as Address
      const borrowVaultAddr = multiplyShortVault.value.address as Address
      const chainId = currentChainId.value
      const adapterEntry = bptAdapterConfig[collateralVaultAddr.toLowerCase()]
        || bptAdapterConfig[collateralVaultAddr]

      if (adapterEntry && adapterEntry.pool && adapterEntry.wrapper && adapterEntry.numTokens) {
        await requestMultiplyCustomQuote('balancer-adapter', async () => {
          const deadline = Math.floor(Date.now() / 1000) + 1800
          const fullEntry = adapterEntry as BptAdapterConfigEntry
          const { expectedBptOut, minBptOut } = await previewAdapterZapIn(
            wagmiConfig,
            fullEntry,
            debtAmount,
            multiplySlippage.value,
          )
          const adapterCalldata = encodeAdapterZapIn(fullEntry.tokenIndex, debtAmount, minBptOut)

          const quote = buildAdapterSwapQuote({
            swapperAddress: swapperAddr,
            swapVerifierAddress: swapVerifierAddr,
            collateralVault: collateralVaultAddr,
            borrowVault: borrowVaultAddr,
            subAccount: account,
            tokenIn,
            tokenOut,
            borrowAmount: debtAmount,
            deadline,
            adapterAddress: fullEntry.adapter as Address,
            adapterCalldata,
            minAmountOut: minBptOut,
          })

          quote.amountOut = expectedBptOut.toString()
          quote.amountOutMin = minBptOut.toString()
          return quote
        }, { logContext })
      }
      else {
        await requestMultiplyCustomQuote('enso', async () => {
          const ensoRoute = await getEnsoRoute({
            chainId,
            fromAddress: swapperAddr,
            tokenIn,
            tokenOut,
            amountIn: debtAmount,
            receiver: swapperAddr,
            slippage: multiplySlippage.value,
          })

          const deadline = Math.floor(Date.now() / 1000) + 1800

          return buildEnsoSwapQuote(ensoRoute, {
            swapperAddress: swapperAddr,
            swapVerifierAddress: swapVerifierAddr,
            collateralVault: collateralVaultAddr,
            borrowVault: borrowVaultAddr,
            subAccount: account,
            tokenIn,
            tokenOut,
            borrowAmount: debtAmount,
            deadline,
          })
        }, { logContext })
      }
    }
    else {
      const requestParams = {
        tokenIn: multiplyShortVault.value.asset.address as Address,
        tokenOut: multiplyLongVault.value.asset.address as Address,
        accountIn: account,
        accountOut: account,
        amount: debtAmount,
        vaultIn: multiplyShortVault.value.address as Address,
        receiver: multiplyLongVault.value.address as Address,
        slippage: multiplySlippage.value,
        swapperMode: SwapperMode.EXACT_IN,
        isRepay: false,
        targetDebt: 0n,
        currentDebt: 0n,
      }
      await requestMultiplyQuotes(requestParams, { logContext })
    }
  }, 500)

  // --- Helpers ---
  const setMultiplyAmounts = (longAmount?: bigint | null, shortAmount?: bigint | null) => {
    if (!multiplySupplyVault.value || !multiplyLongVault.value || !multiplyShortVault.value || !multiplyInputAmount.value) {
      multiplyLongAmount.value = ''
      multiplyShortAmount.value = ''
      return
    }
    let baseNano: bigint
    try {
      baseNano = valueToNano(multiplyInputAmount.value, multiplySupplyVault.value.asset.decimals)
    }
    catch {
      multiplyLongAmount.value = ''
      multiplyShortAmount.value = ''
      return
    }
    if (!baseNano) {
      multiplyLongAmount.value = ''
      multiplyShortAmount.value = ''
      return
    }
    multiplyLongAmount.value = longAmount && longAmount > 0n
      ? trimTrailingZeros(formatUnits(longAmount, Number(multiplyLongVault.value.asset.decimals)))
      : ''
    multiplyShortAmount.value = shortAmount && shortAmount > 0n
      ? trimTrailingZeros(formatUnits(shortAmount, Number(multiplyShortVault.value.asset.decimals)))
      : ''
  }

  const resetMultiplyQuoteState = () => {
    resetMultiplyQuoteStateInternal()
    setMultiplyAmounts(null, null)
  }

  const onRefreshMultiplyQuotes = () => {
    resetMultiplyQuoteState()
    isMultiplyQuoteLoading.value = true
    requestMultiplyQuote()
  }

  // --- Actions: form input handlers ---
  const onMultiplyInput = () => {
    clearMultiplySimulationError()
    if (!multiplyInputAmount.value) {
      resetMultiplyQuoteState()
      return
    }
    requestMultiplyQuote()
  }

  const onMultiplierInput = () => {
    clearMultiplySimulationError()
    if (!multiplyInputAmount.value) {
      resetMultiplyQuoteState()
      return
    }
    requestMultiplyQuote()
  }

  const onMultiplyCollateralChange = (selectedIndex: number) => {
    clearMultiplySimulationError()
    const nextVault = multiplyCollateralVaults.value[selectedIndex]
    const nextOption = multiplyCollateralOptions.value[selectedIndex]
    if (!nextVault || !nextOption) return

    const nextIsSaving = nextOption.type === 'saving'
    const vaultChanged = !multiplySupplyVault.value
      || normalizeAddress(multiplySupplyVault.value.address) !== normalizeAddress(nextVault.address)
    const savingChanged = nextIsSaving !== isMultiplySavingCollateral.value
    if (vaultChanged || savingChanged) {
      multiplySupplyVault.value = nextVault
      isMultiplySavingCollateral.value = nextIsSaving
      multiplyInputAmount.value = ''
      resetMultiplyQuoteState()
    }
  }

  // --- Actions: submit & send ---
  const submitMultiply = async () => {
    if (isMultiplyPreparing.value || isGeoBlocked.value || isMultiplyRestricted.value) return
    isMultiplyPreparing.value = true
    try {
      await guardWithTerms(async () => {
        if (isMultiplySubmitting.value || !isConnected.value) return
        if (!multiplySupplyVault.value || !multiplyLongVault.value || !multiplyShortVault.value) return
        if (!multiplyInputAmount.value || multiplyDebtAmountNano.value <= 0n) return
        if (multiplyErrorText.value) return

        const supplyAmountNano = valueToNano(multiplyInputAmount.value || '0', multiplySupplyVault.value.asset.decimals)
        let supplySharesAmount: bigint | undefined
        if (isMultiplySavingCollateral.value) {
          if (!multiplySavingPosition.value) {
            error('No savings balance for selected collateral')
            return
          }
          if (multiplySavingPosition.value.assets === supplyAmountNano) {
            supplySharesAmount = multiplySavingBalance.value
          }
          else {
            supplySharesAmount = await convertAssetsToShares(multiplySupplyVault.value.address, supplyAmountNano)
          }
          if (!supplySharesAmount || supplySharesAmount <= 0n) {
            error('Unable to resolve savings amount')
            return
          }
        }
        const debtAmount = multiplyDebtAmountNano.value
        if (!supplyAmountNano || debtAmount <= 0n) return

        const isSameAsset = normalizeAddress(multiplyLongVault.value.asset.address) === normalizeAddress(multiplyShortVault.value.asset.address)
        const quote = isSameAsset ? null : multiplySelectedQuote.value
        if (!isSameAsset && !quote) return

        let subAccount: string
        try {
          subAccount = await resolvePendingSubAccount()
        }
        catch (e) {
          logWarn('multiply/resolveSubaccount', e)
          error('Unable to resolve position')
          return
        }

        const planParams: MultiplyPlanParams = {
          supplyVaultAddress: multiplySupplyVault.value.address,
          supplyAssetAddress: multiplySupplyVault.value.asset.address,
          supplyAmount: supplyAmountNano,
          supplySharesAmount,
          supplyIsSavings: isMultiplySavingCollateral.value,
          longVaultAddress: multiplyLongVault.value.address,
          longAssetAddress: multiplyLongVault.value.asset.address,
          borrowVaultAddress: multiplyShortVault.value.address,
          debtAmount,
          quote: quote || undefined,
          swapperMode: SwapperMode.EXACT_IN,
          subAccount,
        }
        multiplyPlanParams.value = planParams

        try {
          multiplyPlan.value = await buildMultiplyPlan({
            ...planParams,
            includePermit2Call: false,
          })
        }
        catch (e) {
          logWarn('multiply/buildPlan', e)
          multiplyPlan.value = null
        }

        if (multiplyPlan.value) {
          const ok = await runMultiplySimulation(multiplyPlan.value)
          if (!ok) return
        }

        modal.open(OperationReviewModal, {
          props: {
            type: 'borrow',
            asset: multiplyShortVault.value.asset,
            amount: multiplyShortAmount.value || formatUnits(debtAmount, Number(multiplyShortVault.value.asset.decimals)),
            plan: multiplyPlan.value || undefined,
            supplyingAssetForBorrow: multiplySupplyVault.value.asset,
            supplyingAmount: multiplyInputAmount.value,
            swapToAsset: quote ? multiplyLongVault.value.asset : undefined,
            swapToAmount: quote ? multiplyLongAmount.value : undefined,
            subAccount,
            onConfirm: () => {
              setTimeout(() => {
                sendMultiply()
              }, 400)
            },
          },
        })
      })
    }
    finally {
      isMultiplyPreparing.value = false
    }
  }

  const sendMultiply = async () => {
    if (!multiplyPlanParams.value) return
    isMultiplySubmitting.value = true
    try {
      const plan = await buildMultiplyPlan({
        ...multiplyPlanParams.value,
        includePermit2Call: true,
      })
      multiplyPlan.value = plan
      await executeTxPlan(plan)
      modal.close()
      refreshAllPositions(eulerLensAddresses.value, address.value || '')
      setTimeout(() => {
        router.replace('/portfolio')
      }, 400)
    }
    catch (e) {
      logWarn('multiply/send', e)
      error('Transaction failed')
    }
    finally {
      isMultiplySubmitting.value = false
    }
  }

  // --- Balance ---
  const updateMultiplyAssetBalance = async () => {
    if (multiplySupplyVault.value?.asset.address && isConnected.value) {
      multiplyAssetBalance.value = await fetchSingleBalance(multiplySupplyVault.value.asset.address)
    }
    else {
      multiplyAssetBalance.value = 0n
    }
  }

  // --- Init ---
  const initMultiplySupplyVault = (vault: Vault) => {
    multiplySupplyVault.value = vault
    isMultiplySavingCollateral.value = false
  }

  // --- Watchers ---
  watch([multiplyEffectiveQuote, multiplyIsSameAsset, multiplyDebtAmountNano], () => {
    if (multiplyIsSameAsset.value && multiplyDebtAmountNano.value > 0n) {
      setMultiplyAmounts(multiplyDebtAmountNano.value, multiplyDebtAmountNano.value)
      return
    }
    if (multiplyEffectiveQuote.value) {
      const amountOut = BigInt(multiplyEffectiveQuote.value.amountOut || 0)
      const amountIn = BigInt(multiplyEffectiveQuote.value.amountIn || 0)
      setMultiplyAmounts(amountOut, amountIn)
      return
    }
    setMultiplyAmounts(null, null)
  }, { immediate: true })

  watch(multiplySlippage, () => {
    clearMultiplySimulationError()
    if (!multiplyInputAmount.value) {
      resetMultiplyQuoteState()
      return
    }
    requestMultiplyQuote()
  })

  watch([multiplySupplyVault, multiplyLongVault, multiplyShortVault, isMultiplySavingCollateral], () => {
    clearMultiplySimulationError()
    resetMultiplyQuoteState()
    if (multiplyInputAmount.value) {
      requestMultiplyQuote()
    }
  })

  watch(multiplySupplyVault, async (newVault) => {
    if (newVault?.asset.address && isConnected.value) {
      multiplyAssetBalance.value = await fetchSingleBalance(newVault.asset.address)
    }
    else {
      multiplyAssetBalance.value = 0n
    }
  })

  watch(multiplySelectedQuote, () => {
    clearMultiplySimulationError()
  })

  watch(multiplyMaxMultiplier, (max) => {
    let next = multiplier.value
    const min = multiplyMinMultiplier.value
    if (!max || max < min) {
      next = min
    }
    else {
      if (next > max) next = max
      if (next < min) next = min
    }
    if (next !== multiplier.value) {
      multiplier.value = next
    }
    if (!multiplyInputAmount.value) {
      resetMultiplyQuoteState()
      return
    }
    requestMultiplyQuote()
  }, { immediate: true })

  // --- Reset ---
  const resetOnTabSwitch = () => {
    clearMultiplySimulationError()
  }

  return {
    // Form state
    multiplyInputAmount,
    multiplier,
    multiplyLongAmount,
    multiplyShortAmount,
    multiplySupplyVault,
    multiplyAssetBalance,
    isMultiplySavingCollateral,
    isMultiplySubmitting,
    isMultiplyPreparing,
    multiplyPlan,

    // Vault aliases
    multiplyLongVault,
    multiplyShortVault,

    // Collateral
    multiplyCollateralOptions,
    multiplyCollateralVaults,
    multiplySavingPosition,
    multiplySavingBalance,
    multiplyBalance,

    // Debt
    multiplyDebtAmountNano,
    multiplyBorrowLtv,
    multiplyMaxMultiplier,
    multiplyMinMultiplier,
    multiplySupplyAmountNano,
    multiplyIsSameAsset,

    // Swap
    multiplySwapAmountIn,
    multiplySwapAmountOut,
    multiplySwapReady,
    multiplySlippage,
    multiplySelectedProvider,
    multiplyQuoteCardsSorted,
    isMultiplyQuoteLoading,
    multiplyQuoteError,
    multiplyQuotesStatusLabel,
    selectMultiplyQuote,

    // USD values
    multiplySupplyValueUsd,
    multiplyLongValueUsd,
    multiplyBorrowValueUsd,
    multiplyTotalSupplyUsd,

    // APY
    multiplySupplyApy,
    multiplyLongApy,
    multiplyBorrowApy,
    multiplyWeightedSupplyApy,

    // ROE
    multiplyRoeBefore,
    multiplyRoeAfter,

    // Health / LTV
    multiplyLiquidationLtv,
    multiplyCurrentLtv,
    multiplyNextLtv,
    multiplyCurrentLiquidationLtv,
    multiplyNextLiquidationLtv,
    multiplyNextHealth,
    multiplyCurrentHealth,

    // Price
    multiplyPriceRatio,
    multiplyCurrentLiquidationPrice,
    multiplyNextLiquidationPrice,
    multiplyCurrentPrice,
    multiplyPriceInvert,

    // Display
    multiplySwapSummary,
    multiplyPriceImpact,
    multiplyRoutedVia,
    multiplyRouteItems,
    multiplyRouteEmptyMessage,
    multiplySimulationError,

    // Validation
    multiplyErrorText,
    isMultiplySubmitDisabled,
    multiplyFormWarnings,

    // Product labels
    multiplySupplyProduct,
    multiplyLongProduct,
    multiplyShortProduct,

    // Actions
    onMultiplyInput,
    onMultiplierInput,
    onMultiplyCollateralChange,
    onRefreshMultiplyQuotes,
    submitMultiply,
    sendMultiply,
    updateMultiplyAssetBalance,
    initMultiplySupplyVault,
    resetOnTabSwitch,
  }
}
