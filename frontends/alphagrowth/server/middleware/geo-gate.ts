import { createError, getRequestURL } from 'h3'
import { SANCTIONED_COUNTRIES } from '~/entities/country-constants'

export default defineEventHandler((event) => {
  // Only gate API routes
  const url = getRequestURL(event)
  if (!url.pathname.startsWith('/api/')) {
    return
  }

  const country = (event.node.req.headers['x-country-code'] as string | undefined)?.toUpperCase()
  const isVpn = event.node.req.headers['x-is-vpn']
  const isProxyOrVpn = event.node.req.headers['x-is-proxy-or-vpn']

  // Log VPN/proxy usage for monitoring (do not block -- too many false positives)
  if (isVpn === 'true' || isProxyOrVpn === 'true') {
    console.warn('[geo-gate] VPN/proxy detected', {
      country: country || 'unknown',
      isVpn,
      isProxyOrVpn,
      path: url.pathname,
    })
  }

  // If country header is missing, allow the request (fail-open).
  // Cloudflare should always set this header; if it's absent something is wrong
  // but blocking legitimate users is worse than missing a check.
  if (!country) {
    return
  }

  // Block sanctioned countries
  if (SANCTIONED_COUNTRIES.includes(country)) {
    console.warn('[geo-gate] Blocked sanctioned country', {
      country,
      path: url.pathname,
    })
    throw createError({
      statusCode: 451,
      statusMessage: 'Unavailable For Legal Reasons',
    })
  }
})
