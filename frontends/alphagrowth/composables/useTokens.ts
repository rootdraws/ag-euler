/* eslint-disable @typescript-eslint/no-dynamic-delete */
import axios from 'axios'
import type {
  TokenData,
} from '~/entities/token'
import { useEulerConfig } from '~/composables/useEulerConfig'
import { safeAssign } from '~/utils/safe-assign'
import { logWarn } from '~/utils/errorHandling'

const isLoading = ref(false)
const tokensByAddress: Record<string, TokenData> = shallowReactive({})

export const useTokens = () => {
  const { getCurrentChainConfig, chainId } = useEulerAddresses()
  const { EULER_API_URL } = useEulerConfig()

  const loadTokens = async () => {
    try {
      isLoading.value = true
      Object.keys(tokensByAddress).forEach(key => delete tokensByAddress[key])

      await until(getCurrentChainConfig).toBeTruthy()

      if (!EULER_API_URL) {
        throw new Error('Tokens API URL is not configured')
      }
      const res = await axios.get(`${EULER_API_URL}/v1/tokens?chainId=${chainId.value}`)

      const tokensArr = res.data as TokenData[]

      safeAssign(tokensByAddress, Object.fromEntries(tokensArr.map(token => [token.address.toLowerCase(), token])))
    }
    catch (e) {
      logWarn('tokens/fetch', e)
    }
    finally {
      isLoading.value = false
    }
  }

  return {
    isLoading,
    tokens: tokensByAddress,
    loadTokens,
  }
}

const tokenIconOverrides = new Map(
  Object.entries(
    import.meta.glob('~/assets/tokens/*', { eager: true, query: '?url', import: 'default' }),
  ).map(([path, url]) => {
    const symbol = path.split('/').pop()?.split('.')[0]?.toLowerCase() ?? ''
    return [symbol, url as string]
  }),
)

export const getAssetLogoUrl = (address: string, symbol: string) => {
  return tokenIconOverrides.get(symbol.toLowerCase())
    ?? tokensByAddress[address.toLowerCase()]?.logoURI
    ?? ''
}
