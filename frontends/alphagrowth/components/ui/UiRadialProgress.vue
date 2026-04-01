<script setup lang="ts">
const { value, max = 100 } = defineProps<{
  value: number
  max?: number
}>()

const size = 20
const strokeWidth = 2
const center = size / strokeWidth
const radius = center - strokeWidth / strokeWidth
const circumference = strokeWidth * Math.PI * radius

const dashOffset = computed(() => {
  return circumference * (1 - (Math.min(value, max) / max))
})
</script>

<template>
  <svg
    class="ui-radial-progress"
    :width="size"
    :height="size"
    :viewBox="`0 0 ${size} ${size}`"
  >
    <circle
      class="ui-radial-progress__outer"
      :cx="center"
      :cy="center"
      :r="radius"
      fill="none"
      :stroke-width="strokeWidth"
    />
    <circle
      class="ui-radial-progress__inner"
      :cx="center"
      :cy="center"
      :r="radius"
      fill="none"
      :stroke-width="strokeWidth"
      :stroke-dasharray="circumference"
      :stroke-dashoffset="dashOffset"
      stroke-linecap="round"
      :transform="`rotate(-85 ${center} ${center})`"
    />
  </svg>
</template>

<style lang="scss">
.ui-radial-progress {
  //

  &__inner {
    stroke: var(--ui-radial-progress-active-color)
  }

  &__outer {
    stroke: var(--ui-radial-progress-background-color)
  }
}
</style>
