import { configureBackend, clearBackendCache } from '~/services/pricing'
import type { BackendConfig } from '~/services/pricing'

/**
 * Composable for accessing price backend configuration.
 *
 * The backend URL is configured via PRICE_API_URL environment variable.
 * When empty, the system uses on-chain prices only.
 *
 * Usage:
 * ```typescript
 * const { backendConfig } = usePriceBackend()
 *
 * // Use with price functions - pass 'off-chain' source and backend config
 * const price = await getAssetUsdPrice(vault, 'off-chain', backendConfig.value)
 * const value = await getAssetUsdValue(amount, vault, 'off-chain', backendConfig.value)
 * ```
 */
export const usePriceBackend = () => {
  const config = useEulerConfig()
  const { chainId } = useEulerAddresses()

  const backendUrl = (config as { PRICE_API_URL?: string }).PRICE_API_URL || ''

  // Initial configuration
  configureBackend(backendUrl || undefined, chainId.value)

  // On chain switch: clear stale cache first, then reconfigure with new chainId
  watch(chainId, () => {
    clearBackendCache()
    configureBackend(backendUrl || undefined, chainId.value)
  })

  const backendConfig = computed<BackendConfig>(() => ({
    url: backendUrl || undefined,
    chainId: chainId.value,
  }))

  const isBackendEnabled = computed(() => !!backendUrl)

  return {
    /**
     * Backend configuration to pass to async price functions.
     * Contains URL and chainId.
     */
    backendConfig,

    /**
     * Whether the backend is enabled (URL is configured).
     */
    isBackendEnabled,

    /**
     * The raw backend URL (for debugging/display).
     */
    backendUrl,
  }
}
