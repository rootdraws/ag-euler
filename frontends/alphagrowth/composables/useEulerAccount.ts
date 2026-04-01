import { getAddress } from 'viem'
import { watch, computed } from 'vue'
import { useDebounceFn } from '@vueuse/core'
import { useAccount } from '@wagmi/vue'
import { useAccountPositions } from './useAccountPositions'
import { useAccountValues } from './useAccountValues'
import { useAccountPortfolioMetrics } from './useAccountPortfolioMetrics'
import type { EulerLensAddresses } from '~/composables/useEulerAddresses'
import type { AccountBorrowPosition } from '~/entities/account'
import { normalizeAddressOrEmpty } from '~/utils/accountPositionHelpers'
import { fetchAccountPositions, type SubgraphPositionEntry } from '~/utils/subgraph'

const {
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
} = useAccountPositions()

const {
  totalSuppliedValue,
  totalSuppliedValueInfo,
  totalBorrowedValue,
  totalBorrowedValueInfo,
} = useAccountValues()

export const useEulerAccount = () => {
  const { isLoaded: isBalancesLoaded } = useWallets()
  const { eulerLensAddresses, isReady: isEulerLensAddressesReady, chainId } = useEulerAddresses()
  const { address } = useAccount()
  const { public: { debugPortfolioAddress } } = useRuntimeConfig()
  const normalizedDebugAddress = computed(() => normalizeAddressOrEmpty(debugPortfolioAddress as string | undefined))
  const portfolioAddress = computed(() => normalizedDebugAddress.value || normalizeAddressOrEmpty(address.value))
  const isDebugPortfolio = computed(() => Boolean(normalizedDebugAddress.value))

  const updatePositions = async () => {
    const gen = positionGuard.current()
    const targetAddress = portfolioAddress.value
    const shouldShowAll = isShowAllPositions.value || isDebugPortfolio.value
    const { SUBGRAPH_URL } = useEulerConfig()

    // Fetch both borrow and deposit entries in a single subgraph query
    const { borrows: borrowEntries, deposits: depositEntries } = targetAddress
      ? await fetchAccountPositions(SUBGRAPH_URL, targetAddress)
      : { borrows: [] as SubgraphPositionEntry[], deposits: [] as SubgraphPositionEntry[] }

    // Discard if chain switched during subgraph fetch
    if (positionGuard.isStale(gen)) return

    // Borrow positions must be loaded first so deposits can filter against them
    await updateBorrowPositions(
      eulerLensAddresses.value,
      targetAddress,
      borrowEntries,
      false,
      { forceAllPositions: shouldShowAll },
    )
    await updateSavingsPositions(
      eulerLensAddresses.value,
      targetAddress,
      depositEntries,
      false,
      { forceAllPositions: shouldShowAll },
      gen,
    )
  }

  const debouncedUpdatePositions = useDebounceFn(() => {
    if (isBalancesLoaded.value && isEulerLensAddressesReady.value) {
      updatePositions()
    }
  }, 100)

  watch([isBalancesLoaded, isEulerLensAddressesReady], () => {
    debouncedUpdatePositions()
  }, { immediate: true })

  watch(isShowAllPositions, () => {
    debouncedUpdatePositions()
  })

  // Refresh positions when wallet address changes
  watch(portfolioAddress, (newAddress, oldAddress) => {
    if (newAddress !== oldAddress) {
      debouncedUpdatePositions()
    }
  })

  // Portfolio ROE/APY — must be called in setup context
  const { portfolioRoe, portfolioNetApy } = useAccountPortfolioMetrics()

  // Clear stale positions and invalidate in-flight fetches on chain change
  watch(chainId, () => {
    positionGuard.next()
    borrowPositions.value = []
    depositPositions.value = []
    collateralUsageSet.value = new Set()
    isPositionsLoaded.value = false
    isPositionsLoading.value = true
    isDepositsLoaded.value = false
    isDepositsLoading.value = true
    totalSuppliedValue.value = 0
    totalBorrowedValue.value = 0
  })

  /**
   * Find a borrow position by its subaccount index.
   * The subaccount index is derived from: ownerAddress XOR subAccountAddress
   */
  const getPositionBySubAccountIndex = (subAccountIndex: number): AccountBorrowPosition | undefined => {
    const owner = portfolioAddress.value || address.value
    if (!owner) return undefined

    return borrowPositions.value.find((position) => {
      try {
        const ownerBigInt = BigInt(getAddress(owner))
        const subAccountBigInt = BigInt(getAddress(position.subAccount))
        const index = Number(ownerBigInt ^ subAccountBigInt)
        return index === subAccountIndex
      }
      catch {
        return false
      }
    })
  }

  /**
   * Refresh all positions (borrows + savings) by fetching entries from subgraph.
   * Used by portfolio page for periodic refresh.
   */
  const refreshAllPositions = async (
    lensAddresses: EulerLensAddresses,
    walletAddress: string,
  ) => {
    const gen = positionGuard.current()
    const { SUBGRAPH_URL } = useEulerConfig()
    const { borrows: borrowEntries, deposits: depositEntries } = walletAddress
      ? await fetchAccountPositions(SUBGRAPH_URL, walletAddress)
      : { borrows: [] as SubgraphPositionEntry[], deposits: [] as SubgraphPositionEntry[] }

    if (positionGuard.isStale(gen)) return

    await updateBorrowPositions(lensAddresses, walletAddress, borrowEntries)
    await updateSavingsPositions(lensAddresses, walletAddress, depositEntries, false, {}, gen)
  }

  return {
    borrowPositions,
    depositPositions,
    isPositionsLoading,
    isPositionsLoaded,
    isDepositsLoading,
    isDepositsLoaded,
    isShowAllPositions,
    portfolioAddress,
    isDebugPortfolio,
    refreshAllPositions,
    getPositionBySubAccountIndex,
    totalSuppliedValue,
    totalSuppliedValueInfo,
    totalBorrowedValue,
    totalBorrowedValueInfo,
    portfolioRoe,
    portfolioNetApy,
  }
}
