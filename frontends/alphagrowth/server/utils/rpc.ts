export const resolveRpcUrl = (chainId: number): string | undefined => {
  const key = `RPC_URL_HTTP_${chainId}`
  return process.env[key]
}
