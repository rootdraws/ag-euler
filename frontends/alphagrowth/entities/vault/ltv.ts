import type { VaultCollateralLTV } from './types'

/** Shared LTV ramp config fields used by both VaultCollateralLTV and BorrowVaultPair */
type LTVRampConfig = Pick<VaultCollateralLTV, 'liquidationLTV' | 'initialLiquidationLTV' | 'targetTimestamp' | 'rampDuration'>

/**
 * Calculate the current liquidation LTV, taking into account ramping.
 * When liquidation LTV is lowered, it ramps down linearly from initialLiquidationLTV
 * to liquidationLTV (target) over rampDuration, reaching target at targetTimestamp.
 */
export const getCurrentLiquidationLTV = (ltv: LTVRampConfig): bigint => {
  const now = BigInt(Math.floor(Date.now() / 1000))

  // If ramping is complete or LTV is ramping UP (not down), return target
  if (now >= ltv.targetTimestamp || ltv.liquidationLTV >= ltv.initialLiquidationLTV) {
    return ltv.liquidationLTV
  }

  // Calculate interpolated value during ramp down
  const timeRemaining = ltv.targetTimestamp - now
  const currentLTV = ltv.liquidationLTV
    + ((ltv.initialLiquidationLTV - ltv.liquidationLTV) * timeRemaining) / ltv.rampDuration

  return currentLTV
}

/**
 * Check if the liquidation LTV is currently ramping down
 */
export const isLiquidationLTVRamping = (ltv: LTVRampConfig): boolean => {
  const now = BigInt(Math.floor(Date.now() / 1000))

  // Ramping down if: not yet at target timestamp AND target is less than initial (ramping DOWN)
  return now < ltv.targetTimestamp && ltv.liquidationLTV < ltv.initialLiquidationLTV
}

/**
 * Get the time remaining until ramping completes (in seconds)
 */
export const getRampTimeRemaining = (ltv: LTVRampConfig): bigint => {
  const now = BigInt(Math.floor(Date.now() / 1000))
  if (now >= ltv.targetTimestamp) {
    return 0n
  }
  return ltv.targetTimestamp - now
}
