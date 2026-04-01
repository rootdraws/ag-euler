import type { MarketGroup } from '~/entities/lend-discovery'
import type { Vault } from '~/entities/vault'
import { nanoToValue } from '~/utils/crypto-utils'
import type { AnyVault } from '~/composables/useVaultRegistry'

const isVaultType = (vault: AnyVault): vault is Vault =>
  !('type' in vault) || (vault as { type?: string }).type === undefined

/**
 * Computes the best net APY for each market group by iterating all actual
 * collateral/liability pairs with LTV relationships. Accounts for intrinsic
 * APY and reward campaigns based on user settings.
 *
 * Returns a reactive map of marketGroupId → bestNetAPY (as a percentage, e.g. 5.2 for 5.2%).
 */
export const useBestNetAPY = (marketGroups: Ref<MarketGroup[]>) => {
  const { withIntrinsicSupplyApy, withIntrinsicBorrowApy, version: intrinsicVersion } = useIntrinsicApy()
  const { getSupplyRewardApy, getBorrowRewardApy, version: rewardsVersion } = useRewardsApy()

  const computeForGroup = (group: MarketGroup): number => {
    const borrowableVaults = group.vaults.filter(
      v => isVaultType(v) && v.vaultCategory !== 'escrow',
    ) as Vault[]

    const allVaults = [...group.vaults, ...group.externalCollateral]
    const knownAddresses = new Set(
      allVaults.map(v => (isVaultType(v) ? v.address : '').toLowerCase()).filter(Boolean),
    )

    let best = -Infinity

    for (const liability of borrowableVaults) {
      const borrowBase = nanoToValue(liability.interestRateInfo.borrowAPY, 25)
      const borrowApy = withIntrinsicBorrowApy(borrowBase, liability.asset.address)

      for (const ltv of liability.collateralLTVs) {
        if (ltv.borrowLTV <= 0n) continue
        const colAddr = ltv.collateral.toLowerCase()
        if (!knownAddresses.has(colAddr)) continue

        const collateral = allVaults.find(
          v => isVaultType(v) && v.address.toLowerCase() === colAddr,
        )
        if (!collateral || !isVaultType(collateral)) continue

        const supplyBase = nanoToValue(collateral.interestRateInfo.supplyAPY, 25)
        const supplyApy = withIntrinsicSupplyApy(supplyBase, collateral.asset.address)
        const supplyRewards = getSupplyRewardApy(collateral.address)
        const borrowRewards = getBorrowRewardApy(liability.address, collateral.address)

        const supplyFinal = supplyApy + supplyRewards
        const borrowFinal = borrowApy - borrowRewards
        const netApy = supplyFinal - borrowFinal

        if (netApy > best) best = netApy
      }
    }

    return Number.isFinite(best) && best > -Infinity ? best : 0
  }

  const bestNetAPYMap = computed((): Map<string, number> => {
    // Read reactive dependencies so this recomputes when they change
    void intrinsicVersion.value
    void rewardsVersion.value

    const result = new Map<string, number>()
    for (const group of marketGroups.value) {
      result.set(group.id, computeForGroup(group))
    }
    return result
  })

  const getBestNetAPY = (groupId: string): number => {
    return bestNetAPYMap.value.get(groupId) ?? 0
  }

  return {
    bestNetAPYMap,
    getBestNetAPY,
  }
}
