import { createError, getQuery, setResponseHeader, setResponseStatus } from 'h3'
import { createRateLimiter } from '~/server/utils/rate-limit'
import { resolveEnsoConfig } from '~/server/utils/enso'
import { isAbortError } from '~/utils/errorHandling'

const UPSTREAM_TIMEOUT_MS = 30_000

const ALLOWED_PARAMS = new Set([
  'chainId',
  'fromAddress',
  'tokenIn',
  'tokenOut',
  'amountIn',
  'receiver',
  'slippage',
  'routingStrategy',
])

const rateLimiter = createRateLimiter({
  max: 30,
  windowMs: 60_000,
  label: 'enso-route',
})

export default defineEventHandler(async (event) => {
  const { apiKey, apiUrl } = resolveEnsoConfig()
  if (!apiKey) {
    throw createError({ statusCode: 503, statusMessage: 'Enso API not configured' })
  }

  rateLimiter.consume(event)

  const rawQuery = getQuery(event)
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(rawQuery)) {
    if (ALLOWED_PARAMS.has(key) && typeof value === 'string' && value) {
      params.set(key, value)
    }
  }

  if (!params.has('chainId') || !params.has('tokenIn') || !params.has('tokenOut') || !params.has('amountIn')) {
    throw createError({ statusCode: 400, statusMessage: 'Missing required parameters: chainId, tokenIn, tokenOut, amountIn' })
  }

  const url = `${apiUrl}/api/v1/shortcuts/route?${params.toString()}`
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS)

  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      signal: controller.signal,
    })

    setResponseStatus(event, response.status)
    setResponseHeader(event, 'content-type', response.headers.get('content-type') || 'application/json')

    return await response.text()
  }
  catch (error: unknown) {
    if (isAbortError(error)) {
      throw createError({ statusCode: 504, statusMessage: 'Enso API timeout' })
    }
    throw createError({ statusCode: 502, statusMessage: 'Enso API error' })
  }
  finally {
    clearTimeout(timeout)
  }
})
