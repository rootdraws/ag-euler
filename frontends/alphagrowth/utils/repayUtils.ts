/**
 * Pure utility functions for the repay page.
 * Extracted from pages/position/[number]/repay.vue to eliminate duplication
 * across wallet, collateral-swap, and savings tabs.
 */

export const amountToPercent = (amountNano: bigint, totalDebt: bigint): number => {
  if (totalDebt <= 0n || amountNano <= 0n) return 0
  return Math.min(100, Math.max(0, Math.round(Number(amountNano * 100n / totalDebt))))
}

export const percentToAmountNano = (percent: number, totalDebt: bigint): bigint => {
  const clamped = Math.min(100, Math.max(0, percent || 0))
  return (totalDebt * BigInt(Math.round(clamped * 100))) / 10_000n
}

export const computeNextLtv = (
  borrowAfter: number,
  collateralAfter: number,
  priceRatio: number,
): number | null => {
  if (borrowAfter === 0) return 0
  if (priceRatio <= 0 || collateralAfter <= 0) return null
  return (borrowAfter / (collateralAfter * priceRatio)) * 100
}

export const computeNextHealth = (
  liquidationLtv: number | null,
  nextLtv: number | null,
): number | null => {
  if (liquidationLtv === null || nextLtv === null) return null
  if (nextLtv <= 0) return Infinity
  return liquidationLtv / nextLtv
}

export const computeLiquidationPrice = (
  priceRatio: number | null,
  health: number | null,
): number | null => {
  if (!priceRatio || !health) return null
  if (health <= 0) return null
  return priceRatio / health
}

export const calculateRoe = (
  supplyUsd: number | null,
  borrowUsd: number | null,
  supplyApy: number | null,
  borrowApy: number | null,
): number | null => {
  if (supplyUsd === null || borrowUsd === null || supplyApy === null || borrowApy === null) {
    return null
  }
  const equity = supplyUsd - borrowUsd
  if (!Number.isFinite(equity) || equity <= 0) {
    return null
  }
  const net = supplyUsd * supplyApy - borrowUsd * borrowApy
  if (!Number.isFinite(net)) {
    return null
  }
  return net / equity
}
