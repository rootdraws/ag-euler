<script setup lang="ts">
import { getAddress, isAddress } from 'viem'
import type { VaultAsset } from '~/entities/vault'
import { formatNumber } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'

const emits = defineEmits<{
  close: []
}>()

const { onSelect, currentAssetAddress } = defineProps<{
  onSelect: (asset: VaultAsset) => void
  currentAssetAddress?: string
}>()

const { getByType } = useVaultRegistry()
const { getBalance } = useWallets()
const {
  customToken,
  customTokenBalance,
  isLoading: isCustomTokenLoading,
  error: customTokenError,
  resolve: resolveCustomToken,
  reset: resetCustomToken,
} = useCustomTokenResolver()

const searchQuery = ref('')

interface TokenOption {
  asset: VaultAsset
  balance: bigint
  balanceFormatted: number
}

const tokenOptions = computed((): TokenOption[] => {
  const seen = new Set<string>()
  const options: TokenOption[] = []

  const allVaults = [...getByType('evk'), ...getByType('earn'), ...getByType('securitize')]
  for (const vault of allVaults) {
    if (!vault.asset?.address) continue
    let normalized: string
    try {
      normalized = getAddress(vault.asset.address)
    }
    catch {
      continue
    }
    if (seen.has(normalized)) continue
    seen.add(normalized)

    const balance = getBalance(normalized as `0x${string}`)
    options.push({
      asset: vault.asset,
      balance,
      balanceFormatted: nanoToValue(balance, vault.asset.decimals),
    })
  }

  // Sort: tokens with balance first (desc by balance), then alphabetically
  return options.sort((a, b) => {
    if (a.balance > 0n && b.balance <= 0n) return -1
    if (a.balance <= 0n && b.balance > 0n) return 1
    if (a.balance > 0n && b.balance > 0n) {
      if (a.balanceFormatted > b.balanceFormatted) return -1
      if (a.balanceFormatted < b.balanceFormatted) return 1
    }
    return a.asset.symbol.localeCompare(b.asset.symbol)
  })
})

const knownAddresses = computed(() => {
  const set = new Set<string>()
  for (const opt of tokenOptions.value) {
    set.add(opt.asset.address.toLowerCase())
  }
  return set
})

const isUnknownAddress = computed(() => {
  const q = searchQuery.value.trim()
  return isAddress(q) && !knownAddresses.value.has(q.toLowerCase())
})

const filteredOptions = computed(() => {
  if (!searchQuery.value) return tokenOptions.value
  const q = searchQuery.value.toLowerCase()
  return tokenOptions.value.filter(opt =>
    opt.asset.symbol.toLowerCase().includes(q)
    || opt.asset.name.toLowerCase().includes(q)
    || opt.asset.address.toLowerCase().includes(q),
  )
})

watch(searchQuery, (q) => {
  const trimmed = q.trim()
  if (isAddress(trimmed) && !knownAddresses.value.has(trimmed.toLowerCase())) {
    resolveCustomToken(trimmed)
  }
  else {
    resetCustomToken()
  }
})

const isSelected = (address: string) => {
  if (!currentAssetAddress) return false
  try {
    return getAddress(address) === getAddress(currentAssetAddress)
  }
  catch {
    return false
  }
}

const handleSelect = (opt: TokenOption) => {
  onSelect(opt.asset)
  emits('close')
}

const handleSelectCustomToken = () => {
  if (!customToken.value) return
  onSelect(customToken.value)
  emits('close')
}
</script>

<template>
  <BaseModalWrapper
    title="Select asset"
    full
    @close="$emit('close')"
  >
    <div class="px-16 pb-12">
      <UiInput
        v-model="searchQuery"
        placeholder="Search by name, symbol, or address"
        icon="search"
        clearable
      />
    </div>
    <div class="flex-1 overflow-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      <div
        v-for="opt in filteredOptions"
        :key="opt.asset.address"
        class="flex items-center py-12 px-16 rounded-16 cursor-pointer"
        :class="isSelected(opt.asset.address) ? 'bg-euler-dark-600' : ''"
        @click="handleSelect(opt)"
      >
        <AssetAvatar
          :asset="opt.asset"
          size="36"
          class="mr-10"
        />
        <div class="flex-grow">
          <div class="text-euler-dark-900 mb-2">
            {{ opt.asset.name }}
          </div>
          <div class="text-h5">
            {{ opt.asset.symbol }}
          </div>
        </div>
        <div class="text-right">
          <div class="text-euler-dark-900 mb-2">
            Balance
          </div>
          <div class="text-h5">
            {{ opt.balance > 0n ? formatNumber(opt.balanceFormatted, 6, 0) : '0' }}
          </div>
        </div>
      </div>
      <!-- Custom token: loading -->
      <div
        v-if="isUnknownAddress && isCustomTokenLoading"
        class="flex items-center justify-center py-24 gap-8 text-content-tertiary text-p3"
      >
        <UiLoader class="text-neutral-500" />
        Looking up token...
      </div>

      <!-- Custom token: resolved -->
      <div
        v-else-if="isUnknownAddress && customToken"
        class="flex items-center py-12 px-16 rounded-16 cursor-pointer hover:bg-euler-dark-600"
        @click="handleSelectCustomToken"
      >
        <AssetAvatar
          :asset="customToken"
          size="36"
          class="mr-10"
        />
        <div class="flex-grow">
          <div class="flex items-center gap-6 mb-2">
            <span class="text-euler-dark-900">{{ customToken.name }}</span>
            <span class="inline-flex items-center rounded-8 px-8 py-2 bg-warning-100 text-warning-500 text-p5">
              Import
            </span>
          </div>
          <div class="text-h5">
            {{ customToken.symbol }}
          </div>
        </div>
        <div class="text-right">
          <div class="text-euler-dark-900 mb-2">
            Balance
          </div>
          <div class="text-h5">
            {{ customTokenBalance > 0n ? formatNumber(nanoToValue(customTokenBalance, customToken.decimals), 6, 0) : '0' }}
          </div>
        </div>
      </div>

      <!-- Custom token: error -->
      <div
        v-else-if="isUnknownAddress && customTokenError"
        class="py-24 text-center text-content-tertiary text-p3"
      >
        {{ customTokenError }}
      </div>

      <!-- No results (only when NOT resolving a custom address) -->
      <div
        v-if="!filteredOptions.length && searchQuery && !isUnknownAddress"
        class="py-24 text-center text-content-tertiary text-p3"
      >
        No results found
      </div>
    </div>
  </BaseModalWrapper>
</template>
