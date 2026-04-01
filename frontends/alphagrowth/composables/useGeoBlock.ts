import { detectCountry } from '~/services/country'
import { getVaultBlock, getEarnVaultBlock, getVaultRestricted, getEarnVaultRestricted, isVaultDeprecated } from '~/utils/eulerLabelsUtils'
import { SANCTIONED_COUNTRIES, COUNTRY_GROUPS } from '~/entities/constants'

const country = ref<string | null>(null)

export const useGeoBlock = () => {
  const loadCountry = async () => {
    if (!import.meta.client) return
    const detected = await detectCountry()
    if (detected) {
      country.value = detected
    }
  }

  return { country, loadCountry }
}

const isCountryInList = (codes: readonly string[]): boolean => {
  return codes.some(code => code.toUpperCase() === country.value!.toUpperCase())
}

const expandBlockList = (codes: readonly string[]): string[] => {
  return codes.flatMap(code => COUNTRY_GROUPS[code] ?? [code])
}

export const isVaultBlockedByCountry = (vaultAddress: string): boolean => {
  if (!country.value) return false

  // Sanctioned countries are always blocked
  if (isCountryInList(SANCTIONED_COUNTRIES)) return true

  const productBlock = getVaultBlock(vaultAddress)
  if (productBlock?.length && isCountryInList(expandBlockList(productBlock))) return true

  const earnBlock = getEarnVaultBlock(vaultAddress)
  if (earnBlock?.length && isCountryInList(expandBlockList(earnBlock))) return true

  return false
}

export const isAnyVaultBlockedByCountry = (...addresses: string[]): boolean => {
  return addresses.some(addr => isVaultBlockedByCountry(addr))
}

export const isVaultRestrictedByCountry = (vaultAddress: string): boolean => {
  if (!country.value) return false

  const vaultRestricted = getVaultRestricted(vaultAddress)
  if (vaultRestricted?.length && isCountryInList(expandBlockList(vaultRestricted))) return true

  const earnRestricted = getEarnVaultRestricted(vaultAddress)
  if (earnRestricted?.length && isCountryInList(expandBlockList(earnRestricted))) return true

  return false
}

export const isAnyVaultRestrictedByCountry = (...addresses: string[]): boolean => {
  return addresses.some(addr => isVaultRestrictedByCountry(addr))
}

export type VaultTagContext = 'browse' | 'swap-target' | 'supply-source'

export const getVaultTags = (
  vaultAddress: string,
  context: VaultTagContext = 'browse',
): { tags: string[], disabled: boolean } => {
  const tags: string[] = []
  const blocked = isVaultBlockedByCountry(vaultAddress)
  const restricted = !blocked && isVaultRestrictedByCountry(vaultAddress)

  if (blocked) tags.push('Restricted')
  // Soft-restricted: only show tag when the context involves acquiring more exposure
  if (restricted && context === 'swap-target') tags.push('Restricted')
  if (isVaultDeprecated(vaultAddress)) tags.push('Deprecated')

  const disabled = blocked
    || isVaultDeprecated(vaultAddress)
    || (restricted && context === 'swap-target')

  return { tags, disabled }
}
