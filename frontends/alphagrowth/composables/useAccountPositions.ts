import { getAddress, type Address, type Abi } from 'viem'
import { ref, shallowRef, type Ref } from 'vue'
import { useVaultRegistry } from './useVaultRegistry'
import { logWarn } from '~/utils/errorHandling'
import { FixedPoint } from '~/utils/fixed-point'
import { getPublicClient } from '~/utils/public-client'
import type { SubgraphPositionEntry } from '~/utils/subgraph'
import { eulerAccountLensABI } from '~/entities/euler/abis'
import type { EulerLensAddresses } from '~/composables/useEulerAddresses'
import { createRaceGuard } from '~/utils/race-guard'
import { BATCH_SIZE_RPC_CALLS, BPS_BASE } from '~/entities/tuning-constants'
import type {
  AccountBorrowPosition, AccountDepositPosition,
} from '~/entities/account'
import {
  fetchVault,
  type Vault,
  type SecuritizeVault,
} from '~/entities/vault'
import { getCollateralUsdPrice } from '~/services/pricing/priceProvider'
import { collectPythFeedIds } from '~/entities/oracle'
import { executeLensWithPythSimulation } from '~/utils/pyth'
import {
  type LensAccountInfo,
  type LensVaultAccountInfo,
  resolvePositionCollaterals,
  toBigInt,
  hasPythOracles,
} from '~/utils/accountPositionHelpers'

const depositPositions: Ref<AccountDepositPosition[]> = ref([])
const borrowPositions: Ref<AccountBorrowPosition[]> = ref([])

// Track which (subAccount, vaultAddress) pairs are used as collateral
// Format: "subAccount:vaultAddress" (both checksummed)
const collateralUsageSet: Ref<Set<string>> = shallowRef(new Set())

const isPositionsLoading = ref(true)
const isPositionsLoaded = ref(false)
const isDepositsLoading = ref(true)
const isDepositsLoaded = ref(false)
const isShowAllPositions = ref(false)

// Generation counter to invalidate stale in-flight position fetches after chain switch.
// Incremented on chain change; async operations capturing an older generation discard results.
const positionGuard = createRaceGuard()

