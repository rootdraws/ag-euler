<script setup lang="ts">
import type { ToastVariant, ToastSize } from './UiToast.vue'
import { registerToastContainer, unregisterToastContainer } from '~/components/ui/composables/useToast'

export interface Toast {
  id: string
  variant?: ToastVariant
  size?: ToastSize
  title: string
  description?: string
  actionText?: string
  persistent?: boolean
  duration?: number
  onAction?: () => void
}

const toasts = ref<Toast[]>([])

const addToast = (toast: Omit<Toast, 'id'>) => {
  const id = Date.now().toString()
  const newToast: Toast = {
    id,
    variant: 'info',
    size: 'normal',
    persistent: false,
    duration: 5000,
    ...toast,
  }
  toasts.value.push(newToast)
  return id
}

const removeToast = (id: string) => {
  const index = toasts.value.findIndex(toast => toast.id === id)
  if (index > -1) {
    toasts.value.splice(index, 1)
  }
}

const clearAllToasts = () => {
  toasts.value = []
}

const handleToastAction = (toast: Toast) => {
  if (toast.onAction) {
    toast.onAction()
  }
  if (!toast.persistent) {
    removeToast(toast.id)
  }
}

// Expose methods for external use
defineExpose({
  addToast,
  removeToast,
  clearAllToasts,
})

// Register this container instance
onMounted(() => {
  registerToastContainer({
    addToast,
    removeToast,
    clearAllToasts,
  })
})

// Unregister on unmount
onUnmounted(() => {
  unregisterToastContainer()
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="toasts.length > 0"
      class="ui-toast-container"
    >
      <TransitionGroup
        name="toast-list"
        tag="div"
        class="ui-toast-container__list"
      >
        <UiToast
          v-for="toast in toasts"
          :key="toast.id"
          :variant="toast.variant"
          :size="toast.size"
          :title="toast.title"
          :description="toast.description"
          :action-text="toast.actionText"
          :persistent="toast.persistent"
          :duration="toast.duration"
          class="ui-toast-container__toast"
          @close="removeToast(toast.id)"
          @action="handleToastAction(toast)"
        />
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<style lang="scss">
.ui-toast-container {
  position: fixed;
  top: 20px;
  right: 20px;
  z-index: 9999;
  pointer-events: none;

  @media (max-width: 768px) {
    top: 10px;
    right: 10px;
    left: 10px;

    &__list {
      max-width: none;
    }
  }

  @media (max-width: 480px) {
    top: 10px;
    left: 10px;
    right: 10px;
  }

  &__list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    max-width: 400px;
  }

  &__toast {
    pointer-events: auto;
    max-width: 320px;
  }
}
</style>
