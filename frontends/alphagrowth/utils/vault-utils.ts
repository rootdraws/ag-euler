import { getAddress } from 'viem'

export const isSameVault = (
  vaultA: { address: string } | undefined,
  vaultB: { address: string } | undefined,
): boolean => {
  if (!vaultA || !vaultB) return false
  try {
    return getAddress(vaultA.address) === getAddress(vaultB.address)
  }
  catch {
    return false
  }
}

export const isSameUnderlyingAsset = (
  vaultA: { asset: { address: string } } | undefined,
  vaultB: { asset: { address: string } } | undefined,
): boolean => {
  if (!vaultA || !vaultB) return false
  try {
    return getAddress(vaultA.asset.address) === getAddress(vaultB.asset.address)
  }
  catch {
    return false
  }
}
