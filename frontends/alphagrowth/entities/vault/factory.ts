import axios from 'axios'
import { useVaultRegistry } from '~/composables/useVaultRegistry'

// Cache for vault factory lookups
const vaultFactoryCache = new Map<string, string>()

// Fetch vault factory from subgraph
export const fetchVaultFactory = async (
  vaultAddress: string,
  subgraphUrl?: string,
): Promise<string | null> => {
  const normalizedAddress = vaultAddress.toLowerCase()

  // Check cache first
  if (vaultFactoryCache.has(normalizedAddress)) {
    return vaultFactoryCache.get(normalizedAddress)!
  }

  try {
    const url = subgraphUrl || useEulerConfig().SUBGRAPH_URL
    if (!url) {
      console.warn('[fetchVaultFactory] No subgraph URL available')
      return null
    }

    const { data } = await axios.post(url, {
      query: `query VaultFactory {
        vaults(where: { id: "${normalizedAddress}" }) {
          id
          factory
          }
          }`,
    })

    const vault = data?.data?.vaults?.[0]
    if (vault?.factory) {
      vaultFactoryCache.set(normalizedAddress, vault.factory.toLowerCase())
      return vault.factory.toLowerCase()
    }

    return null
  }
  catch (e) {
    console.warn('[fetchVaultFactory] Failed to fetch vault factory:', e)
    return null
  }
}

// Check if vault is a securitize vault - first checks registry, then falls back to subgraph
export const isSecuritizeVault = async (address: string): Promise<boolean> => {
  try {
    // First check the vault registry (if populated)
    const { getType } = useVaultRegistry()
    const registryType = getType(address)
    if (registryType) {
      return registryType === 'securitize'
    }

    // Fall back to subgraph query
    const { eulerPeripheryAddresses } = useEulerAddresses()
    const securitizeFactory = eulerPeripheryAddresses.value?.securitizeFactory
    if (!securitizeFactory) {
      return false
    }

    const factory = await fetchVaultFactory(address)
    if (!factory) {
      return false
    }
    return factory.toLowerCase() === securitizeFactory.toLowerCase()
  }
  catch {
    return false
  }
}

// Synchronous check using cached factory data
export const isSecuritizeVaultSync = (address: string): boolean => {
  const { eulerPeripheryAddresses } = useEulerAddresses()
  const securitizeFactory = eulerPeripheryAddresses.value?.securitizeFactory
  if (!securitizeFactory) {
    return false
  }

  const normalizedAddress = address.toLowerCase()
  const factory = vaultFactoryCache.get(normalizedAddress)
  if (!factory) {
    return false
  }
  return factory.toLowerCase() === securitizeFactory.toLowerCase()
}

// Batch fetch vault factories from subgraph
export const fetchVaultFactories = async (
  vaultAddresses: string[],
): Promise<Map<string, string>> => {
  const result = new Map<string, string>()

  if (!vaultAddresses.length) {
    return result
  }

  // Filter out already cached addresses
  const uncachedAddresses = vaultAddresses.filter(
    addr => !vaultFactoryCache.has(addr.toLowerCase()),
  )

  // Add cached results to output
  vaultAddresses.forEach((addr) => {
    const cached = vaultFactoryCache.get(addr.toLowerCase())
    if (cached) {
      result.set(addr.toLowerCase(), cached)
    }
  })

  if (!uncachedAddresses.length) {
    return result
  }

  try {
    const { SUBGRAPH_URL } = useEulerConfig()
    if (!SUBGRAPH_URL) {
      return result
    }

    const normalizedAddresses = uncachedAddresses.map(addr => addr.toLowerCase())

    // Use id_in for batch query with exact matches
    // Add first: 1000 to override The Graph's default limit of 100
    const addressList = normalizedAddresses.map(addr => `"${addr}"`).join(', ')
    const { data } = await axios.post(SUBGRAPH_URL, {
      query: `query VaultFactories {
        vaults(first: 1000, where: { id_in: [${addressList}] }) {
          id
          factory
        }
      }`,
    })

    const vaults = data?.data?.vaults || []
    vaults.forEach((vault: { id: string, factory: string }) => {
      if (vault.factory) {
        const factoryLower = vault.factory.toLowerCase()
        vaultFactoryCache.set(vault.id, factoryLower)
        result.set(vault.id, factoryLower)
      }
    })

    return result
  }
  catch (e) {
    console.warn('[fetchVaultFactories] Failed to fetch vault factories:', e)
    return result
  }
}

// Get all securitize vault addresses from a list of addresses
export const filterSecuritizeVaults = async (vaultAddresses: string[]): Promise<string[]> => {
  const { eulerPeripheryAddresses } = useEulerAddresses()
  const securitizeFactory = eulerPeripheryAddresses.value?.securitizeFactory
  if (!securitizeFactory) {
    return []
  }

  const factories = await fetchVaultFactories(vaultAddresses)
  const securitizeAddresses: string[] = []

  factories.forEach((factory, address) => {
    if (factory.toLowerCase() === securitizeFactory.toLowerCase()) {
      securitizeAddresses.push(address)
    }
  })

  return securitizeAddresses
}
