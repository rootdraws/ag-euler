type LogSeverity = 'warn' | 'error' | 'silent'

/**
 * Detects AbortError (DOMException) and CanceledError (Axios).
 */
export function isAbortError(error: unknown): boolean {
  if (error instanceof DOMException && error.name === 'AbortError') return true
  if (typeof error === 'object' && error !== null && 'name' in error) {
    const name = (error as { name?: string }).name
    return name === 'AbortError' || name === 'CanceledError'
  }
  return false
}

/**
 * Structured warning with [context] tag.
 *
 * @param context - Tag for the log message, e.g. 'merkl/loadTokens'
 * @param error - The error or message to log
 * @param options.severity - 'warn' (default) | 'error' | 'silent'
 * @param options.data - Additional data to log after the error
 */
export function logWarn(
  context: string,
  error: unknown,
  options?: { severity?: LogSeverity, data?: unknown },
): void {
  const severity = options?.severity ?? 'warn'
  if (severity === 'silent') return

  const log = severity === 'error' ? console.error : console.warn
  if (options?.data !== undefined) {
    log(`[${context}]`, error, options.data)
  }
  else {
    log(`[${context}]`, error)
  }
}

/**
 * Runs an async function and returns a fallback value on error.
 *
 * @param fn - Async function to execute
 * @param fallback - Value to return if fn throws
 * @param logContext - If provided, logs the error via logWarn with this context
 */
export async function catchToFallback<T>(
  fn: () => Promise<T>,
  fallback: T,
  logContext?: string,
): Promise<T> {
  try {
    return await fn()
  }
  catch (err) {
    if (logContext) {
      logWarn(logContext, err)
    }
    return fallback
  }
}
