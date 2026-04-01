import { getAddress } from 'viem'
import { logWarn } from '~/utils/errorHandling'
import { useToast } from '~/components/ui/composables/useToast'
import { getDefaultPageRoute } from '~/entities/menu'

const normalizeParam = (value: unknown) => (Array.isArray(value) ? value[0] : value)

const parseChainId = (value: unknown): number | null => {
  const normalized = normalizeParam(value)
  const parsed = typeof normalized === 'string'
    ? Number.parseInt(normalized, 10)
    : typeof normalized === 'number'
      ? normalized
      : NaN

  return Number.isFinite(parsed) ? parsed : null
}

const getDefaultRoute = () => {
  const { enableEarnPage, enableLendPage, enableExplorePage } = useDeployConfig()
  return getDefaultPageRoute(enableEarnPage, enableLendPage, enableExplorePage)
}

const scheduleVaultCheck = (vaultParam: string, path: string, expectedChainId: number | null) => {
  setTimeout(async () => {
    const route = useRoute()
    const { info } = useToast()
    const { getVault, getSecuritizeVault, isSecuritizeVault } = useVaults()
    const { chainId } = useEulerAddresses()

    if (path.includes('earn')) {
      return
    }

    const currentVault = normalizeParam(route.params?.vault)
    if (!currentVault || String(currentVault) !== vaultParam) {
      return
    }

    if (route.path !== path) {
      return
    }

    if (expectedChainId !== null && chainId.value !== expectedChainId) {
      return
    }

    try {
      const vaultAddress = getAddress(String(currentVault))
      if (await isSecuritizeVault(vaultAddress)) {
        await getSecuritizeVault(vaultAddress)
      }
      else {
        await getVault(vaultAddress)
      }
    }
    catch {
      if (route.path !== path) {
        return
      }

      if (expectedChainId !== null && chainId.value !== expectedChainId) {
        return
      }

      info('This vault could not be found on this chain!')
      void navigateTo({
        name: getDefaultRoute(),
        query: { ...route.query },
        hash: route.hash,
      }, { replace: true })
    }
  }, 0)
}

export default defineNuxtRouteMiddleware(async (to, from) => {
  const { info } = useToast()
  if (import.meta.server) {
    return
  }

  if (from && to.path === from.path) {
    const toVaultParam = normalizeParam(to.params?.vault)
    const fromVaultParam = normalizeParam(from.params?.vault)
    if (toVaultParam === fromVaultParam) {
      const toNetworkId = parseChainId(to.query.network)
      const fromNetworkId = parseChainId(from.query.network)
      if (toVaultParam && toNetworkId !== fromNetworkId) {
        scheduleVaultCheck(String(toVaultParam), to.path, toNetworkId)
      }
      return
    }
  }

  const rawVault = to.params?.vault
  if (!rawVault) {
    return
  }

  let vaultAddress: string | null = null
  try {
    vaultAddress = getAddress(String(normalizeParam(rawVault)))
  }
  catch {
    info('This vault could not be found on this chain!')
    return navigateTo({
      name: getDefaultRoute(),
      query: { ...to.query },
      hash: to.hash,
    }, { replace: true })
  }

  const { getVault, getSecuritizeVault, isSecuritizeVault } = useVaults()

  if (!to.path.includes('earn') && vaultAddress) {
    try {
      if (await isSecuritizeVault(vaultAddress)) {
        await getSecuritizeVault(vaultAddress)
      }
      else {
        await getVault(vaultAddress)
      }
    }
    catch {
      logWarn('ensure-vault', 'failed to load vault')
      info('This vault could not be found on this chain!')
      return navigateTo({
        name: getDefaultRoute(),
        query: { ...to.query },
        hash: to.hash,
      }, { replace: true })
    }
  }
})
