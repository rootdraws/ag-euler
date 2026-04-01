<script setup lang="ts">
const { label, value, orientation = 'vertical' } = defineProps<{
  label?: string
  value?: string
  orientation?: 'horizontal' | 'vertical'
}>()
</script>

<template>
  <div
    class="flex gap-8"
    :class="[orientation === 'horizontal' ? 'flex-row justify-between w-full' : 'flex flex-col']"
  >
    <div class="text-p3 text-content-tertiary">
      <slot name="label">
        {{ label }}
      </slot>
    </div>
    <div class="text-p2 text-content-primary">
      <slot>
        {{ value || '-' }}
      </slot>
    </div>
  </div>
</template>
