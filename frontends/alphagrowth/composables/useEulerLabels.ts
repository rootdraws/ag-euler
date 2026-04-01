/* eslint-disable @typescript-eslint/no-dynamic-delete */
import axios from 'axios'
import { getAddress } from 'viem'
import type { EulerLabelPoint } from '~/entities/euler/labels'
import type { EarnVault, Vault } from '~/entities/vault'
import { safeAssign } from '~/utils/safe-assign'
import { logWarn } from '~/utils/errorHandling'
import { CACHE_TTL_5MIN_MS } from '~/entities/tuning-constants'
import { normalizeAddress } from '~/utils/normalizeAddress'
import { getParentChainId } from '~/entities/forkChainMap'
import {
  isLoading,
  loadState,
  products,
  entities,
  points,
  earnVaults,
  earnVaultBlocks,
  earnVaultRestrictions,
  featuredEarnVaults,
  verifiedVaultAddresses,
  oracleAdapters,
  loadingAdapters,
} from '~/utils/eulerLabelsState'
import {
  normalizeProducts,
  normalizeEntities,
  normalizeOracleAdapters,
  getProductByVault,
  getEntitiesByVault,
  getEntitiesByEarnVault,
  getPointsByVault,
  applyVaultOverrides,
} from '~/utils/eulerLabelsUtils'

let _labelsRepo = 'euler-xyz/euler-labels'
let _labelsRepoBranch = 'master'
let _oracleChecksRepo = 'euler-xyz/oracle-checks'
let _isCustomLabelsRepo = false
let _enableEarnPage = true

const initRepos = () => {
  const { labelsRepo, labelsRepoBranch, oracleChecksRepo, isCustomLabelsRepo, enableEarnPage } = useDeployConfig()
  _labelsRepo = labelsRepo
  _labelsRepoBranch = labelsRepoBranch
  _oracleChecksRepo = oracleChecksRepo
  _isCustomLabelsRepo = isCustomLabelsRepo.value
  _enableEarnPage = enableEarnPage
}

const getLabelsUrl = (chainId: number, file: string) =>
  `https://raw.githubusercontent.com/${_labelsRepo}/${_labelsRepoBranch}/${getParentChainId(chainId)}/${file}`

const getOracleChecksUrl = (chainId: number, file: string) =>
  `https://raw.githubusercontent.com/${_oracleChecksRepo}/master/data/${chainId}/${file}`

const loadOracleAdapter = async (chainId: number, oracleAddress: string) => {
  const checksummed = getAddress(oracleAddress)
  const key = checksummed.toLowerCase()

  if (oracleAdapters[key]) {
    return oracleAdapters[key]
  }

  if (loadingAdapters.has(key)) {
    return undefined
  }

  loadingAdapters.add(key)
  try {
    const url = getOracleChecksUrl(chainId, `adapters/${checksummed}.json`)
    const res = await axios.get(url)
    const meta = normalizeOracleAdapters([res.data])
    safeAssign(oracleAdapters, meta)
    return oracleAdapters[key]
  }
  catch {
    return undefined
  }
  finally {
    loadingAdapters.delete(key)
  }
}

const loadOracleAdapters = async (chainId: number, addresses?: string[]) => {
  if (!addresses?.length) {
    return
  }
  await Promise.all(addresses.map(addr => loadOracleAdapter(chainId, addr)))
}

