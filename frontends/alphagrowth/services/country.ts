import { CACHE_TTL_5MIN_MS } from '~/entities/tuning-constants'

let cached: { value: string | null, timestamp: number } | null = null

export async function detectCountry(): Promise<string | null> {
  if (cached !== null && Date.now() - cached.timestamp < CACHE_TTL_5MIN_MS) {
    return cached.value
  }

  try {
    const resp = await fetch(window.location.origin, { method: 'HEAD' })
    const header = resp.headers.get('x-country-code')
    cached = { value: header?.toUpperCase() || null, timestamp: Date.now() }
  }
  catch {
    cached = { value: null, timestamp: Date.now() }
  }

  return cached.value
}

export function resetCountryCache(): void {
  cached = null
}
