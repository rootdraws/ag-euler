<script setup lang="ts">
import { useMarketGroups } from '~/composables/useMarketGroups'

defineOptions({
  name: 'ExploreMarketPage',
})

const route = useRoute()
const marketKey = computed(() => route.params.market as string)

const { marketGroups, isResolvingTVL } = useMarketGroups()
const { isUpdating, isEarnUpdating, isEscrowUpdating } = useVaults()

const isLoading = computed(() =>
  isUpdating.value || isEarnUpdating.value || isEscrowUpdating.value
  || isResolvingTVL.value || marketGroups.value.length === 0,
)

const market = computed(() =>
  marketGroups.value.find(g => g.id === marketKey.value),
)
</script>

<template>
  <section class="flex flex-col min-h-[calc(100dvh-178px)]">
    <!-- Back link -->
    <NuxtLink
      to="/explore"
      class="flex items-center gap-4 text-p3 text-content-tertiary hover:text-accent-600 transition-colors mb-16"
    >
      <UiIcon
        name="arrow-left"
        class="!w-16 !h-16"
      />
      Back to Explore
    </NuxtLink>

    <!-- Loading -->
    <UiLoader
      v-if="isLoading"
      class="flex-1 self-center justify-self-center"
    />

    <!-- Market not found -->
    <div
      v-else-if="!market"
      class="flex flex-col flex-1 gap-12 items-center justify-center text-content-tertiary"
    >
      <UiIcon
        name="search"
        class="!w-24 !h-24"
      />
      <div class="text-center max-w-[240px]">
        Market not found. It may not exist on this network.
      </div>
      <NuxtLink
        to="/explore"
        class="text-p3 text-accent-600 underline mt-8"
      >
        Browse all markets
      </NuxtLink>
    </div>

    <!-- Market page -->
    <template v-else>
      <DiscoveryMarketAccordion
        :markets="[market]"
        :initial-expanded="[market.id]"
      />
    </template>
  </section>
</template>