export const useEulerLabels = () => {
  initRepos()

  const loadLabels = async (forceRefresh = false) => {
    try {
      const { getCurrentChainConfig, loadEulerConfig } = useEulerAddresses()

      if (!getCurrentChainConfig.value) {
        loadEulerConfig()
      }
      await until(getCurrentChainConfig).toBeTruthy()

      const chainId = getCurrentChainConfig.value!.chainId
      const now = Date.now()

      if (!forceRefresh
        && loadState.chainId === chainId
        && Object.keys(products).length > 0
        && (now - loadState.timestamp) < CACHE_TTL_5MIN_MS) {
        return
      }

      isLoading.value = true

      Object.keys(products).forEach(key => delete products[key])
      Object.keys(entities).forEach(key => delete entities[key])
      Object.keys(points).forEach(key => delete points[key])
      Object.keys(oracleAdapters).forEach(key => delete oracleAdapters[key])
      Object.keys(earnVaultBlocks).forEach(key => delete earnVaultBlocks[key])
      Object.keys(earnVaultRestrictions).forEach(key => delete earnVaultRestrictions[key])
      featuredEarnVaults.clear()
      earnVaults.value = []
      verifiedVaultAddresses.value = []

      const [productRes, entitiesRes, pointsRes] = await Promise.all([
        axios.get(getLabelsUrl(chainId, 'products.json')),
        axios.get(getLabelsUrl(chainId, 'entities.json')),
        axios.get(getLabelsUrl(chainId, 'points.json')),
      ])

      if (_isCustomLabelsRepo) {
        try {
          const earnRes = await axios.get(getLabelsUrl(chainId, 'earn-vaults.json'))
          const earnEntries = earnRes.data as Array<string | { address: string, block?: string[], restricted?: string[], featured?: boolean }>
          earnVaults.value = earnEntries.map((entry) => {
            if (typeof entry === 'string') return normalizeAddress(entry)
            const addr = normalizeAddress(entry.address)
            if (entry.block?.length) {
              earnVaultBlocks[addr.toLowerCase()] = entry.block
            }
            if (entry.restricted?.length) {
              earnVaultRestrictions[addr.toLowerCase()] = entry.restricted
            }
            if (entry.featured) {
              featuredEarnVaults.add(addr)
            }
            return addr
          })
        }
        catch {
          if (_enableEarnPage) {
            logWarn('labels/earn-vaults', `earn-vaults.json not found on ${_labelsRepo}@${_labelsRepoBranch}`)
          }
        }
      }

      const normalizedProducts = normalizeProducts(productRes.data)
      safeAssign(products, normalizedProducts.products)
      verifiedVaultAddresses.value = normalizedProducts.vaultAddresses

      safeAssign(entities, normalizeEntities(entitiesRes.data))

      const pointsData = pointsRes.data as EulerLabelPoint[]
      pointsData.forEach((point) => {
        if (!point.collateralVaults || point.isTurtleClub) {
          return
        }

        point.collateralVaults.forEach((vaultAddress) => {
          const normalized = normalizeAddress(vaultAddress)
          if (!points[normalized]) {
            points[normalized] = []
          }
          points[normalized].push({
            name: point.name,
            logo: point.logo,
          })
        })
      })

      loadState.chainId = chainId
      loadState.timestamp = Date.now()
    }
    catch (e) {
      logWarn('labels/load', e)
    }
    finally {
      isLoading.value = false
    }
  }

  return {
    isLoading,
    verifiedVaultAddresses,
    products,
    entities,
    points,
    oracleAdapters,
    earnVaults,
    loadLabels,
    loadOracleAdapter,
    loadOracleAdapters,
  }
}

export const useEulerProductOfVault = (vaultAddress: string | Ref<string>) => {
  return toReactive(computed(() => {
    const addr = unref(vaultAddress)
    return applyVaultOverrides(getProductByVault(addr), addr)
  }))
}

export const useEulerEntitiesOfVault = (vault: Vault | Ref<Vault>) => {
  return toReactive(computed(() => getEntitiesByVault(unref(vault))))
}

export const useEulerEntitiesOfEarnVault = (earnVault: EarnVault | Ref<EarnVault>) => {
  return toReactive(computed(() => getEntitiesByEarnVault(unref(earnVault))))
}

export const useEulerPointsOfVault = (vaultAddress: string | Ref<string>) => {
  return toReactive(computed(() => getPointsByVault(unref(vaultAddress))))
}
