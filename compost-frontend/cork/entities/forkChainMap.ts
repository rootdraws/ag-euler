/**
 * Maps Tenderly Virtual TestNet chain IDs to their parent (forked) chain IDs.
 * Used so labels, subgraphs, and Euler config resolve to the parent chain's
 * data while the wallet and RPC operate on the fork's own chain ID.
 */
const FORK_CHAIN_MAP: Record<number, number> = {
  9991: 1, // Tenderly mainnet fork → Ethereum Mainnet
}

export const getParentChainId = (chainId: number): number =>
  FORK_CHAIN_MAP[chainId] ?? chainId

export const isForkChain = (chainId: number): boolean =>
  chainId in FORK_CHAIN_MAP
