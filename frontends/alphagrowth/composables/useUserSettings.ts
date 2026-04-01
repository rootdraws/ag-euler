type UserSettings = {
  enableIntrinsicApy: boolean
  enableRewardsApy: boolean
}

const SETTINGS_KEY = 'user-settings'
const defaults: UserSettings = { enableIntrinsicApy: true, enableRewardsApy: true }

const settings = useLocalStorage<UserSettings>(SETTINGS_KEY, defaults)

export const useUserSettings = () => ({
  settings: readonly(settings),
  updateSetting: <K extends keyof UserSettings>(key: K, value: UserSettings[K]) => {
    settings.value = { ...settings.value, [key]: value }
  },
})
