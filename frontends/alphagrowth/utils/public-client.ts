import { createPublicClient, http, type PublicClient } from 'viem'

const clientCache = new Map<string, PublicClient>()

export const getPublicClient = (rpcUrl: string): PublicClient => {
  const cached = clientCache.get(rpcUrl)
  if (cached) {
    return cached
  }

  const client = createPublicClient({
    transport: http(rpcUrl, {
      batch: {
        batchSize: 100,
        wait: 50,
      },
    }),
  })

  clientCache.set(rpcUrl, client)
  return client
}
