import {
  DEFILLAMA_YIELDS_URL,
  BREVIS_API_URL,
  BREVIS_MERKLE_PROOF_URL,
  EULER_INTERFACES_CHAINS_URL,
  MERKL_API_BASE_URL,
  MERKL_DISTRIBUTOR_ADDRESS,
} from '~/entities/constants'
import { getParentChainId } from '~/entities/forkChainMap'

const getRpcUrlByChainId = (chainId?: number, origin?: string): string => {
  if (!chainId) {
    return ''
  }
  if (!origin) {
    return `/api/rpc/${chainId}`
  }
  return `${origin}/api/rpc/${chainId}`
}

export const useEulerConfig = () => {
  const envConfig = useEnvConfig()
  const { labelsRepo, labelsRepoBranch } = useDeployConfig()
  const { subgraphUris } = useChainConfig()
  const { chainId } = useEulerAddresses()
  const requestUrl = useRequestURL()

  const labelsBaseUrl = `https://raw.githubusercontent.com/${labelsRepo}/refs/heads/${labelsRepoBranch}`

  return {
    // APIs (from constants)
    DEFILLAMA_YIELDS_URL,
    BREVIS_API_URL,
    BREVIS_MERKLE_PROOF_URL,
    EULER_INTERFACES_CHAINS_URL,
    MERKL_API_BASE_URL,

    // Labels (built from CONFIG_LABELS_REPO)
    getEulerLabelsEntitiesUrl: (id: number) => `${labelsBaseUrl}/${id}/entities.json`,
    getEulerLabelsProductsUrl: (id: number) => `${labelsBaseUrl}/${id}/products.json`,
    getEulerLabelsEarnVaultsUrl: (id: number) => `${labelsBaseUrl}/${id}/earn-vaults.json`,
    getEulerLabelsPointsUrl: (id: number) => `${labelsBaseUrl}/${id}/points.json`,
    EULER_LABELS_ENTITY_LOGO_URL: `${labelsBaseUrl}/logo`,

    // Runtime app config APIs
    EULER_API_URL: envConfig.eulerApiUrl,
    SWAP_API_URL: envConfig.swapApiUrl,
    PRICE_API_URL: envConfig.priceApiUrl,
    PYTH_HERMES_URL: envConfig.pythHermesUrl,

    // Chain-specific (computed)
    EVM_PROVIDER_URL: computed(() => getRpcUrlByChainId(chainId.value, requestUrl.origin)).value,
    SUBGRAPH_URL: computed(() => subgraphUris[String(chainId.value)] || subgraphUris[String(getParentChainId(chainId.value))] || '').value,
    MERKL_ADDRESS: MERKL_DISTRIBUTOR_ADDRESS,
  }
}