const updateBorrowPositions = async (
  eulerLensAddresses: EulerLensAddresses,
  address: string,
  borrowEntries: SubgraphPositionEntry[],
  isInitialLoading = false,
  options: { forceAllPositions?: boolean } = {},
) => {
  const gen = positionGuard.current()

  if (isInitialLoading) {
    isPositionsLoaded.value = false
    isPositionsLoading.value = true
    borrowPositions.value = []
  }

  if (!address) {
    borrowPositions.value = []
    isPositionsLoading.value = false
    isPositionsLoaded.value = true
    return
  }

  const { EVM_PROVIDER_URL, PYTH_HERMES_URL } = useEulerConfig()
  const { getOrFetch } = useVaultRegistry()
  const { eulerCoreAddresses } = useEulerAddresses()
  const shouldShowAllPositions = options.forceAllPositions ?? isShowAllPositions.value
  const isAllPositionsAtStart = shouldShowAllPositions

  if (!eulerLensAddresses?.accountLens) {
    throw new Error('Euler addresses not loaded yet')
  }

  const client = getPublicClient(EVM_PROVIDER_URL)

  let borrows: AccountBorrowPosition[] = []
  const batchSize = BATCH_SIZE_RPC_CALLS

  for (let i = 0; i < borrowEntries.length; i += batchSize) {
    if (positionGuard.isStale(gen)) return

    const batch = borrowEntries
      .slice(i, i + batchSize)
      .map(async (entry) => {
        const vaultAddress = entry.vault
        const subAccount = entry.subAccount

        // Pre-fetch borrow vault to check for Pyth oracles
        const borrowVault = await getOrFetch(vaultAddress) as Vault | undefined

        let res: LensAccountInfo | undefined
        try {
          // Check if vault uses Pyth oracles and we can use simulation
          const pythFeeds = borrowVault ? collectPythFeedIds(borrowVault.oracleDetailedInfo) : []
          const canUsePythSimulation = pythFeeds.length > 0
            && PYTH_HERMES_URL
            && eulerCoreAddresses.value?.evc

          if (canUsePythSimulation) {
            // Use batchSimulation with Pyth updates for fresh oracle prices
            const result = await executeLensWithPythSimulation(
              pythFeeds,
              eulerLensAddresses.accountLens as Address,
              eulerAccountLensABI as Abi,
              'getAccountInfo',
              [subAccount, vaultAddress],
              eulerCoreAddresses.value!.evc,
              EVM_PROVIDER_URL,
              PYTH_HERMES_URL!,
            ) as LensAccountInfo | undefined
            if (result) {
              res = result
            }
          }

          // Direct call: either non-Pyth vault, or Pyth simulation failed/returned nothing
          if (!res) {
            res = await client.readContract({
              address: eulerLensAddresses.accountLens as Address,
              abi: eulerAccountLensABI as Abi,
              functionName: 'getAccountInfo',
              args: [subAccount, vaultAddress],
            }) as LensAccountInfo
          }
        }
        catch (err) {
          logWarn('updateBorrowPositions', err)
          return undefined
        }

        if (!res || !res.evcAccountInfo.enabledControllers.length || !res.evcAccountInfo.enabledCollaterals.length || res.vaultAccountInfo.borrowed === 0n) {
          return undefined
        }

        const enabledCollateralsList = res.evcAccountInfo.enabledCollaterals.map(collateral => getAddress(collateral))
        const collaterals = resolvePositionCollaterals(res.vaultAccountInfo?.liquidityInfo, enabledCollateralsList)

        const borrowAddress = getAddress(res.evcAccountInfo.enabledControllers[0])
        // Use pre-fetched vault if it matches, otherwise fetch
        let borrow = borrowVault && borrowVault.address.toLowerCase() === borrowAddress.toLowerCase()
          ? borrowVault
          : await getOrFetch(borrowAddress) as Vault | undefined
        if (!borrow) {
          return undefined
        }

        // If borrow vault uses Pyth oracles, always fetch fresh prices
        // (Pyth prices are only valid for ~2 minutes and require continuous updates)
        if (hasPythOracles(borrow)) {
          const freshBorrow = await fetchVault(borrowAddress)
          if (freshBorrow) {
            borrow = freshBorrow
          }
        }

        let collateralAddress: string | undefined
        const collateralCandidates = collaterals.length ? collaterals : enabledCollateralsList
        for (const addr of collateralCandidates) {
          if (borrow.collateralLTVs.some(ltv => getAddress(ltv.collateral) === addr)) {
            collateralAddress = addr
            break
          }
        }

        if (!collateralAddress) {
          collateralAddress = collateralCandidates[0]
        }

        if (!collateralAddress) {
          return undefined
        }

        // Use unified resolution for collateral vault (handles EVK, escrow, and securitize)
        // Note: Collateral PRICES come from borrow.collateralPrices[], which are already
        // refreshed when we fetch the borrow vault with Pyth simulation above.
        // The collateral vault only provides totalAssets/totalShares for share→asset conversion.
        const collateral = await getOrFetch(collateralAddress) as Vault | SecuritizeVault | undefined

        if (!collateral) {
          return undefined
        }

        // Skip positions where either vault is unverified (unless showing all positions)
        if (!shouldShowAllPositions && (!borrow.verified || !collateral.verified)) {
          return undefined
        }

        // Fetch actual collateral balance — doesn't depend on the oracle
        let suppliedAssets = 0n
        try {
          const collateralRes = await client.readContract({
            address: eulerLensAddresses.accountLens as Address,
            abi: eulerAccountLensABI as Abi,
            functionName: 'getVaultAccountInfo',
            args: [subAccount, collateralAddress],
          }) as LensVaultAccountInfo
          suppliedAssets = toBigInt(collateralRes.assets)
        }
        catch {
          // Collateral amount unavailable
        }

        const liquidityInfo = res.vaultAccountInfo.liquidityInfo
        const hasQueryFailure = Boolean(liquidityInfo.queryFailure)

        if (hasQueryFailure) {
          // LTV config comes from vault governance, not oracle
          const ltvConfig = borrow.collateralLTVs.find(ltv =>
            getAddress(ltv.collateral) === getAddress(collateral.address),
          )

          return {
            borrow,
            collateral,
            collaterals,
            subAccount,
            borrowed: res.vaultAccountInfo.borrowed,
            supplied: suppliedAssets,
            borrowLTV: ltvConfig?.borrowLTV ?? 0n,
            liquidationLTV: ltvConfig?.liquidationLTV ?? 0n,
            // Oracle-dependent fields — genuinely unavailable
            health: 0n,
            userLTV: 0n,
            price: 0n,
            liabilityValueBorrowing: 0n,
            liabilityValueLiquidation: 0n,
            timeToLiquidation: 0n,
            collateralValueLiquidation: 0n,
            liquidityQueryFailure: true,
          } as AccountBorrowPosition
        }

        const collateralValueLiquidation = liquidityInfo.collateralValueLiquidation
        const collateralValueRaw = liquidityInfo.collateralValueRaw
        let liabilityValueBorrowing = liquidityInfo.liabilityValueBorrowing

        // Compute effective LTVs from aggregates (handles multi-collateral correctly)
        const liquidationLTV = collateralValueRaw > 0n
          ? collateralValueLiquidation * BPS_BASE / collateralValueRaw
          : 0n
        const effectiveBorrowLTV = collateralValueRaw > 0n
          ? liquidityInfo.collateralValueBorrowing * BPS_BASE / collateralValueRaw
          : 0n

        if (liabilityValueBorrowing === 0n && res.vaultAccountInfo.borrowed > 0n) {
          logWarn('updateBorrowPositions', 'liabilityValueBorrowing is 0 but borrowed amount exists, calculating manually')
          const borrowedInUnitOfAccount = FixedPoint.fromValue(res.vaultAccountInfo.borrowed, borrow.decimals)
            .mul(FixedPoint.fromValue(borrow.liabilityPriceInfo.amountOutMid, 18))
            .div(FixedPoint.fromValue(borrow.liabilityPriceInfo.amountIn, 0))
          liabilityValueBorrowing = borrowedInUnitOfAccount.value
        }
        const healthFixed = liabilityValueBorrowing === 0n
          ? FixedPoint.fromValue(0n, 18)
          : FixedPoint.fromValue(collateralValueLiquidation, 18).div(FixedPoint.fromValue(liabilityValueBorrowing, 18))

        const userLTVFixed = healthFixed.isZero()
          ? FixedPoint.fromValue(0n, 18)
          : FixedPoint.fromValue(liquidationLTV * (10n ** 16n), 18).div(healthFixed)
        const userLTV = userLTVFixed.value

        // Get collateral price in USD for liquidation price calculation
        const collateralPriceUsd = await getCollateralUsdPrice(borrow, collateral, 'off-chain')

        // Guard against missing price
        if (!collateralPriceUsd) {
          return undefined
        }

        const supplyLiquidationPriceRatio = collateralValueLiquidation === 0n
          ? FixedPoint.fromValue(0n, 18)
          : FixedPoint.fromValue(liabilityValueBorrowing, 18)
              .div(FixedPoint.fromValue(collateralValueLiquidation, 18))

        // Use USD price for display (already converted from UoA)
        const currentCollateralPriceUsd = FixedPoint.fromValue(collateralPriceUsd.amountOutMid, 18)

        const price = currentCollateralPriceUsd.mul(supplyLiquidationPriceRatio).value

        return {
          borrow,
          collateral,
          collaterals,
          subAccount,
          borrowLTV: effectiveBorrowLTV,
          timeToLiquidation: liquidityInfo.timeToLiquidation,
          health: healthFixed.value,
          borrowed: res.vaultAccountInfo.borrowed,
          price,
          userLTV,
          supplied: suppliedAssets,
          liabilityValueBorrowing,
          liabilityValueLiquidation: liquidityInfo.liabilityValueLiquidation,
          liquidationLTV,
          collateralValueLiquidation,
        } as AccountBorrowPosition
      })

    const batchResults = await Promise.all(batch)
    const validResults = batchResults.filter(o => !!o) as AccountBorrowPosition[]
    borrows = [...borrows, ...validResults]
  }
  // Discard results if chain switched during fetch
  if (positionGuard.isStale(gen)) return

  const collateralPositions: AccountBorrowPosition[] = []
  const shouldUpdate = options.forceAllPositions !== undefined
    ? true
    : isShowAllPositions.value === isAllPositionsAtStart
  if (shouldUpdate) {
    const allPositions = [...borrows, ...collateralPositions]
    borrowPositions.value = allPositions

    // Build set of (subAccount, collateralVault) pairs used as collateral
    // Must include ALL enabled collateral vaults, not just the primary one
    const usageSet = new Set<string>()
    for (const pos of allPositions) {
      const subAccount = getAddress(pos.subAccount)
      for (const addr of pos.collaterals ?? [pos.collateral.address]) {
        usageSet.add(`${subAccount}:${getAddress(addr)}`)
      }
    }
    collateralUsageSet.value = usageSet

    isPositionsLoading.value = false
    isPositionsLoaded.value = true
  }
}

