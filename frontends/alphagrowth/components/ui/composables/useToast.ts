import type { Toast } from '~/components/ui/UiToastContainer.vue'
import type { ToastVariant, ToastSize } from '~/components/ui/UiToast.vue'

interface ToastOptions {
  variant?: ToastVariant
  size?: ToastSize
  description?: string
  actionText?: string
  persistent?: boolean
  duration?: number
  onAction?: () => void
}

interface ToastContainer {
  addToast: (toast: Omit<Toast, 'id'>) => string
  removeToast: (id: string) => void
  clearAllToasts: () => void
}

// Global toast container reference
let toastContainer: ToastContainer | null = null

export const useToast = () => {
  const show = (title: string, options: ToastOptions = {}): string => {
    if (!toastContainer) {
      console.warn('Toast container not found. Make sure UiToastContainer is mounted.')
      return ''
    }

    const toast: Omit<Toast, 'id'> = {
      title,
      variant: options.variant || 'info',
      size: options.size || 'normal',
      description: options.description,
      actionText: options.actionText,
      persistent: options.persistent || false,
      duration: options.duration || 5000,
      onAction: options.onAction,
    }

    return toastContainer.addToast(toast)
  }

  const success = (title: string, options: Omit<ToastOptions, 'variant'> = {}): string => {
    return show(title, { ...options, variant: 'success' })
  }

  const error = (title: string, options: Omit<ToastOptions, 'variant'> = {}): string => {
    return show(title, { ...options, variant: 'error' })
  }

  const warning = (title: string, options: Omit<ToastOptions, 'variant'> = {}): string => {
    return show(title, { ...options, variant: 'warning' })
  }

  const info = (title: string, options: Omit<ToastOptions, 'variant'> = {}): string => {
    return show(title, { ...options, variant: 'info' })
  }

  const neutral = (title: string, options: Omit<ToastOptions, 'variant'> = {}): string => {
    return show(title, { ...options, variant: 'neutral' })
  }

  const remove = (id: string): void => {
    if (toastContainer) {
      toastContainer.removeToast(id)
    }
  }

  const clear = (): void => {
    if (toastContainer) {
      toastContainer.clearAllToasts()
    }
  }

  return {
    show,
    success,
    error,
    warning,
    info,
    neutral,
    remove,
    clear,
  }
}

// Function to register the toast container
export const registerToastContainer = (container: ToastContainer) => {
  toastContainer = container
}

// Function to unregister the toast container
export const unregisterToastContainer = () => {
  toastContainer = null
}
