import { getProductByVault } from '~/utils/eulerLabelsUtils'
import { getVaultTags, type VaultTagContext } from '~/composables/useGeoBlock'
import type { CollateralOption, Vault } from '~/entities/vault'
import { getAssetUsdValueOrZero } from '~/services/pricing/priceProvider'

export function computeSupplyApy(
  vault: Vault,
  withIntrinsicSupplyApy: (base: number, assetAddress: string) => number,
  getSupplyRewardApy: (vaultAddress: string) => number,
): number {
  const base = nanoToValue(vault.interestRateInfo.supplyAPY || 0n, 25)
  return withIntrinsicSupplyApy(base, vault.asset.address) + getSupplyRewardApy(vault.address)
}

export function computeBorrowApy(
  vault: Vault,
  withIntrinsicBorrowApy: (base: number, assetAddress: string) => number,
  getBorrowRewardApy: (vaultAddress: string, collateralAddress?: string) => number,
  collateralAddress?: string,
): number {
  const base = nanoToValue(vault.interestRateInfo.borrowAPY || 0n, 25)
  return withIntrinsicBorrowApy(base, vault.asset.address) - getBorrowRewardApy(vault.address, collateralAddress)
}

export async function buildCollateralOption(params: {
  vault: Vault
  type: string
  amount: number
  priceAmount: number
  apy: number
  tagContext: VaultTagContext
}): Promise<CollateralOption> {
  const { vault, type, amount, priceAmount, apy, tagContext } = params
  const product = getProductByVault(vault.address)
  const { tags, disabled } = getVaultTags(vault.address, tagContext)

  return {
    type,
    amount,
    price: await getAssetUsdValueOrZero(priceAmount, vault, 'off-chain'),
    apy,
    symbol: vault.asset.symbol,
    assetAddress: vault.asset.address,
    label: product.name || vault.name,
    vaultAddress: vault.address,
    tags,
    disabled,
  }
}
