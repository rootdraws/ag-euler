<script setup lang="ts">
type SwapRouteBadgeTone = 'best' | 'worse'

type SwapRouteItem = {
  provider: string
  amount: string
  symbol: string
  routeLabel?: string
  badge?: {
    label: string
    tone: SwapRouteBadgeTone
  }
}

withDefaults(defineProps<{
  title?: string
  statusLabel?: string | null
  items: SwapRouteItem[]
  selectedProvider?: string | null
  isLoading?: boolean
  emptyMessage?: string
}>(), {
  title: 'Select swap route',
  statusLabel: null,
  selectedProvider: null,
  isLoading: false,
  emptyMessage: 'Enter amount to fetch quotes',
})

const emit = defineEmits<{
  (e: 'select', provider: string): void
  (e: 'refresh'): void
}>()

const onSelect = (provider: string) => {
  emit('select', provider)
}
</script>

<template>
  <div class="bg-surface-secondary p-16 rounded-16 flex flex-col gap-12 border border-line-default">
    <div class="flex justify-between items-center">
      <p class="text-p2 text-content-primary">
        {{ title }}
      </p>
      <div class="flex items-center gap-8">
        <p class="text-p3 text-content-secondary">
          {{ statusLabel || '-' }}
        </p>
        <button
          type="button"
          aria-label="Refresh swap quotes"
          class="text-content-secondary hover:text-accent-600 transition-colors disabled:opacity-50"
          :disabled="isLoading || !items.length"
          @click="emit('refresh')"
        >
          <SvgIcon
            name="refresh"
            class="!w-16 !h-16"
            :class="{ 'animate-spin': isLoading }"
          />
        </button>
      </div>
    </div>
    <div class="flex flex-col gap-8 max-h-[240px] overflow-y-auto pr-4">
      <template v-if="items.length">
        <button
          v-for="item in items"
          :key="item.provider"
          type="button"
          class="w-full text-left rounded-12 border p-12 transition-colors"
          :class="selectedProvider === item.provider
            ? 'border-accent-500 bg-neutral-200'
            : 'border-line-default bg-surface hover:bg-surface-secondary'"
          @click="onSelect(item.provider)"
        >
          <div class="flex items-center justify-between gap-8">
            <p class="text-p2 text-content-primary">
              {{ item.amount }} {{ item.symbol }}
            </p>
            <div class="flex flex-col items-end gap-2 text-p3 text-content-secondary">
              <p
                v-if="item.badge"
                :class="item.badge.tone === 'best' ? 'text-success-600' : 'text-error-500'"
              >
                {{ item.badge.label }}
              </p>
              <span class="truncate">{{ item.routeLabel || '-' }}</span>
            </div>
          </div>
        </button>
      </template>
      <template v-else-if="isLoading">
        <div class="h-48 rounded-12 bg-surface animate-pulse" />
        <div class="h-48 rounded-12 bg-surface animate-pulse" />
        <div class="h-48 rounded-12 bg-surface animate-pulse" />
      </template>
      <template v-else>
        <p class="text-p3 text-content-secondary">
          {{ emptyMessage }}
        </p>
      </template>
    </div>
  </div>
</template>
