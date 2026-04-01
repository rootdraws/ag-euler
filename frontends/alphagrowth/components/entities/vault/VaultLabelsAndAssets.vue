<script setup lang="ts">
import { getAddress } from 'viem'
import type { EarnVault, SecuritizeVault, Vault, VaultAsset } from '~/entities/vault'
import { useEulerProductOfVault } from '~/composables/useEulerLabels'
import { isAnyVaultBlockedByCountry } from '~/composables/useGeoBlock'

const { vault, assets, size, assetsLabel, pairVault } = defineProps<{
  vault: Vault | EarnVault | SecuritizeVault
  assets: VaultAsset[]
  size?: 'large'
  assetsLabel?: string
  pairVault?: Vault
}>()
const vaultAddress = computed(() => getAddress(vault.address))
const product = useEulerProductOfVault(vaultAddress)
const displayName = computed(() => {
  if ('vaultCategory' in vault && vault.vaultCategory === 'escrow') {
    return 'Escrowed collateral'
  }
  return product.name || vault.name
})

const pairVaultAddress = computed(() => pairVault ? getAddress(pairVault.address) : '')
const pairProduct = useEulerProductOfVault(pairVaultAddress)

const isVaultDeprecated = computed(() => {
  const addr = vaultAddress.value
  return product.deprecatedVaults?.includes(addr) ?? false
})
const isPairVaultDeprecated = computed(() => {
  if (!pairVault) return false
  const addr = pairVaultAddress.value
  return pairProduct.deprecatedVaults?.includes(addr) ?? false
})
const isDeprecated = computed(() => isVaultDeprecated.value || isPairVaultDeprecated.value)
const isRestricted = computed(() => {
  const addresses = [vault.address]
  if (pairVault) addresses.push(pairVault.address)
  return isAnyVaultBlockedByCountry(...addresses)
})

const getVaultLabel = (v: Vault | EarnVault | SecuritizeVault) => {
  if ('vaultCategory' in v && v.vaultCategory === 'escrow') {
    return 'Escrowed collateral'
  }
  const addr = getAddress(v.address)
  if (addr === vaultAddress.value) {
    return product.name || vault.name
  }
  return pairProduct.name || v.name
}

const displayLabel = computed(() => {
  const collateralLabel = getVaultLabel(vault)

  if (!pairVault) {
    return collateralLabel
  }

  const borrowLabel = getVaultLabel(pairVault)

  if (collateralLabel === borrowLabel) {
    return collateralLabel
  }

  return `${collateralLabel} / ${borrowLabel}`
})

const displayAssetsLabel = computed(() => assetsLabel || assets.map(asset => asset.symbol).join('/'))
</script>

<template>
  <div
    :class="[size === 'large' ? 'gap-16' : 'gap-12']"
    class="flex items-center"
  >
    <AssetAvatar
      :asset="assets"
      :size="size === 'large' ? '46' : '38'"
    />

    <div>
      <div class="flex items-center gap-8 mb-4">
        <span class="text-content-tertiary">
          <VaultDisplayName
            :name="pairVault ? displayLabel : displayName"
            :is-unverified="('verified' in vault && !vault.verified) || !!(pairVault && 'verified' in pairVault && !pairVault.verified)"
          />
        </span>
        <span
          v-if="isDeprecated"
          class="inline-flex items-center gap-4 rounded-8 px-8 py-2 bg-warning-100 text-warning-500 text-p5"
        >
          <SvgIcon
            name="warning"
            class="!w-14 !h-14"
          />
          Deprecated
        </span>
        <span
          v-if="isRestricted"
          class="inline-flex items-center gap-4 rounded-8 px-8 py-2 bg-warning-100 text-warning-500 text-p5"
          title="This vault is not available in your region"
        >
          <SvgIcon
            name="warning"
            class="!w-14 !h-14"
          />
          Restricted
        </span>
      </div>

      <p class="text-p2 font-semibold text-content-primary">
        {{ displayAssetsLabel }}
      </p>
    </div>
  </div>
</template>
