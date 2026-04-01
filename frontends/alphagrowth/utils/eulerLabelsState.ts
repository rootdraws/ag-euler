import type { EulerLabelEntity, EulerLabelProduct, EulerLabelPointReward } from '~/entities/euler/labels'
import type { OracleAdapterMeta } from '~/entities/oracle'

export const isLoading = ref(false)

// Use a simple object to track loaded state (survives HMR better than ref)
export const loadState = { chainId: null as number | null, timestamp: 0 }

export const products: Record<string, EulerLabelProduct> = shallowReactive({})
export const entities: Record<string, EulerLabelEntity> = shallowReactive({})
export const points: Record<string, EulerLabelPointReward[]> = shallowReactive({})
export const earnVaults: Ref<string[]> = ref([]) // string of earn vault addresses
export const earnVaultBlocks: Record<string, string[]> = shallowReactive({}) // address (lowercase) -> blocked country codes
export const earnVaultRestrictions: Record<string, string[]> = shallowReactive({}) // address (lowercase) -> restricted country codes
export const featuredEarnVaults: Set<string> = shallowReactive(new Set())
// Derived from products - all unique vault addresses across all products
export const verifiedVaultAddresses: Ref<string[]> = ref([])
export const oracleAdapters: Record<string, OracleAdapterMeta> = shallowReactive({})

export const loadingAdapters = new Set<string>()
