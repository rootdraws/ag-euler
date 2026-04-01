<script setup lang="ts">
defineProps<{
  label: string
  alignTop?: boolean
}>()
</script>

<template>
  <div
    class="flex justify-between flex-wrap gap-8"
    :class="alignTop ? 'items-start' : 'items-center'"
  >
    <p class="text-content-tertiary shrink-0">
      {{ label }}
    </p>
    <div class="ml-auto text-right">
      <slot />
    </div>
  </div>
</template>
