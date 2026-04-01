import type { Hex } from 'viem'
import { hashMessage, keccak256, stringToHex } from 'viem'
import { logWarn } from '~/utils/errorHandling'

let cachedTosData: TosData | null = null
let fetchPromise: Promise<TosData> | null = null

export interface TosData {
  tosMessage: string
  tosMessageHash: Hex
}

export async function getTosData(): Promise<TosData> {
  if (cachedTosData) {
    return cachedTosData
  }
  if (fetchPromise) {
    return fetchPromise
  }

  const { tosUrl, tosMdUrl } = useDeployConfig()

  if (!tosMdUrl) {
    throw new Error('TOS markdown URL not configured (NUXT_PUBLIC_CONFIG_TOS_MD_URL)')
  }

  fetchPromise = fetch(tosMdUrl)
    .then((response) => {
      if (!response.ok) {
        throw new Error(`Failed to fetch ToS: ${response.status} ${response.statusText}`)
      }
      return response.text()
    })
    .then((content) => {
      const tosHash = hashMessage(content)
      const tosHashShort = `0x${tosHash.slice(-6)}`
      const tosMessage = `By proceeding to engage with and use Euler, you accept and agree to abide by the Terms of Use: ${tosUrl}\n\nhash:${tosHashShort}`
      const tosMessageHash = keccak256(stringToHex(tosMessage))
      cachedTosData = { tosMessage, tosMessageHash }
      return cachedTosData
    })
    .catch((error) => {
      logWarn('tos/loadMarkdown', error, { severity: 'error' })
      throw error
    })
    .finally(() => {
      fetchPromise = null
    })

  return fetchPromise
}
