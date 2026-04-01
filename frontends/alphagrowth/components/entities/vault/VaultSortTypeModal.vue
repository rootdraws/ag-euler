<script setup lang="ts">
const emits = defineEmits(['close'])
const { options, selected, onSave } = defineProps<{
  options: string[]
  selected?: string
  title?: string
  onSave: (selected: string) => void
}>()

const selectedIdx = ref(options.findIndex(option => option === selected))

const handleClose = () => {
  emits('close')
}
</script>

<template>
  <BaseModalWrapper
    :title="title"
    @close="handleClose"
  >
    <div
      v-for="(option, idx) in options"
      :key="`options-${idx}`"
      class="flex items-center py-12 px-16 cursor-pointer rounded-16"
      :class="[selectedIdx === idx ? 'bg-euler-dark-600' : '']"
      @click="onSave(option)"
    >
      <div class="grow-1">
        <div class="text-euler-dark-1000 mb-2">
          {{ option }}
        </div>
      </div>
    </div>
  </BaseModalWrapper>
</template>
