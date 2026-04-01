/**
 * Server-side structured logging utility.
 * Mirrors the client-side logWarn pattern from utils/errorHandling.ts.
 */
export function logWarn(context: string, ...args: unknown[]): void {
  console.warn(`[${context}]`, ...args)
}
