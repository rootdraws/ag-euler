<script setup lang="ts">
defineProps<{ loading: boolean }>()
</script>

<template>
  <Transition
    name="instant-fade"
    mode="out-in"
  >
    <div
      v-if="loading"
      class="w-80 h-20 rounded-12 bg-[rgba(200,200,200,0.1)]"
    />
    <slot v-else />
  </Transition>
</template>
