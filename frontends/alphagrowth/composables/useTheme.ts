const THEME_KEY = 'theme'

type Theme = 'light' | 'dark'

const theme = ref<Theme>('dark')
let initialized = false

export const useTheme = () => {
  if (!initialized && import.meta.client) {
    const stored = localStorage.getItem(THEME_KEY) as Theme | null
    theme.value = stored ?? 'dark'
    initialized = true
  }

  const isDark = computed(() => theme.value === 'dark')

  const toggleTheme = () => {
    theme.value = theme.value === 'dark' ? 'light' : 'dark'
    localStorage.setItem(THEME_KEY, theme.value)
  }

  return { theme: readonly(theme), isDark, toggleTheme }
}
