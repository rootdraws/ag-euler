import type { ComputedRef } from 'vue'
import { useAccount } from '@wagmi/vue'
import { formatUnits, type Address, type Abi, zeroAddress } from 'viem'
import { logWarn } from '~/utils/errorHandling'
import { FixedPoint } from '~/utils/fixed-point'
import { getPublicClient } from '~/utils/public-client'
import { useModal } from '~/components/ui/composables/useModal'
import { OperationReviewModal, SwapTokenSelector, SlippageSettingsModal } from '#components'
import { useTermsOfUseGate } from '~/composables/useTermsOfUseGate'
import { useToast } from '~/components/ui/composables/useToast'
import { eulerAccountLensABI } from '~/entities/euler/abis'
import {
  getNetAPY,
  type Vault,
  type SecuritizeVault,
  type VaultAsset,
} from '~/entities/vault'
import {
  getAssetUsdValueOrZero,
  getCollateralUsdValueOrZero,
} from '~/services/pricing/priceProvider'
import type { TxPlan } from '~/entities/txPlan'
import { isAnyVaultBlockedByCountry, isVaultRestrictedByCountry } from '~/composables/useGeoBlock'
import { useVaultRegistry } from '~/composables/useVaultRegistry'
import { useSwapQuotesParallel } from '~/composables/useSwapQuotesParallel'
import type { SwapApiQuote } from '~/entities/swap'
import type { SwapApiRequestInput } from '~/composables/useSwapApi'
import { buildSwapRouteItems } from '~/utils/swapRouteItems'
import { formatSmartAmount } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import { normalizeAddressOrEmpty } from '~/utils/accountPositionHelpers'

export interface UseCollateralFormOptions {
  mode: 'supply' | 'withdraw'

  needsSwap: ComputedRef<boolean>
  effectiveBalance: ComputedRef<bigint>

  computePriceFixed: (
    position: NonNullable<ReturnType<ReturnType<typeof useEulerAccount>['getPositionBySubAccountIndex']>>,
    borrowVault?: Vault,
    collateralVault?: Vault | SecuritizeVault,
  ) => FixedPoint

  computeLiquidationPrice: (
    position: NonNullable<ReturnType<ReturnType<typeof useEulerAccount>['getPositionBySubAccountIndex']>>,
  ) => number | undefined

  validateEstimate: (ctx: {
    amountFixed: FixedPoint
    suppliedFixed: FixedPoint
    borrowedFixed: FixedPoint
    priceFixed: FixedPoint
    collateralValue: FixedPoint
    userLtvFixed: FixedPoint
    needsSwap: boolean
  }) => void

  buildDirectPlan: (ctx: {
    vaultAddress: string
    assetAddress: string
    amountNano: bigint
    subAccount?: string
    includePermit2Call?: boolean
  }) => Promise<TxPlan>

  buildSwapPlan: (quote: SwapApiQuote, ctx: {
    vaultAddress: string
    amountNano: bigint
    subAccount?: string
    includePermit2Call?: boolean
  }) => Promise<TxPlan>

  requestSwapQuoteParams: (ctx: {
    userAddr: Address
    subAccountAddr: Address
    amountNano: bigint
    slippage: number
    asset: VaultAsset
    vaultAddress: string
  }) => SwapApiRequestInput | null

  getSwapOutputAsset: () => VaultAsset | undefined

  reviewLabel: string
  reviewType: string
  swapReviewType: string
  getReviewAsset: (needsSwap: boolean) => VaultAsset | undefined
  getSwapToAsset: () => VaultAsset | undefined

  onAfterLoad?: () => Promise<void> | void
  onAfterSend?: () => Promise<void> | void
}

