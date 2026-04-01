<script setup lang="ts">
const model = defineModel<unknown[] | string | boolean>()
const props = withDefaults(
  defineProps<{
    name?: string
    size?: 'small' | 'large'
    label?: string
    selfValue?: number | string | boolean
    tabindex?: string | number
    disabled?: boolean
    disabledIcon?: string
  }>(),
  {
    size: 'small',
  },
)

const isFocused = ref(false)
const localValue = ref(false)
const checkboxRef = ref()

const classes = computed(() => {
  return {
    'is-checked': localValue.value,
    'is-focused': isFocused.value,
    'is-disabled': props.disabled,
    [`ui-checkbox--${props.size}`]: props.size,
  }
})

const checkValue = () => {
  if (Array.isArray(model.value)) {
    localValue.value = model.value.includes(props.selfValue)
  }
  else {
    localValue.value = Boolean(model.value)
  }
}
const onFocus = () => {
  isFocused.value = true
}
const onBlur = () => {
  isFocused.value = false
}
const onInput = () => {
  if (model.value !== undefined) {
    if (Array.isArray(model.value)) {
      const arr = [...model.value]
      localValue.value = !localValue.value

      if (localValue.value) {
        arr.push(props.selfValue)
      }
      else {
        arr.splice(arr.indexOf(props.selfValue), 1)
      }

      model.value = arr
    }
    else {
      localValue.value = !localValue.value
      model.value = localValue.value
    }
  }
}

onMounted(() => {
  checkValue()
})
watch(model, () => {
  checkValue()
})
</script>

<template>
  <div :class="['ui-checkbox', classes]">
    <label
      ref="checkboxRef"
      class="ui-checkbox__wrap"
    >
      <span class="ui-checkbox__field">
        <input
          v-model="localValue"
          class="ui-checkbox__input"
          type="checkbox"
          :tabindex="tabindex"
          :name="name"
          :disabled="disabled"
          :aria-checked="localValue"
          :aria-disabled="disabled"
          @keydown.enter.stop.prevent="checkboxRef.click()"
          @focus="onFocus"
          @blur="onBlur"
          @input="onInput"
        >
        <span
          v-if="disabled && disabledIcon"
          class="ui-checkbox__disabled-icon-wrap"
        >
          <SvgIcon
            :name="disabledIcon"
            aria-hidden="true"
          />
        </span>
        <span
          v-else
          class="ui-checkbox__icon-wrap"
        >
          <SvgIcon
            name="check"
            aria-hidden="true"
          />
        </span>
      </span>
    </label>
  </div>
</template>

<style lang="scss">
.ui-checkbox {
  $block: &;

  &.is-disabled {
    #{$block}__field {
      cursor: not-allowed;
    }

    #{$block}__label {
      cursor: not-allowed;
    }

    #{$block}__disabled-icon-wrap {
      opacity: 1;
      color: var(--ui-checkbox-disabled-icon-color);
    }
  }

  &:hover {
    &:not(.is-disabled, .is-checked) {
      #{$block}__field {
        background-color: var(--ui-checkbox-hover-background-color);
      }
    }

    &.is-checked:not(.is-disabled) {
      #{$block}__field {
        background-color: var(--ui-checkbox-hover-checked-background-color);
      }
    }
  }

  &.is-checked:not(.is-disabled) {
    #{$block}__field {
      background-color: var(--ui-checkbox-checked-background-color);
      box-shadow: 0 0 0 2px var(--ui-checkbox-checked-box-shadow-color);
    }

    #{$block}__icon-wrap {
      opacity: 1;
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
    background-color: var(--ui-checkbox-background-color);
    color: var(--ui-checkbox-color);
    overflow: hidden;
    box-shadow: 0 0 0 1.5px var(--ui-checkbox-box-shadow-color), 0 1px 2px rgba(0, 0, 0, 0.06);
    transition: box-shadow 0.15s ease, background-color 0.15s ease;

    svg {
      width: 16px;
      height: 16px;
    }
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

  &__icon-wrap,
  &__disabled-icon-wrap {
    display: flex;
    opacity: 0;
    position: relative;
  }

  &__label {
    margin-left: 8px;
    color: var(--ui-checkbox-label-color);
    font-size: 16px;
    line-height: 24px;
    font-weight: 400;
    cursor: pointer;
  }

  &--large {
    width: 32px;
    height: 32px;

    &.is-focused {
      #{$block}__field {
        outline: 2px solid var(--ui-checkbox-focus-outline-color);
        outline-offset: 4px;
      }
    }

    #{$block}__field {
      min-width: 32px;
      min-height: 32px;
      border-radius: 7px;

      svg {
        width: 24px;
        height: 24px;
      }
    }

    #{$block}__input {
      border-radius: 7px;
    }
  }

  &--small {
    width: 20px;
    height: 20px;

    &.is-focused {
      #{$block}__field {
        outline: 2px solid var(--ui-checkbox-focus-outline-color);
        outline-offset: 3px;
      }
    }

    #{$block}__field {
      min-width: 20px;
      min-height: 20px;
      border-radius: 2px;

      svg {
        width: 16px;
        height: 16px;
      }
    }

    #{$block}__input {
      border-radius: 2px;
    }
  }
}
</style>
