<script setup lang="ts">
const emits = defineEmits(['close'])
const { onCancel } = defineProps<{
  onCancel: () => void
}>()

const handleCancel = () => {
  onCancel()
  emits('close')
}
</script>

<template>
  <BaseModalWrapper
    title="Important!"
    warning
    @close="handleCancel"
  >
    <div class="flex flex-col gap-12 text-euler-dark-900 mb-24">
      <h4 class="text-white text-h4">
        Are you sure you want to interact with the unverified vault?
      </h4>
      <p class="pb-8">
        Proceeding with this unknown and unverified vault may pose security risks. Such vaults could potentially be used for phishing attempts.
      </p>
      <p>
        Please ensure you trust the source before continuing.
      </p>
    </div>
    <div class="flex gap-8">
      <UiButton
        size="large"
        rounded
        variant="primary-stroke"
        @click="emits('close')"
      >
        Yes
      </UiButton>
      <UiButton
        size="large"
        rounded
        @click="handleCancel"
      >
        Cancel
      </UiButton>
    </div>
  </BaseModalWrapper>
</template>
