<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { useAppKit } from '@reown/appkit/vue'
import { flip, offset, shift, useFloating } from '@floating-ui/vue'

const props = defineProps<{ disabled?: boolean, loading?: boolean, disabledReason?: string }>()
const { isConnected } = useAccount()
const { open } = useAppKit()
const { chainId: _chainId } = useEulerAddresses()
const { chainId, switchChain } = useWagmi()

const reference = ref(null)
const floating = ref(null)
const isTooltipVisible = ref(false)

const { floatingStyles, update } = useFloating(reference, floating, {
  placement: 'top',
  middleware: [
    offset({ mainAxis: 8 }),
    flip({ padding: 8 }),
    shift({ padding: 8 }),
  ],
})

const showTooltip = () => {
  if (_disabled.value && props.disabledReason) {
    isTooltipVisible.value = true
    update()
  }
}
const hideTooltip = () => {
  isTooltipVisible.value = false
}

const needToSwitchChain = computed(() => {
  return isConnected.value && chainId.value !== _chainId.value
})
const _disabled = computed(() => {
  return props.disabled && !needToSwitchChain.value
})
const onClick = (e: Event) => {
  if (needToSwitchChain.value) {
    e.preventDefault()
    switchChain({ chainId: _chainId.value })
    return
  }
  if (!isConnected.value) {
    e.preventDefault()
    open()
    return
  }
}
</script>

<template>
  <div
    ref="reference"
    class="vault-form-submit"
    @mouseenter="showTooltip"
    @mouseleave="hideTooltip"
  >
    <UiButton
      v-bind="$attrs"
      size="large"
      type="submit"
      :variant="needToSwitchChain ? 'red' : 'primary'"
      :loading="loading"
      :disabled="_disabled"
      @click="onClick"
    >
      <template v-if="needToSwitchChain">
        Switch chain
      </template>
      <slot v-else-if="isConnected" />
      <template v-else>
        Connect wallet
      </template>
    </UiButton>
    <Transition name="tooltip">
      <div
        v-if="isTooltipVisible && _disabled && disabledReason"
        ref="floating"
        :style="floatingStyles"
        class="vault-form-submit__tooltip"
      >
        {{ disabledReason }}
      </div>
    </Transition>
  </div>
</template>

<style lang="scss">
.vault-form-submit {
  position: relative;
  width: 100%;

  .ui-button {
    width: 100%;
  }

  &__tooltip {
    position: absolute;
    z-index: 10;
    max-width: 300px;
    padding: 8px 12px;
    border-radius: 8px;
    background-color: var(--ui-footnote-floating-background-color);
    box-shadow: 0 8px 32px var(--ui-footnote-floating-box-shadow-color);
    font-size: 13px;
    line-height: 18px;
    font-weight: 400;
    text-align: center;
    pointer-events: none;
  }
}

.tooltip-enter-active,
.tooltip-leave-active {
  transition: opacity 0.15s ease;
}

.tooltip-enter-from,
.tooltip-leave-to {
  opacity: 0;
}
</style>
