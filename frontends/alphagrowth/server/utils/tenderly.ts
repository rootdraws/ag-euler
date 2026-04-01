import type { Address, Hex } from 'viem'

export interface TenderlyConfig {
  accessKey: string
  accountSlug: string
  projectSlug: string
}

export interface ViemStateOverrideEntry {
  address: Address
  stateDiff?: { slot: Hex, value: Hex }[]
}

export const resolveTenderlyConfig = (): TenderlyConfig | undefined => {
  const accessKey = process.env.TENDERLY_ACCESS_KEY
  const accountSlug = process.env.TENDERLY_ACCOUNT_SLUG
  const projectSlug = process.env.TENDERLY_PROJECT_SLUG

  if (!accessKey || !accountSlug || !projectSlug) {
    return undefined
  }

  return { accessKey, accountSlug, projectSlug }
}

export const viemStateOverridesToTenderly = (
  overrides: ViemStateOverrideEntry[],
): Record<string, { storage: Record<string, string> }> => {
  const result: Record<string, { storage: Record<string, string> }> = {}

  for (const entry of overrides) {
    if (!entry.stateDiff?.length) continue

    const storage: Record<string, string> = {}
    for (const diff of entry.stateDiff) {
      storage[diff.slot] = diff.value
    }

    const key = entry.address.toLowerCase()
    const existing = result[key]
    if (existing) {
      result[key] = { storage: { ...existing.storage, ...storage } }
    }
    else {
      result[key] = { storage }
    }
  }

  return result
}
