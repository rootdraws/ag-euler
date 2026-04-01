<script setup lang="ts">
export type ToastVariant = 'info' | 'success' | 'warning' | 'error' | 'neutral'
export type ToastSize = 'normal' | 'compact'

const props = withDefaults(defineProps<{
  variant?: ToastVariant
  size?: ToastSize
  title: string
  description?: string
  actionText?: string
  persistent?: boolean
  duration?: number
}>(), {
  variant: 'info',
  size: 'normal',
  persistent: false,
  duration: 5000,
})

const emit = defineEmits(['close', 'action'])

const hasAction = computed(() => !!props.actionText)

const iconName = computed(() => {
  const iconMap: Record<ToastVariant, string> = {
    info: 'info-circle',
    success: 'check-circle',
    warning: 'info-circle',
    error: 'warning-circle',
    neutral: 'info-circle',
  }
  return iconMap[props.variant]
})

const classes = computed(() => {
  return {
    [`ui-toast--${props.variant}`]: props.variant,
    [`ui-toast--${props.size}`]: props.size,
    'ui-toast--with-action': hasAction.value,
  }
})

// Auto-dismiss functionality
if (!props.persistent && props.duration > 0) {
  setTimeout(() => {
    emit('close')
  }, props.duration)
}
</script>

<template>
  <Transition
    name="toast"
    appear
  >
    <div
      :class="classes"
      class="ui-toast"
    >
      <div class="ui-toast__card-container">
        <div class="ui-toast__icon-wrapper">
          <UiIcon
            :name="iconName"
            class="ui-toast__icon"
          />
        </div>
        <div class="ui-toast__content-wrapper">
          <div
            v-if="title"
            class="ui-toast__heading-container"
          >
            <div class="ui-toast__heading">
              {{ title }}
            </div>
          </div>
          <div
            v-if="description"
            class="ui-toast__paragraph-container"
          >
            <p class="ui-toast__paragraph">
              {{ description }}
            </p>
          </div>
        </div>
        <button
          v-if="!persistent"
          class="ui-toast__close-button"
          @click="$emit('close')"
        >
          <UiIcon
            name="times"
            class="ui-toast__close-icon"
          />
        </button>
      </div>
      <div
        v-if="hasAction"
        class="ui-toast__splitter"
      />
      <div
        v-if="hasAction"
        class="ui-toast__action-container"
      >
        <div class="ui-toast__spacer-32" />
        <div class="ui-toast__spacer-20" />
        <div class="ui-toast__action-wrapper">
          <button
            class="ui-toast__action-button"
            @click="$emit('action')"
          >
            <span class="ui-toast__action-text">{{ actionText }}</span>
            <UiIcon
              name="arrow-right"
              class="ui-toast__action-icon"
            />
          </button>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style lang="scss">
