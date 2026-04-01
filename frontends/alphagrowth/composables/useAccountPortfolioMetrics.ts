import { ref, watchEffect } from 'vue'
import { useVaultRegistry } from './useVaultRegistry'
import { useAccountPositions } from './useAccountPositions'
import { useAccountValues } from './useAccountValues'
import type { Vault } from '~/entities/vault'
import {
  getAssetUsdValue,
  getCollateralUsdValueOrZero,
} from '~/services/pricing/priceProvider'
import { nanoToValue } from '~/utils/crypto-utils'

const portfolioRoe = ref(0)
const portfolioNetApy = ref(0)

export const useAccountPortfolioMetrics = () => {
  const { borrowPositions } = useAccountPositions()
  const { totalSuppliedValueInfo, totalBorrowedValueInfo } = useAccountValues()

  // Must be called in setup context — useIntrinsicApy uses onMounted
  const { withIntrinsicBorrowApy, withIntrinsicSupplyApy, version: intrinsicVersion } = useIntrinsicApy()
  const { getSupplyRewardApy, getBorrowRewardApy, version: rewardsVersion } = useRewardsApy()

  const computePortfolioRoe = async () => {
    const { getVault: registryGetVault } = useVaultRegistry()

    let totalNetYield = 0
    let totalEquity = 0
    let totalSupplyUSD = 0

    for (const position of borrowPositions.value) {
      const registryVault = registryGetVault(position.borrow.address) as Vault | undefined
      const borrowVault = registryVault || position.borrow

      const supplyUSD = await getCollateralUsdValueOrZero(position.supplied, borrowVault, position.collateral, 'off-chain')
      const borrowUSD = (await getAssetUsdValue(position.borrowed, borrowVault, 'off-chain')) ?? 0

      const supplyApy = withIntrinsicSupplyApy(
        nanoToValue(position.collateral.interestRateInfo?.supplyAPY || 0n, 25),
        position.collateral.asset.address,
      )
      const borrowApy = withIntrinsicBorrowApy(
        nanoToValue(position.borrow.interestRateInfo.borrowAPY, 25),
        position.borrow.asset.address,
      )

      const supplyRewardAPY = getSupplyRewardApy(position.collateral.address)
      const borrowRewardAPY = getBorrowRewardApy(position.borrow.address, position.collateral.address)

      const netYield
        = supplyUSD * (supplyApy + supplyRewardAPY)
          - borrowUSD * (borrowApy - borrowRewardAPY)
      const equity = supplyUSD - borrowUSD

      totalNetYield += netYield
      totalEquity += equity
      totalSupplyUSD += supplyUSD
    }

    portfolioRoe.value = totalEquity > 0 ? totalNetYield / totalEquity : 0
    portfolioNetApy.value = totalSupplyUSD > 0 ? totalNetYield / totalSupplyUSD : 0
  }

  watchEffect(() => {
    const _supplyTotal = totalSuppliedValueInfo.value.total
    const _borrowTotal = totalBorrowedValueInfo.value.total
    void rewardsVersion.value
    void intrinsicVersion.value
    if (borrowPositions.value.length) {
      computePortfolioRoe()
    }
    else {
      portfolioRoe.value = 0
      portfolioNetApy.value = 0
    }
  })

  return { portfolioRoe, portfolioNetApy }
}