export const useCollateralForm = (options: UseCollateralFormOptions) => {
  const router = useRouter()
  const route = useRoute()
  const modal = useModal()
  const { error } = useToast()
  const { getSubmitLabel, getSubmitDisabled, guardWithTerms } = useTermsOfUseGate()
  const submitLabel = getSubmitLabel(options.reviewLabel)
  const { executeTxPlan } = useEulerOperations()
  const { isConnected, address } = useAccount()
  const positionIndex = usePositionIndex()
  const { isPositionsLoaded, getPositionBySubAccountIndex } = useEulerAccount()
  const { getSupplyRewardApy, getBorrowRewardApy } = useRewardsApy()
  const { withIntrinsicBorrowApy, withIntrinsicSupplyApy } = useIntrinsicApy()
  const { runSimulation, simulationError, clearSimulationError } = useTxPlanSimulation()
  const { isReady: isVaultsReady } = useVaults()
  const { getOrFetch } = useVaultRegistry()
  const { eulerLensAddresses, isReady: isEulerAddressesReady, loadEulerConfig } = useEulerAddresses()
  const { EVM_PROVIDER_URL } = useEulerConfig()

  // --- Shared reactive state ---
  const isLoading = ref(false)
  const isSubmitting = ref(false)
  const isPreparing = ref(false)
  const isEstimatesLoading = ref(false)
  const amount = ref('')
  const plan = ref<TxPlan | null>(null)
  const estimateNetAPY = ref(0)
  const estimateUserLTV = ref(0n)
  const estimateHealth = ref(0n)
  const estimatesError = ref('')
  const selectedCollateral = ref<Vault | SecuritizeVault | null>(null)
  const selectedCollateralAssets = ref(0n)
  const lastCollateralAddress = ref('')

  // --- Swap infrastructure ---
  const { enableSwapDeposit } = useDeployConfig()
  const { slippage: swapSlippage } = useSlippage()
  const {
    sortedQuoteCards: swapQuoteCardsSorted,
    selectedProvider: swapSelectedProvider,
    selectedQuote: swapSelectedQuote,
    effectiveQuote: swapEffectiveQuote,
    providersCount: swapProvidersCount,
    isLoading: isSwapQuoteLoading,
    quoteError: swapQuoteError,
    statusLabel: swapQuotesStatusLabel,
    getQuoteDiffPct: getSwapQuoteDiffPct,
    reset: resetSwapQuoteState,
    requestQuotes: requestSwapQuotes,
    selectProvider: selectSwapQuote,
  } = useSwapQuotesParallel({ amountField: 'amountOut', compare: 'max' })

  // --- Position/vault computeds ---
  const position = computed(() => getPositionBySubAccountIndex(+positionIndex))
  const isPositionLoaded = computed(() => !!position.value)
  const collateralVault = computed(() => selectedCollateral.value || position.value?.collateral)
  const borrowVault = computed(() => position.value?.borrow)
  const collateralAssets = computed(() => selectedCollateralAssets.value)
  const asset = computed(() => collateralVault.value?.asset)

  const priceInvert = usePriceInvert(
    () => collateralVault.value?.asset.symbol,
    () => borrowVault.value?.asset.symbol,
  )

  // --- APY block ---
  const collateralSupplyRewardApy = computed(() => getSupplyRewardApy(collateralVault.value?.address || ''))
  const borrowRewardApy = computed(() => getBorrowRewardApy(borrowVault.value?.address || '', collateralVault.value?.address || ''))
  const collateralSupplyApy = computed(() => {
    if (!collateralVault.value) return 0
    return withIntrinsicSupplyApy(
      nanoToValue(collateralVault.value.interestRateInfo.supplyAPY || 0n, 25),
      collateralVault.value?.asset.address,
    )
  })
  const borrowApy = computed(() => withIntrinsicBorrowApy(
    nanoToValue(borrowVault.value?.interestRateInfo.borrowAPY || 0n, 25),
    borrowVault.value?.asset.address,
  ))

  const getCollateralValueUsdLocal = async (amt: bigint) => {
    if (!borrowVault.value || !collateralVault.value) return 0
    return getCollateralUsdValueOrZero(amt, borrowVault.value, collateralVault.value as Vault, 'off-chain')
  }

  const netAPY = ref(0)

  watchEffect(async () => {
    if (!position.value || !borrowVault.value || !collateralVault.value) {
      netAPY.value = 0
      return
    }

    const [collateralUsd, borrowedUsd] = await Promise.all([
      getCollateralValueUsdLocal(collateralAssets.value),
      getAssetUsdValueOrZero(position.value.borrowed ?? 0n, borrowVault.value, 'off-chain'),
    ])

    netAPY.value = getNetAPY(
      collateralUsd,
      collateralSupplyApy.value,
      borrowedUsd,
      borrowApy.value,
      collateralSupplyRewardApy.value || null,
      borrowRewardApy.value || null,
    )
  })

  // --- FixedPoint computeds ---
  const amountFixed = computed(() => FixedPoint.fromValue(
    valueToNano(amount.value || '0', collateralVault.value?.decimals),
    Number(collateralVault.value?.decimals),
  ))
  const borrowedFixed = computed(() => FixedPoint.fromValue(position.value?.borrowed || 0n, position.value?.borrow.decimals || 18))
  const suppliedFixed = computed(() => FixedPoint.fromValue(collateralAssets.value, collateralVault.value?.decimals || 18))
  const priceFixed = computed(() => {
    if (!position.value) return FixedPoint.fromValue(0n, 18)
    return options.computePriceFixed(position.value, borrowVault.value, collateralVault.value)
  })
  const liquidationPrice = computed(() => {
    if (!position.value) return undefined
    return options.computeLiquidationPrice(position.value)
  })

  // --- Collateral loading ---
  const getSelectedCollateralAddress = () =>
    (typeof route.query.collateral === 'string' ? route.query.collateral : '')

  const loadSelectedCollateral = async () => {
    if (!position.value) {
      selectedCollateral.value = null
      selectedCollateralAssets.value = 0n
      return
    }

    const primaryAddress = normalizeAddressOrEmpty(position.value.collateral.address)
    const targetAddress = normalizeAddressOrEmpty(getSelectedCollateralAddress()) || primaryAddress

    if (targetAddress !== lastCollateralAddress.value) {
      amount.value = ''
      lastCollateralAddress.value = targetAddress
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
      }) as Record<string, unknown>
      selectedCollateralAssets.value = res.assets as bigint
    }
    catch (e) {
      logWarn(`collateral/${options.mode}`, e)
      if (!selectedCollateral.value) {
        selectedCollateral.value = position.value.collateral
      }
    }
  }

  // --- Swap helpers ---
  const swapEstimatedOutput = computed(() => {
    const outputAsset = options.getSwapOutputAsset()
    if (!swapEffectiveQuote.value || !outputAsset) return ''
    const amountOut = BigInt(swapEffectiveQuote.value.amountOut || 0)
    if (amountOut <= 0n) return ''
    return formatUnits(amountOut, Number(outputAsset.decimals))
  })

  const swapRouteItems = computed(() => {
    const outputAsset = options.getSwapOutputAsset()
    if (!outputAsset) return []
    return buildSwapRouteItems({
      quoteCards: swapQuoteCardsSorted.value,
      getQuoteDiffPct: getSwapQuoteDiffPct,
      decimals: Number(outputAsset.decimals),
      symbol: outputAsset.symbol,
      formatAmount: formatSmartAmount,
    })
  })

  const requestSwapQuote = useDebounceFn(async () => {
    swapQuoteError.value = null

    if (!options.needsSwap.value || !amount.value || !asset.value) {
      resetSwapQuoteState()
      return
    }

    const inputAmountNano = valueToNano(amount.value || '0', asset.value.decimals)
    if (inputAmountNano <= 0n) {
      resetSwapQuoteState()
      return
    }

    const userAddr = (address.value || zeroAddress) as Address
    const subAccountAddr = position.value?.subAccount
      ? (position.value.subAccount as Address)
      : userAddr

    const params = options.requestSwapQuoteParams({
      userAddr,
      subAccountAddr,
      amountNano: inputAmountNano,
      slippage: swapSlippage.value,
      asset: asset.value,
      vaultAddress: collateralVault.value?.address || '',
    })

    if (!params) {
      resetSwapQuoteState()
      return
    }

    await requestSwapQuotes(params, {
      logContext: {
        amount: amount.value,
        slippage: swapSlippage.value,
      },
    })
  }, 500)

  const openSwapTokenSelector = (currentAddress?: string, onSelect?: (a: VaultAsset) => void) => {
    modal.open(SwapTokenSelector, {
      props: {
        currentAssetAddress: currentAddress || asset.value?.address,
        onSelect: onSelect || (() => {}),
      },
    })
  }

  const openSlippageSettings = () => {
    modal.open(SlippageSettingsModal)
  }

  const onRefreshSwapQuotes = () => {
    resetSwapQuoteState()
    requestSwapQuote()
  }

  // --- Validation computeds ---
  const isGeoBlocked = computed(() => {
    const addresses: string[] = []
    if (borrowVault.value) addresses.push(borrowVault.value.address)
    if (collateralVault.value) addresses.push(collateralVault.value.address)
    return isAnyVaultBlockedByCountry(...addresses)
  })

  const isSwapRestricted = computed(() =>
    options.needsSwap.value && isVaultRestrictedByCountry(collateralVault.value?.address || ''),
  )

  const isSubmitDisabled = computed(() => {
    if (!isConnected.value) return false
    if (options.effectiveBalance.value < valueToNano(amount.value, asset.value?.decimals)) return true
    if (isLoading.value || !(+amount.value) || !!estimatesError.value || isEstimatesLoading.value) return true
    if (options.needsSwap.value && !swapEffectiveQuote.value && !isSwapQuoteLoading.value) return true
    return false
  })

  const submitDisabled = getSubmitDisabled(computed(() =>
    isGeoBlocked.value || isSwapRestricted.value || isLoading.value || isSubmitDisabled.value,
  ))

  // --- Estimates ---
  const updateEstimates = useDebounceFn(async () => {
    clearSimulationError()
    estimatesError.value = ''
    if (!collateralVault.value) return

    try {
      const amountNano = valueToNano(amount.value, collateralVault.value.decimals)

      // Normalize all FixedPoints to 18 decimals for consistent LTV/health math.
      // borrowedFixed may have different decimals (e.g. 6 for USDC) than collateral (e.g. 18 for WETH),
      // and FixedPoint.div inherits this.decimals — so without normalizing, the result would have
      // wrong decimal scale vs what nanoToValue(..., 18) expects in the template.
      const supplied18 = suppliedFixed.value.round(18)
      const amount18 = amountFixed.value.round(18)
      const borrowed18 = borrowedFixed.value.round(18)

      const collateralValue = options.mode === 'supply'
        ? supplied18.add(amount18).mul(priceFixed.value)
        : supplied18.sub(amount18).mul(priceFixed.value)

      const userLtvFixed = collateralValue.isZero()
        ? FixedPoint.fromValue(0n, 18)
        : borrowed18
            .div(collateralValue)
            .mul(FixedPoint.fromValue(100n, 0))

      options.validateEstimate({
        amountFixed: amountFixed.value,
        suppliedFixed: suppliedFixed.value,
        borrowedFixed: borrowedFixed.value,
        priceFixed: priceFixed.value,
        collateralValue,
        userLtvFixed,
        needsSwap: options.needsSwap.value,
      })

      const adjustedCollateral = options.mode === 'supply'
        ? collateralAssets.value + amountNano
        : collateralAssets.value - amountNano

      const [collateralUsd, borrowedUsd] = await Promise.all([
        getCollateralValueUsdLocal(adjustedCollateral),
        getAssetUsdValueOrZero(position.value!.borrowed || 0n, borrowVault.value!, 'off-chain'),
      ])

      estimateNetAPY.value = getNetAPY(
        collateralUsd,
        collateralSupplyApy.value,
        borrowedUsd,
        borrowApy.value,
        collateralSupplyRewardApy.value || null,
        borrowRewardApy.value || null,
      )

      estimateUserLTV.value = userLtvFixed.value
      // liquidationLTV is in basis points (e.g. 8600 = 86%). Convert to 18-decimal
      // percentage (8600 * 10^16 = 86 * 10^18) to match userLtvFixed's 18 decimals.
      estimateHealth.value = (userLtvFixed.isZero() || userLtvFixed.isNegative())
        ? 0n
        : FixedPoint.fromValue(position.value!.liquidationLTV * (10n ** 16n), 18).div(userLtvFixed).value
    }
    catch (e: unknown) {
      logWarn('collateral/estimates', e)
      estimateNetAPY.value = netAPY.value
      estimateUserLTV.value = position.value!.userLTV
      estimateHealth.value = position.value!.health
      estimatesError.value = (e as { message: string }).message
    }
    finally {
      isEstimatesLoading.value = false
    }
  }, 500)

  // --- Load ---
  const load = async () => {
    if (!isConnected.value) return
    isLoading.value = true
    await until(isPositionLoaded).toBe(true)
    try {
      await loadSelectedCollateral()
      await options.onAfterLoad?.()
      estimateNetAPY.value = netAPY.value
      estimateUserLTV.value = position.value!.userLTV
      estimateHealth.value = position.value!.health
    }
    catch (e) {
      showError('Unable to load Vault')
      logWarn('collateral/load', e)
    }
    finally {
      isLoading.value = false
    }
  }

  // --- Submit ---
  const submit = async () => {
    if (isPreparing.value || isGeoBlocked.value || isSwapRestricted.value) return
    isPreparing.value = true
    try {
      await guardWithTerms(async () => {
        if (!collateralVault.value?.address || !asset.value?.address) return

        try {
          if (options.needsSwap.value && swapEffectiveQuote.value) {
            plan.value = await options.buildSwapPlan(swapEffectiveQuote.value, {
              vaultAddress: collateralVault.value.address,
              amountNano: valueToNano(amount.value || '0', asset.value.decimals),
              subAccount: position.value?.subAccount,
              includePermit2Call: false,
            })
          }
          else {
            plan.value = await options.buildDirectPlan({
              vaultAddress: collateralVault.value.address,
              assetAddress: asset.value.address,
              amountNano: valueToNano(amount.value || '0', asset.value.decimals),
              subAccount: position.value?.subAccount,
              includePermit2Call: false,
            })
          }
        }
        catch (e) {
          logWarn(`collateral/${options.mode}/buildPlan`, e)
          plan.value = null
        }

        if (plan.value) {
          const ok = await runSimulation(plan.value)
          if (!ok) return
        }

        const reviewAsset = options.getReviewAsset(options.needsSwap.value)
        const reviewType = options.needsSwap.value ? options.swapReviewType : options.reviewType
        modal.open(OperationReviewModal, {
          props: {
            type: reviewType,
            asset: reviewAsset,
            amount: amount.value,
            plan: plan.value || undefined,
            subAccount: position.value?.subAccount,
            hasBorrows: (position.value?.borrowed || 0n) > 0n,
            swapToAsset: options.needsSwap.value ? options.getSwapToAsset() : undefined,
            swapToAmount: options.needsSwap.value ? swapEstimatedOutput.value : undefined,
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

  // --- Send ---
  const send = async () => {
    try {
      isSubmitting.value = true
      if (!asset.value?.address || !collateralVault.value?.address) return

      let txPlan: TxPlan
      if (options.needsSwap.value && (swapSelectedQuote.value || swapEffectiveQuote.value)) {
        const quote = swapSelectedQuote.value || swapEffectiveQuote.value!
        txPlan = await options.buildSwapPlan(quote, {
          vaultAddress: collateralVault.value.address,
          amountNano: valueToNano(amount.value || '0', asset.value.decimals),
          subAccount: position.value?.subAccount,
        })
      }
      else {
        txPlan = await options.buildDirectPlan({
          vaultAddress: collateralVault.value.address,
          assetAddress: asset.value.address,
          amountNano: valueToNano(amount.value || '0', asset.value.decimals),
          subAccount: position.value?.subAccount,
          includePermit2Call: true,
        })
      }
      await executeTxPlan(txPlan)

      modal.close()
      await options.onAfterSend?.()
      setTimeout(() => {
        router.replace('/portfolio')
      }, 400)
    }
    catch (e) {
      logWarn('collateral/send', e)
      error('Transaction failed')
    }
    finally {
      isSubmitting.value = false
    }
  }

  // --- Common watchers ---
  watch(isPositionsLoaded, (val) => {
    if (val) load()
  }, { immediate: true })

  watch(() => route.query.collateral, async () => {
    clearSimulationError()
    if (!isPositionLoaded.value) return
    await loadSelectedCollateral()
    await options.onAfterLoad?.()
    estimateNetAPY.value = netAPY.value
    estimateUserLTV.value = position.value?.userLTV || 0n
    estimateHealth.value = position.value?.health || 0n
  })

  watch(amount, async () => {
    if (!collateralVault.value) return
    if (!isEstimatesLoading.value) {
      isEstimatesLoading.value = true
    }
    updateEstimates()
    if (options.needsSwap.value) {
      resetSwapQuoteState()
      requestSwapQuote()
    }
  })

  watch(swapSlippage, () => {
    if (options.needsSwap.value && amount.value) {
      clearSimulationError()
      resetSwapQuoteState()
      requestSwapQuote()
    }
  })

  watch(swapSelectedQuote, () => {
    clearSimulationError()
  })

  return {
    // State
    isLoading,
    isSubmitting,
    isPreparing,
    isEstimatesLoading,
    amount,
    plan,
    estimateNetAPY,
    estimateUserLTV,
    estimateHealth,
    estimatesError,
    selectedCollateral,
    selectedCollateralAssets,

    // Position/vault
    position,
    isPositionLoaded,
    collateralVault,
    borrowVault,
    collateralAssets,
    asset,
    priceInvert,

    // APY
    netAPY,
    collateralSupplyApy,
    borrowApy,
    collateralSupplyRewardApy,
    borrowRewardApy,

    // FixedPoint
    amountFixed,
    borrowedFixed,
    suppliedFixed,
    priceFixed,
    liquidationPrice,

    // Swap
    enableSwapDeposit,
    swapSlippage,
    swapQuoteCardsSorted,
    swapSelectedProvider,
    swapSelectedQuote,
    swapEffectiveQuote,
    swapProvidersCount,
    isSwapQuoteLoading,
    swapQuoteError,
    swapQuotesStatusLabel,
    swapEstimatedOutput,
    swapRouteItems,
    selectSwapQuote,
    resetSwapQuoteState,
    requestSwapQuote,
    openSwapTokenSelector,
    openSlippageSettings,
    onRefreshSwapQuotes,

    // Validation
    isGeoBlocked,
    isSwapRestricted,
    isSubmitDisabled,
    submitDisabled,
    submitLabel,
    simulationError,
    clearSimulationError,

    // Actions
    loadSelectedCollateral,
    submit,
    send,
    updateEstimates,
  }
}
