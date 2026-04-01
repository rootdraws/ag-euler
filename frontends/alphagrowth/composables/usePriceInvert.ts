import { ref, computed, toValue, reactive, type MaybeRefOrGetter } from 'vue'

export function usePriceInvert(
  symbolA: MaybeRefOrGetter<string | undefined>,
  symbolB: MaybeRefOrGetter<string | undefined>,
) {
  const isInverted = ref(false)

  const toggle = () => {
    isInverted.value = !isInverted.value
  }

  const invertValue = (value: number | null | undefined): number | undefined => {
    if (value == null) return undefined
    if (!isInverted.value) return value
    if (value === 0 || !Number.isFinite(value)) return undefined
    return 1 / value
  }

  const displaySymbol = computed(() => {
    const a = toValue(symbolA) || ''
    const b = toValue(symbolB) || ''
    return isInverted.value ? `${b}/${a}` : `${a}/${b}`
  })

  return reactive({ isInverted, toggle, invertValue, displaySymbol })
}
