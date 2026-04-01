<script setup lang="ts">
const model = defineModel<boolean>()
const props = defineProps<{
  name?: string
  label?: string
  tabindex?: string | number
  disabled?: boolean
  disabledIcon?: string
}>()

const isFocused = ref(false)
const localValue = ref(false)
const switchRef = ref()

const classes = computed(() => {
  return {
    'is-checked': localValue.value,
    'is-focused': isFocused.value,
    'is-disabled': props.disabled,
  }
})

const checkValue = () => {
  localValue.value = Boolean(model.value)
}
const onFocus = () => {
  isFocused.value = true
}
const onBlur = () => {
  isFocused.value = false
}
const onInput = () => {
  localValue.value = !localValue.value
  model.value = localValue.value
}

onMounted(() => {
  checkValue()
})
watch(model, () => {
  checkValue()
})
</script>

<template>
  <div :class="['ui-switch', classes]">
    <label
      ref="switchRef"
      class="ui-switch__wrap"
    >
      <span class="ui-switch__field">
        <input
          v-model="localValue"
          class="ui-switch__input"
          type="checkbox"
          :tabindex="tabindex"
          :name="name"
          :disabled="disabled"
          :aria-checked="localValue"
          :aria-disabled="disabled"
          @keydown.enter.stop.prevent="switchRef.click()"
          @focus="onFocus"
          @blur="onBlur"
          @input="onInput"
        >
        <span class="ui-switch__indicator" />
      </span>
    </label>
  </div>
</template>

<style lang="scss">
.ui-switch {
  $block: &;
  width: 32px;
  height: 20px;

  &.is-disabled {
    #{$block}__field {
      cursor: not-allowed;
      background-color: var(--ui-switch-disabled-background-color);
      box-shadow: 0 0 0 1px var(--ui-switch-disabled-border-color);
    }

    #{$block}__indicator {
      background-color: var(--ui-switch-disabled-indicator-background-color);
    }
  }

  &.is-focused {
    #{$block}__field {
      outline: 2px solid var(--ui-switch-focus-outline-color);
      outline-offset: 4px;
    }
  }

  &.is-checked:not(.is-disabled) {
    #{$block}__field {
      background-color: var(--ui-switch-checked-background-color);
    }

    #{$block}__indicator {
      transform: translateX(calc(100% - 4px));
      background-color: var(--ui-switch-checked-indicator-background-color);
    }
  }

  &:hover {
    &:not(.is-disabled, .is-checked) {
      #{$block}__field {
        background-color: var(--ui-switch-hover-background-color);
      }

      #{$block}__indicator {
        background-color: var(--ui-switch-hover-indicator-background-color);
      }
    }

    &.is-checked:not(.is-disabled) {
      #{$block}__field {
        background-color: var(--ui-switch-hover-checked-background-color);
      }

      #{$block}__indicator {
        background-color: var(--ui-switch-hover-checked-indicator-background-color);
      }
    }
  }

  &__wrap {
    display: flex;
    align-items: center;
    outline: none;
    user-select: none;
  }

  &__field {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    min-width: 32px;
    min-height: 20px;
    border-radius: 100px;
    color: var(--ui-switch-color);
    background-color: var(--ui-switch-background-color);
    overflow: hidden;
    box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.1);
    transition: background-color 0.15s ease, box-shadow 0.15s ease;
  }

  &__input {
    position: absolute;
    top: 0;
    left: 0;
    display: block;
    width: 100%;
    height: 100%;
    appearance: none;
    cursor: pointer;
  }

  &__indicator {
    position: absolute;
    top: 2px;
    left: 2px;
    display: flex;
    width: 16px;
    height: 16px;
    background-color: var(--ui-switch-indicator-background-color);
    border-radius: 100px;
    transition: transform 0.2s ease-in-out, box-shadow 0.15s ease;
    transform: translateX(0);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
  }
}
</style>
