<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { getSubAccountIndex } from '~/entities/account'

const { isConnected, address } = useAccount()
const { borrowPositions, isPositionsLoaded, portfolioAddress } = useEulerAccount()
const { isReady } = useVaults()

const ownerAddress = computed(() => portfolioAddress.value || address.value || '')

const sortedBorrowPositions = computed(() => {
  if (!ownerAddress.value) return borrowPositions.value
  return [...borrowPositions.value].sort((a, b) => {
    const indexA = getSubAccountIndex(ownerAddress.value, a.subAccount)
    const indexB = getSubAccountIndex(ownerAddress.value, b.subAccount)
    return indexA - indexB
  })
})
</script>

<template>
  <div
    class="flex mx-16 p-8 rounded-12 border border-line-default bg-surface shadow-card"
    :class="sortedBorrowPositions.length === 0 ? 'flex-1' : ''"
  >
    <div
      v-if="isConnected && (!isPositionsLoaded || (!isReady && sortedBorrowPositions.length === 0))"
      class="flex flex-1 justify-center items-center"
    >
      <UiLoader class="text-content-tertiary" />
    </div>

    <div
      v-else-if="sortedBorrowPositions.length === 0"
      class="flex flex-1 justify-center items-center"
    >
      <div class="flex flex-col gap-8 items-center text-content-tertiary">
        <div class="flex w-48 h-48 justify-center items-center rounded-12 bg-surface-secondary">
          <SvgIcon name="search" />
        </div>
        <template v-if="isConnected">
          You don't have positions yet
        </template>
        <template v-else>
          Connect your wallet to see your positions
        </template>
      </div>
    </div>

    <div
      v-else
      class="w-full"
    >
      <PortfolioList
        :items="sortedBorrowPositions"
        type="borrow"
      />
      <div
        v-if="!isReady"
        class="flex justify-center items-center mt-12"
      >
        <UiLoader class="text-content-tertiary" />
      </div>
    </div>
  </div>
</template>
