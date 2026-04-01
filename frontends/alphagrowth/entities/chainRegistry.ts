import * as allChains from '@reown/appkit/networks'
import type { AppKitNetwork } from '@reown/appkit/networks'
import { getParentChainId } from '~/entities/forkChainMap'

const tenderlyMainnetFork: AppKitNetwork = {
  id: 9991,
  name: 'Tenderly Mainnet Fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: {
      http: ['https://virtual.mainnet.eu.rpc.tenderly.co/9ed470ed-cd9d-4822-be5b-71777c0e2a38'],
    },
  },
  blockExplorers: {
    default: { name: 'Tenderly', url: 'https://dashboard.tenderly.co' },
  },
}

const chainMap = new Map<number, AppKitNetwork>(
  (Object.values(allChains) as unknown[])
    .filter((v): v is AppKitNetwork => v != null && typeof v === 'object' && 'id' in v)
    .map((chain): [number, AppKitNetwork] => [chain.id as number, chain]),
)

chainMap.set(tenderlyMainnetFork.id as number, tenderlyMainnetFork)

export const getNetworksByChainIds = (ids: readonly number[]): AppKitNetwork[] =>
  ids.map((id) => {
    const chain = chainMap.get(id)
    if (!chain) {
      throw new Error(`[chainRegistry] Unknown chain ID ${id}. Not found in @reown/appkit/networks.`)
    }
    return chain
  })

export const getChainById = (chainId: number): AppKitNetwork | undefined =>
  chainMap.get(chainId)

const DEFI_LLAMA_NAMES: ReadonlyMap<number, string> = new Map([
  [1, 'Ethereum'],
  [56, 'BSC'],
  [130, 'Unichain'],
  [146, 'Sonic'],
  [239, 'TAC'],
  [1923, 'Swell'],
  [42161, 'Arbitrum'],
  [43114, 'Avalanche'],
  [59144, 'Linea'],
  [60808, 'BOB'],
  [80094, 'Berachain'],
  [8453, 'Base'],
  [9745, 'Plasma'],
])

export const getDefiLlamaChainName = (chainId: number): string | undefined =>
  DEFI_LLAMA_NAMES.get(chainId) ?? DEFI_LLAMA_NAMES.get(getParentChainId(chainId))
