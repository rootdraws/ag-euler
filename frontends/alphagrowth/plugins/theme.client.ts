import { themeHue } from '~/entities/custom'

const defaultHue = 211
const normalizeHue = (hue: number) => ((hue % 360) + 360) % 360

export default defineNuxtPlugin(() => {
  const normalizedHue = Number.isFinite(themeHue) ? normalizeHue(themeHue) : defaultHue

  if (typeof document !== 'undefined') {
    document.documentElement.style.setProperty('--brand-hue', `${normalizedHue}deg`)
  }
})