const updateSavingsPositions = async (
  eulerLensAddresses: EulerLensAddresses,
  address: string,
  depositEntries: SubgraphPositionEntry[],
  isInitialLoading = false,
  options: { forceAllPositions?: boolean } = {},
  generation?: number,
) => {
  const gen = generation ?? positionGuard.current()

  if (isInitialLoading) {
    isDepositsLoaded.value = false
    isDepositsLoading.value = true
    depositPositions.value = []
  }

  if (!address) {
    isDepositsLoaded.value = false
    isDepositsLoading.value = true
    depositPositions.value = []
    return
  }

  const { getOrFetch } = useVaultRegistry()
  const { EVM_PROVIDER_URL } = useEulerConfig()

  const shouldShowAllPositions = options.forceAllPositions ?? isShowAllPositions.value
  const isAllPositionsAtStart = shouldShowAllPositions

  if (!eulerLensAddresses?.accountLens) {
    throw new Error('Euler addresses not loaded yet')
  }

  const client = getPublicClient(EVM_PROVIDER_URL)

  let deposits: AccountDepositPosition[] = []

  const batchSize = BATCH_SIZE_RPC_CALLS
  for (let i = 0; i < depositEntries.length; i += batchSize) {
    if (positionGuard.isStale(gen)) return

    const batch = depositEntries
      .slice(i, i + batchSize)
      .map(async (entry) => {
        const vaultAddress = entry.vault
        const subAccount = entry.subAccount

        // Check if this deposit is being used as collateral
        const collateralKey = `${subAccount}:${vaultAddress}`
        if (collateralUsageSet.value.has(collateralKey)) {
          return undefined
        }

        // Resolve vault from registry
        const vault = await getOrFetch(vaultAddress)
        if (!vault) return undefined

        // Skip unverified vaults unless showing all positions
        if (!shouldShowAllPositions && !vault.verified) {
          return undefined
        }

        try {
          const res = await client.readContract({
            address: eulerLensAddresses.accountLens as Address,
            abi: eulerAccountLensABI as Abi,
            functionName: 'getAccountInfo',
            args: [subAccount, vaultAddress],
          }) as LensAccountInfo

          // Only include if there are shares
          if (res.vaultAccountInfo.shares === 0n) {
            return undefined
          }

          return {
            vault,
            subAccount,
            shares: res.vaultAccountInfo.shares,
            assets: res.vaultAccountInfo.assets,
          } as AccountDepositPosition
        }
        catch (e) {
          logWarn('updateSavingsPositions', e)
          return undefined
        }
      })
    const results = (await Promise.all(batch)).filter((o): o is AccountDepositPosition => !!o)
    deposits = [...deposits, ...results]
  }

  // Discard results if chain switched during fetch
  if (positionGuard.isStale(gen)) return

  const shouldUpdate = options.forceAllPositions !== undefined
    ? true
    : isShowAllPositions.value === isAllPositionsAtStart
  if (shouldUpdate) {
    depositPositions.value = deposits
    isDepositsLoading.value = false
    isDepositsLoaded.value = true
  }
}

export const useAccountPositions = () => ({
  depositPositions,
  borrowPositions,
  collateralUsageSet,
  isPositionsLoading,
  isPositionsLoaded,
  isDepositsLoading,
  isDepositsLoaded,
  isShowAllPositions,
  positionGuard,
  updateBorrowPositions,
  updateSavingsPositions,
})
