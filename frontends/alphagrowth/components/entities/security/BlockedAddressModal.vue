<script setup lang="ts">
defineProps<{
  address: string
}>()
const emits = defineEmits(['close'])

const handleClose = () => {
  emits('close')
}
</script>

<template>
  <BaseModalWrapper
    title="Unable to proceed"
    @close="handleClose"
  >
    <div class="flex flex-col gap-16">
      <p class="text-euler-dark-900">
        This address is not eligible to use this interface.
      </p>
      <div class="bg-euler-dark-200 rounded-8 p-12 text-center font-mono text-14 break-all">
        {{ address }}
      </div>
    </div>
    <div class="flex justify-end mt-16">
      <UiButton
        size="xlarge"
        rounded
        variant="primary-stroke"
        @click="handleClose"
      >
        Close
      </UiButton>
    </div>
  </BaseModalWrapper>
</template>
