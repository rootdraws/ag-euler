import { getChainById } from '~/entities/chainRegistry'

const cleanUrl = (url?: string) => {
  if (!url) return ''
  return url.endsWith('/') ? url : `${url}/`
}

const resolveExplorerBase = (chainId?: number) => {
  if (chainId) {
    const chain = getChainById(chainId)
    const url = cleanUrl(chain?.blockExplorers?.default.url)
    if (url) return url
  }

  const mainnet = getChainById(1)
  return cleanUrl(mainnet?.blockExplorers?.default.url) || 'https://etherscan.io/'
}

export const getExplorerLink = (
  hashOrAddress?: string,
  chainId?: number,
  isAddress = false,
) => {
  const baseUrl = resolveExplorerBase(chainId)
  if (!hashOrAddress) {
    return baseUrl
  }

  const chain = chainId ? getChainById(chainId) : undefined
  const explorerName = chain?.blockExplorers?.default?.name
  const path = isAddress
    ? 'address'
    : explorerName === 'Tenderly'
      ? 'tx/mainnet'
      : 'tx'

  return `${baseUrl}${path}/${hashOrAddress}`
}