.ui-toast {
  display: flex;
  flex-direction: column;
  width: 100%;
  background: var(--ui-toast-background-color);
  border-radius: 8px;
  border: 1px solid;
  box-shadow: var(--ui-toast-box-shadow);
  overflow: hidden;

  &--info {
    border-color: var(--ui-toast-info-border-color);

    .ui-toast__card-container {
      background: var(--ui-toast-info-background-color);
    }

    .ui-toast__icon,
    .ui-toast__heading,
    .ui-toast__paragraph,
    .ui-toast__action-text,
    .ui-toast__action-icon,
    .ui-toast__close-icon {
      color: var(--ui-toast-info-text-color);
    }

    .ui-toast__splitter {
      background: var(--ui-toast-info-splitter-color);
    }

    .ui-toast__action-container {
      background: var(--ui-toast-info-action-background-color);
    }
  }

  &--success {
    border-color: var(--ui-toast-success-border-color);

    .ui-toast__card-container {
      background: var(--ui-toast-success-background-color);
    }

    .ui-toast__icon,
    .ui-toast__heading,
    .ui-toast__paragraph,
    .ui-toast__action-text,
    .ui-toast__action-icon,
    .ui-toast__close-icon {
      color: var(--ui-toast-success-text-color);
    }

    .ui-toast__splitter {
      background: var(--ui-toast-success-splitter-color);
    }

    .ui-toast__action-container {
      background: var(--ui-toast-success-action-background-color);
    }
  }

  &--warning {
    border-color: var(--ui-toast-warning-border-color);

    .ui-toast__card-container {
      background: var(--ui-toast-warning-background-color);
    }

    .ui-toast__icon {
      color: var(--ui-toast-warning-text-color);
    }

    .ui-toast__heading,
    .ui-toast__paragraph {
      color: var(--ui-toast-warning-text-color);
    }

    .ui-toast__action-text,
    .ui-toast__action-icon,
    .ui-toast__close-icon {
      color: var(--ui-toast-info-text-color);
    }

    .ui-toast__splitter {
      background: var(--ui-toast-warning-splitter-color);
    }

    .ui-toast__action-container {
      background: var(--ui-toast-warning-action-background-color);
    }
  }

  &--error {
    border-color: var(--ui-toast-error-border-color);

    .ui-toast__card-container {
      background: var(--ui-toast-error-background-color);
    }

    .ui-toast__icon,
    .ui-toast__heading,
    .ui-toast__paragraph {
      color: var(--ui-toast-error-text-color);
    }

    .ui-toast__action-text,
    .ui-toast__action-icon,
    .ui-toast__close-icon {
      color: var(--ui-toast-info-text-color);
    }

    .ui-toast__splitter {
      background: var(--ui-toast-error-splitter-color);
    }

    .ui-toast__action-container {
      background: var(--ui-toast-error-action-background-color);
    }
  }

  &--neutral {
    border-color: var(--ui-toast-neutral-border-color);

    .ui-toast__card-container {
      background: var(--ui-toast-neutral-background-color);
    }

    .ui-toast__icon,
    .ui-toast__heading,
    .ui-toast__paragraph,
    .ui-toast__action-text,
    .ui-toast__action-icon,
    .ui-toast__close-icon {
      color: var(--ui-toast-neutral-text-color);
    }

    .ui-toast__splitter {
      background: var(--ui-toast-neutral-splitter-color);
    }

    .ui-toast__action-container {
      background: var(--ui-toast-neutral-action-background-color);
    }
  }

  &--normal {
    .ui-toast__card-container {
      padding: 0 20px;
    }

    .ui-toast__icon-wrapper {
      padding: 22px 0;
    }

    .ui-toast__content-wrapper {
      padding: 20px 0;
    }

    .ui-toast__heading {
      font-size: 14px;
      line-height: 1.4285714285714286em;
      font-weight: 600;
    }

    .ui-toast__paragraph {
      font-size: 14px;
      line-height: 1.4285714285714286em;
      font-weight: 400;
    }

    .ui-toast__action-container {
      padding: 16px 24px 16px 0;
    }

    .ui-toast__action-text {
      font-size: 14px;
      line-height: 1.4285714285714286em;
      font-weight: 600;
    }

    .ui-toast__icon {
      width: 20px;
      height: 20px;
      font-size: 14px;
    }

    .ui-toast__action-icon {
      width: 20px;
      height: 20px;
      font-size: 14px;
    }
  }

  &--compact {
    .ui-toast__card-container {
      padding: 0 12px;
    }

    .ui-toast__icon-wrapper {
      padding: 12px 0;
    }

    .ui-toast__content-wrapper {
      padding: 12px 0;
      gap: 4px;
    }

    .ui-toast__heading {
      font-size: 12px;
      line-height: 1.3333333333333333em;
      font-weight: 600;
    }

    .ui-toast__paragraph {
      font-size: 12px;
      line-height: 1.3333333333333333em;
      font-weight: 400;
    }

    .ui-toast__action-container {
      padding: 12px 24px 12px 0;
    }

    .ui-toast__action-text {
      font-size: 12px;
      line-height: 1.3333333333333333em;
      font-weight: 600;
    }

    .ui-toast__icon {
      width: 20px;
      height: 20px;
      font-size: 14px;
    }

    .ui-toast__action-icon {
      width: 16px;
      height: 16px;
      font-size: 12px;
    }

    .ui-toast__spacer-32 {
      width: 24px;
    }
  }

  &__card-container {
    display: flex;
    align-items: stretch;
    gap: 12px;
    border-radius: 7px 7px 0 0;
    position: relative;

    .ui-toast--with-action & {
      border-radius: 7px 7px 0 0;
    }

    .ui-toast:not(.ui-toast--with-action) & {
      border-radius: 7px;
    }
  }

  &__icon-wrapper {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  &__icon {
    display: block;
  }

  &__content-wrapper {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }

  &__heading-container {
    display: flex;
    align-items: stretch;
    gap: 12px;
    padding: 2px 0;
  }

  &__heading {
    margin: 0;
    font-family: Inter, sans-serif;
    text-align: left;
    flex: 1;
  }

  &__paragraph-container {
    display: flex;
    align-items: stretch;
    padding: 2px 0;
  }

  &__paragraph {
    margin: 0;
    font-family: Inter, sans-serif;
    text-align: left;
    flex: 1;
  }

  &__close-button {
    position: absolute;
    top: 8px;
    right: 8px;
    background: none;
    border: none;
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0.7;
    transition: opacity 0.2s ease;

    &:hover {
      opacity: 1;
    }
  }

  &__close-icon {
    width: 14px;
    height: 14px;
    font-size: 12px;
  }

  &__splitter {
    height: 1px;
    width: 100%;
  }

  &__action-container {
    display: flex;
    align-items: center;
    border-radius: 0 0 7px 7px;
  }

  &__spacer-32 {
    width: 32px;
    flex-shrink: 0;
  }

  &__spacer-20 {
    width: 20px;
    flex-shrink: 0;
  }

  &__action-wrapper {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    flex: 1;
  }

  &__action-button {
    display: flex;
    align-items: center;
    gap: 8px;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
    font-family: Inter, sans-serif;
    transition: opacity 0.2s ease;

    &:hover {
      opacity: 0.8;
    }
  }

  &__action-text {
    margin: 0;
    text-align: left;
  }

  &__action-icon {
    display: block;
    flex-shrink: 0;
  }
}
</style>
