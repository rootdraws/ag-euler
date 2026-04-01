import { maxUint256 } from 'viem'
import { getVaultUtilization, type Vault } from '~/entities/vault'

export type WarningLevel = 'info' | 'high' | 'critical'
export type WarningContext = 'lend' | 'borrow' | 'general'

export interface VaultWarning {
  level: WarningLevel
  title: string
  message: string
}

const UTILISATION_HIGH = 95
const UTILISATION_CRITICAL = 99

const CAP_HIGH = 95
const CAP_CRITICAL = 99

const utilisationMessages: Record<WarningContext, Record<'high' | 'critical', { title: string, message: string }>> = {
  lend: {
    high: {
      title: 'High utilisation',
      message: 'Utilisation is high on this market. Available liquidity is limited, which may affect your ability to withdraw.',
    },
    critical: {
      title: 'Critical utilisation',
      message: 'Utilisation is critically high. Nearly all liquidity has been borrowed. Withdrawals may fail until borrowers repay.',
    },
  },
  borrow: {
    high: {
      title: 'High utilisation',
      message: 'Utilisation is high on this market. Interest rates are elevated and may be volatile.',
    },
    critical: {
      title: 'Critical utilisation',
      message: 'Utilisation is critically high. Interest rates are very elevated. Available liquidity is near zero.',
    },
  },
  general: {
    high: {
      title: 'High utilisation',
      message: 'High utilisation on this market. A large proportion of the available liquidity has been borrowed.',
    },
    critical: {
      title: 'Critical utilisation',
      message: 'Utilisation is critically high. Nearly all available liquidity has been borrowed.',
    },
  },
}

const getUtilisationLevel = (utilisation: number): 'high' | 'critical' | null => {
  if (utilisation >= UTILISATION_CRITICAL) return 'critical'
  if (utilisation >= UTILISATION_HIGH) return 'high'
  return null
}

const getCapLevel = (percentage: number): WarningLevel | null => {
  if (percentage >= CAP_CRITICAL) return 'critical'
  if (percentage >= CAP_HIGH) return 'high'
  return null
}

const bigintPercentage = (numerator: bigint, denominator: bigint): number => {
  const scale = 10n ** 2n
  const fraction = (numerator * scale * 100n) / denominator
  const whole = fraction / scale
  const remainder = fraction % scale
  return parseFloat(`${whole}.${remainder.toString().padStart(2, '0')}`)
}

export const getSupplyCapPercentage = (vault: Vault): number => {
  if (vault.supplyCap >= maxUint256) return 0
  if (vault.supplyCap === 0n) return vault.supply > 0n ? 100 : 0
  return bigintPercentage(vault.supply, vault.supplyCap)
}

export const getBorrowCapPercentage = (vault: Vault): number => {
  if (vault.borrowCap >= maxUint256) return 0
  if (vault.borrowCap === 0n) return vault.borrow > 0n ? 100 : 0
  return bigintPercentage(vault.borrow, vault.borrowCap)
}

export const getUtilisationWarning = (
  vault: Vault,
  context: WarningContext = 'general',
): VaultWarning | null => {
  const utilisation = getVaultUtilization(vault)
  const level = getUtilisationLevel(utilisation)
  if (!level) return null

  const { title, message } = utilisationMessages[context][level]
  return { level, title, message }
}

export const getSupplyCapWarning = (vault: Vault): VaultWarning | null => {
  const percentage = getSupplyCapPercentage(vault)
  const level = getCapLevel(percentage)
  if (!level) return null

  const title = percentage >= 100
    ? 'Supply cap reached'
    : percentage >= CAP_CRITICAL
      ? 'Supply cap nearly reached'
      : 'Supply cap approaching limit'
  const message = percentage >= 100
    ? 'The supply cap has been reached. New deposits will fail.'
    : percentage >= CAP_CRITICAL
      ? 'The supply cap is nearly reached. New deposits may be limited or fail.'
      : 'The supply cap is approaching its limit. Available capacity for new deposits is limited.'

  return { level: 'info', title, message }
}

export const getBorrowCapWarning = (vault: Vault): VaultWarning | null => {
  const percentage = getBorrowCapPercentage(vault)
  const level = getCapLevel(percentage)
  if (!level) return null

  const title = percentage >= 100
    ? 'Borrow cap reached'
    : percentage >= CAP_CRITICAL
      ? 'Borrow cap nearly reached'
      : 'Borrow cap approaching limit'
  const message = percentage >= 100
    ? 'The borrow cap has been reached. New borrows will fail.'
    : percentage >= CAP_CRITICAL
      ? 'The borrow cap is nearly reached. New borrows may be limited or fail.'
      : 'The borrow cap is approaching its limit. Available capacity for new borrows is limited.'

  return { level: 'info', title, message }
}
