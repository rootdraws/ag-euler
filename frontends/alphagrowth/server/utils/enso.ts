export function resolveEnsoConfig() {
  const apiKey = process.env.ENSO_API_KEY || ''
  const apiUrl = process.env.ENSO_API_URL || 'https://api.enso.build'
  return { apiKey, apiUrl }
}
