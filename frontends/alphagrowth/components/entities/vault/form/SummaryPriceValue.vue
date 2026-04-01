<script setup lang="ts">
const props = defineProps<{
  before?: string | null
  after?: string | null
  value?: string | null
  symbol?: string
  invertible?: boolean
  estimateOnly?: boolean
}>()

const emit = defineEmits<{
  invert: []
}>()

const displayValue = computed(() => props.value ?? props.after ?? props.before ?? null)

const showTransition = computed(() => {
  if (props.estimateOnly) return false
  return props.before != null && props.after != null && props.before !== props.after
})
</script>

<template>
  <p class="text-p2 text-right inline-flex items-center">
    <template v-if="showTransition">
      <span class="text-content-tertiary">{{ before }}</span>
      &rarr; <span class="text-content-primary">{{ after }}</span>
    </template>
    <template v-else>
      <span class="text-content-primary">{{ displayValue ?? '-' }}</span>
    </template>
    <span
      v-if="displayValue != null && symbol"
      class="text-content-tertiary text-p3 ml-4"
    >
      {{ symbol }}
    </span>
    <button
      v-if="invertible && displayValue != null"
      type="button"
      class="ml-4 text-content-tertiary hover:text-content-primary transition-colors inline-flex"
      @click.stop="emit('invert')"
    >
      <SvgIcon
        name="swap-horizontal"
        class="!w-12 !h-12"
      />
    </button>
  </p>
</template>
