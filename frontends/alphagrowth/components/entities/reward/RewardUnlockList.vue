<script setup lang="ts">
import type { REULLock } from '~/entities/reul'

defineProps<{
  items: REULLock[]
}>()
</script>

<template>
  <div
    class="flex flex-col gap-8"
  >
    <RewardUnlockItem
      v-for="(item, idx) in items"
      :key="`unlock-${idx}`"
      :item="item"
    />
  </div>
</template>
