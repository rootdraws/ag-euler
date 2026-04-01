import axios from 'axios'
import { DEFILLAMA_YIELDS_URL } from '~/entities/constants'
import type { IntrinsicApySourceConfig } from '~/entities/custom'
import type { IntrinsicApyProvider, IntrinsicApyResult } from '~/entities/intrinsic-apy'

type DefiLlamaPool = {
  pool?: string
  project?: string
  apy?: number | null
  apyMean30d?: number | null
}

type DefiLlamaSource = Extract<IntrinsicApySourceConfig, { provider: 'defillama' }>

const normalize = (value?: string) => value?.toLowerCase() || ''

const buildSourceUrl = (poolId: string) =>
  `https://defillama.com/yields/pool/${poolId}`

const formatProjectName = (project: string) =>
  project.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')

export const createDefiLlamaProvider = (sources: readonly IntrinsicApySourceConfig[]): IntrinsicApyProvider => {
  const defillamaSources = sources.filter(
    (s): s is DefiLlamaSource => s.provider === 'defillama',
  )

  return {
    name: 'DefiLlama',

    async fetch(): Promise<IntrinsicApyResult[]> {
      const res = await axios.get(DEFILLAMA_YIELDS_URL)
      const rawPools = (res.data?.data || []) as DefiLlamaPool[]

      const poolsById = new Map<string, DefiLlamaPool>()
      for (const pool of rawPools) {
        if (pool.pool) {
          poolsById.set(pool.pool, pool)
        }
      }

      const results: IntrinsicApyResult[] = []

      for (const source of defillamaSources) {
        const pool = poolsById.get(source.poolId)
        if (!pool) continue

        const apy = source.useSpotApy
          ? (pool.apy ?? 0)
          : (pool.apyMean30d ?? 0)

        const providerName = pool.project
          ? `${formatProjectName(pool.project)} via DefiLlama`
          : 'DefiLlama'

        results.push({
          address: normalize(source.address),
          info: {
            apy,
            provider: providerName,
            source: buildSourceUrl(source.poolId),
          },
        })
      }

      return results
    },
  }
}
