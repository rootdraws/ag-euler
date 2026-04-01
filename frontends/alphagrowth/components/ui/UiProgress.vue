<script setup lang="ts">
const props = withDefaults(defineProps<{
  size?: 'small' | 'large'
  rounded?: boolean
  max?: number
  color?: 'primary' | 'danger'
}>(), {
  size: 'large',
  rounded: false,
  max: 1,
  color: 'primary',
})
const model = defineModel<number>({ default: 0 })

const classes = computed(() => {
  return {
    [`ui-progress--${props.size}`]: props.size,
    'is-rounded': props.rounded,
    [`is-${props.color}`]: props.color,
  }
})
</script>

<template>
  <div
    :class="classes"
    class="ui-progress"
  >
    <div
      :style="{ width: `${Math.min(1, model/max) * 100}%` }"
      class="ui-progress__bar"
    />
  </div>
</template>

<style lang="scss">
.ui-progress {
  $block: &;

  overflow: hidden;
  border-radius: 100px;
  background-color: var(--ui-progress-background-color);

  &__bar {
    height: 100%;
    border-radius: 100px;
  }

  &--small {
    min-width: 30px;
    height: 6px;
    min-height: 6px;
  }

  &--large {
    min-width: 50px;
    height: 10px;
    min-height: 10px;
  }

  &.is-rounded {
    width: 100%;
  }

  &.is-primary {
    #{$block}__bar {
      background-color: var(--ui-progress-primary-bar-color);
    }
  }

  &.is-danger {
    #{$block}__bar {
      background-color: var(--ui-progress-danger-bar-color);
    }
  }
}
</style>
