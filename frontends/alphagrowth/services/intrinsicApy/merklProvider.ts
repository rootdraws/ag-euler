import axios from 'axios'
import type { IntrinsicApySourceConfig } from '~/entities/custom'
import type { IntrinsicApyProvider, IntrinsicApyResult } from '~/entities/intrinsic-apy'

type MerklOpportunity = {
  identifier?: string
  apr?: number | null
  status?: string
  name?: string
}

type MerklSource = Extract<IntrinsicApySourceConfig, { provider: 'merkl' }>

const normalize = (value?: string) => value?.toLowerCase() || ''

const MERKL_API_BASE = 'https://api.merkl.xyz/v4'

const buildSourceUrl = (chainId: number, identifier: string) =>
  `https://app.merkl.xyz/opportunities/${chainId}/${identifier}`

export const createMerklProvider = (sources: readonly IntrinsicApySourceConfig[]): IntrinsicApyProvider => {
  const merklSources = sources.filter(
    (s): s is MerklSource => s.provider === 'merkl',
  )

  return {
    name: 'Merkl',

    async fetch(chainId: number): Promise<IntrinsicApyResult[]> {
      const relevantSources = merklSources.filter(s => s.chainId === chainId)
      if (relevantSources.length === 0) return []

      const res = await axios.get(`${MERKL_API_BASE}/opportunities`, {
        params: { chainId, name: 'balancer', items: 100 },
      })

      const opportunities = (Array.isArray(res.data) ? res.data : []) as MerklOpportunity[]

      const byIdentifier = new Map<string, MerklOpportunity>()
      for (const opp of opportunities) {
        if (opp.identifier) {
          byIdentifier.set(normalize(opp.identifier), opp)
        }
      }

      const results: IntrinsicApyResult[] = []

      for (const source of relevantSources) {
        const opp = byIdentifier.get(normalize(source.merklIdentifier))
        if (!opp || opp.status !== 'LIVE') continue

        results.push({
          address: normalize(source.address),
          info: {
            apy: opp.apr ?? 0,
            provider: 'Merkl Rewards',
            source: buildSourceUrl(chainId, source.merklIdentifier),
          },
        })
      }

      return results
    },
  }
}
