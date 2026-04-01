<script setup lang="ts">
import type { AlignedPlacement } from '@floating-ui/vue'
import type { VaultWarning } from '~/composables/useVaultWarnings'

const { warning, tooltipPlacement = 'top-end' } = defineProps<{
  warning: VaultWarning | null
  tooltipPlacement?: AlignedPlacement
}>()
</script>

<template>
  <UiFootnote
    v-if="warning"
    :icon="warning.level === 'info' ? 'info-circle' : 'warning'"
    :title="warning.title"
    :text="warning.message"
    :tooltip-placement="tooltipPlacement"
    :class="warning.level === 'critical'
      ? '[--ui-footnote-icon-color:var(--error-500)]'
      : warning.level === 'info'
        ? '[--ui-footnote-icon-color:var(--warning-500)]'
        : '[--ui-footnote-icon-color:var(--warning-500)]'"
  />
</template>
