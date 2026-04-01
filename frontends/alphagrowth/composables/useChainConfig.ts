/**
 * Provides chain configuration derived from environment variables.
 *
 * On the server, scans process.env directly (for SSR or API routes).
 * On the client, reads from window.__CHAIN_CONFIG__ which is injected
 * by server/plugins/chain-config.ts via the render:html hook.
 *
 * This avoids runtimeConfig (which is frozen in production) and works
 * with runtime-injected env vars (e.g. Doppler on Railway).
 */

interface ChainConfig {
  enabledChainIds: number[]
  subgraphUris: Record<string, string>
}

let cached: ChainConfig | null = null

function scanEnv(): ChainConfig {
  const enabledChainIds = Object.keys(process.env)
    .filter(k => /^RPC_URL_HTTP_\d+$/.test(k) && process.env[k])
    .map(k => Number(k.replace('RPC_URL_HTTP_', '')))

  const subgraphUris: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    const match = key.match(/^NUXT_PUBLIC_SUBGRAPH_URI_(\d+)$/)
    if (match && value) {
      subgraphUris[match[1]] = value
    }
  }

  return { enabledChainIds, subgraphUris }
}

export const useChainConfig = (): ChainConfig => {
  if (cached) return cached

  if (import.meta.server) {
    cached = scanEnv()
  }
  else if (typeof window !== 'undefined' && (window as any).__CHAIN_CONFIG__) {
    cached = (window as any).__CHAIN_CONFIG__
  }
  else {
    cached = { enabledChainIds: [], subgraphUris: {} }
  }

  return cached!
}
