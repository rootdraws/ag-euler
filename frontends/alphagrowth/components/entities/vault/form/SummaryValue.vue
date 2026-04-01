<script setup lang="ts">
const props = defineProps<{
  before?: string | null
  after?: string | null
  suffix?: string
  estimateOnly?: boolean
}>()

const showTransition = computed(() => {
  if (props.estimateOnly) return false
  return props.before != null && props.after != null && props.before !== props.after
})
</script>

<template>
  <p class="text-p2">
    <template v-if="showTransition">
      <span class="text-content-tertiary">{{ before }}{{ suffix ? suffix : '' }}</span>
      &rarr; <span class="text-content-primary">{{ after }}{{ suffix ? suffix : '' }}</span>
    </template>
    <template v-else>
      <span class="text-content-primary">{{ after ?? before ?? '-' }}{{ (after ?? before) != null && suffix ? suffix : '' }}</span>
    </template>
  </p>
</template>
