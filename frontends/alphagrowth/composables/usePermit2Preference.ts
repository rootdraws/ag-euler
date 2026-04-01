import { PERMIT2_PREFERENCE_STORAGE_KEY } from '~/entities/constants'

export const usePermit2Preference = () => {
  const permit2Enabled = useState<boolean>(PERMIT2_PREFERENCE_STORAGE_KEY, () => true)
  const persisted = useLocalStorage<boolean>(PERMIT2_PREFERENCE_STORAGE_KEY, true)

  const syncValue = (value: boolean) => {
    if (permit2Enabled.value !== value) {
      permit2Enabled.value = value
    }
    if (persisted.value !== value) {
      persisted.value = value
    }
  }

  watch(persisted, value => syncValue(value), { immediate: true })
  watch(permit2Enabled, value => syncValue(value))

  const setPermit2Enabled = (value: boolean) => {
    syncValue(value)
  }

  return {
    permit2Enabled,
    setPermit2Enabled,
  }
}
