const parseChainId = (value: unknown): number | null => {
  const normalized = Array.isArray(value) ? value[0] : value
  const parsed = typeof normalized === 'string'
    ? Number.parseInt(normalized, 10)
    : typeof normalized === 'number'
      ? normalized
      : NaN

  return Number.isFinite(parsed) ? parsed : null
}

export default defineNuxtRouteMiddleware((to) => {
  if (import.meta.server) {
    return
  }

  const { chainId } = useEulerAddresses()

  const queryChainId = parseChainId(to.query.network)
  const savedChainId = parseChainId(localStorage.getItem('chainId'))
  const fallbackChainId = queryChainId ?? savedChainId ?? (chainId.value || 1)

  if (!queryChainId || queryChainId !== fallbackChainId) {
    return navigateTo({
      path: to.path,
      query: {
        ...to.query,
        network: fallbackChainId,
      },
      hash: to.hash,
    })
  }
})
