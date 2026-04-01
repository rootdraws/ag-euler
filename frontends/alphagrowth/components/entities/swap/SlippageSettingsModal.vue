<script setup lang="ts">
const emit = defineEmits(['close'])
</script>

<template>
  <BaseModalWrapper
    @close="emit('close')"
  >
    <SlippageSettings />
    <UiButton
      variant="primary"
      size="xlarge"
      @click="emit('close')"
    >
      Save
    </UiButton>
  </BaseModalWrapper>
</template>
