import {
  DEFAULT_SLIPPAGE,
  MAX_SLIPPAGE,
  MIN_SLIPPAGE,
  SLIPPAGE_STORAGE_KEY,
} from '~/entities/constants'

const normalizeSlippage = (value: number) => {
  if (!Number.isFinite(value)) {
    return DEFAULT_SLIPPAGE
  }
  return Math.min(MAX_SLIPPAGE, Math.max(MIN_SLIPPAGE, value))
}

export const useSlippage = () => {
  const slippage = useState<number>(SLIPPAGE_STORAGE_KEY, () => DEFAULT_SLIPPAGE)
  const persisted = useLocalStorage<number>(SLIPPAGE_STORAGE_KEY, DEFAULT_SLIPPAGE)

  const syncSlippage = (value: number) => {
    const normalized = normalizeSlippage(value)
    if (slippage.value !== normalized) {
      slippage.value = normalized
    }
    if (persisted.value !== normalized) {
      persisted.value = normalized
    }
  }

  watch(persisted, value => syncSlippage(value), { immediate: true })
  watch(slippage, value => syncSlippage(value))

  const setSlippage = (value: number) => {
    syncSlippage(value)
  }

  return {
    slippage,
    setSlippage,
    minSlippage: MIN_SLIPPAGE,
    maxSlippage: MAX_SLIPPAGE,
    defaultSlippage: DEFAULT_SLIPPAGE,
  }
}
