# Intrinsic APY

Intrinsic APY represents yield that is native to the underlying asset itself, independent of the Euler lending market. For example, wstETH earns staking yield from Lido, sDAI earns the DAI Savings Rate, and Pendle PT tokens earn implied yield from the fixed-rate market.

Euler Lite adds this intrinsic yield on top of the vault's lending/borrowing APY so users see the total effective return.

## Architecture

The system uses a **provider abstraction** to support multiple APY data sources. Each provider implements a common interface, fetches APY data from its source, and returns results keyed by token address.

```
┌─────────────────────────────┐
│     useIntrinsicApy()       │  Composable (orchestrator)
│  - TTL cache (5 min)        │
│  - address-based lookup     │
│  - chain-switch invalidation│
└──────────┬──────────────────┘
           │ Promise.allSettled
    ┌──────┴──────┐
    ▼             ▼
┌─────────┐  ┌─────────┐
│DefiLlama│  │ Pendle  │     Providers
│Provider │  │Provider │
└────┬────┘  └────┬────┘
     │            │
     ▼            ▼
  yields API   Pendle V2 API
```

### Types (`entities/intrinsic-apy.ts`)

```typescript
interface IntrinsicApyInfo {
  readonly apy: number        // percentage (e.g. 3.5 = 3.5%)
  readonly provider: string   // human-readable (e.g. "Lido via DefiLlama", "Pendle")
  readonly source?: string    // URL to verify the APY
}

interface IntrinsicApyProvider {
  readonly name: string
  fetch(chainId: number): Promise<IntrinsicApyResult[]>
}

interface IntrinsicApyResult {
  readonly address: string    // lowercase token address
  readonly info: IntrinsicApyInfo
}
```

### Config (`entities/custom.ts`)

All intrinsic APY sources are configured as a static array with discriminated union types:

```typescript
type IntrinsicApySourceConfig =
  | { provider: 'defillama'; address: string; chainId: number; poolId: string; useSpotApy?: boolean }
  | { provider: 'pendle'; address: string; chainId: number; pendleMarket: string; crossChainSourceChainId?: number }
```

Each entry maps a token address on a specific chain to its data source. DefiLlama entries reference a pool UUID; Pendle entries reference a Pendle market address.

## Providers

### DefiLlama (`services/intrinsicApy/defillamaProvider.ts`)

Covers yield-bearing tokens like LSTs, stablecoins with native yield, and LP tokens.

- **API**: Single bulk fetch from `https://yields.llama.fi/pools`
- **Matching**: Exact `poolId` lookup via `Map` (no symbol/project fuzzy matching)
- **APY value**: Uses `apyMean30d` (30-day rolling average) by default. Set `useSpotApy: true` in the config entry to use the spot `apy` instead.
- **Source URL**: `https://defillama.com/yields/pool/{poolId}`
- **Provider name**: Derived from the pool's project field (e.g. "Lido via DefiLlama", "Rocket Pool via DefiLlama")

### Pendle (`services/intrinsicApy/pendleProvider.ts`)

Covers Pendle Principal Tokens (PTs) which earn implied yield from Pendle's fixed-rate market.

- **API**: Per-market fetch from `https://api-v2.pendle.finance/core/v2/{chainId}/markets/{marketAddress}/data`
- **Batching**: Processes up to 10 concurrent requests
- **APY value**: `impliedApy` field (ratio, multiplied by 100 to get percentage)
- **Maturity detection**: If the market's `timestamp` is older than 2 hours, the PT has matured and APY is set to 0
- **Cross-chain**: Use `crossChainSourceChainId` for PTs whose Pendle market lives on a different chain than the token
- **Source URL**: `https://app.pendle.finance/trade/markets`

## Composable (`composables/useIntrinsicApy.ts`)

### Caching

- **TTL**: 5 minutes. After expiry, the next access triggers a background re-fetch.
- **Chain switch**: Immediately clears cached data and re-fetches for the new chain.
- **Toggle**: When the user disables intrinsic APY in settings, cached data is cleared. Re-enabling triggers a fresh fetch.

### Lookup

All lookups are by **lowercase token address**. The composable normalizes addresses internally.

```typescript
const { getIntrinsicApy, getIntrinsicApyInfo, withIntrinsicSupplyApy, withIntrinsicBorrowApy } = useIntrinsicApy()

// Raw APY value
const apy = getIntrinsicApy(vault.asset.address)  // e.g. 3.2

// Full info with provider name and source URL (for modals)
const info = getIntrinsicApyInfo(vault.asset.address)
// { apy: 3.2, provider: "Lido via DefiLlama", source: "https://defillama.com/yields/pool/..." }

// Combined with lending APY (compounding formula)
const totalSupply = withIntrinsicSupplyApy(lendingApy, vault.asset.address)
const totalBorrow = withIntrinsicBorrowApy(borrowApy, vault.asset.address)
```

### Compounding formula

When combining intrinsic APY with a vault's base APY:

```
effectiveAPY = baseAPY + (1 + baseAPY / 100) * intrinsicAPY
```

This accounts for the fact that the intrinsic yield compounds on top of the lending yield (the vault holds a yield-bearing asset, so as its value grows, the lent amount grows too).

## Source Attribution

The supply and borrow APY modals show where the intrinsic APY comes from:

- **Provider name** displayed in parentheses: "Intrinsic APY (Lido via DefiLlama)"
- **Source link** displayed below the description, linking to the external data source for verification

This is powered by the `intrinsicApyInfo` prop on `VaultSupplyApyModal` and `VaultBorrowApyModal`. Callers pass it alongside the numeric APY value:

```typescript
modal.open(VaultSupplyApyModal, {
  props: {
    lendingAPY: ...,
    intrinsicAPY: getIntrinsicApy(vault.asset.address),
    intrinsicApyInfo: getIntrinsicApyInfo(vault.asset.address),
  },
})
```

## Adding a New Provider

1. Create `services/intrinsicApy/myProvider.ts` implementing `IntrinsicApyProvider`
2. Add a new variant to `IntrinsicApySourceConfig` in `entities/custom.ts`
3. Add config entries to the `intrinsicApySources` array
4. Register the provider in `composables/useIntrinsicApy.ts`:
   ```typescript
   const providers: IntrinsicApyProvider[] = [
     createDefiLlamaProvider(intrinsicApySources),
     createPendleProvider(intrinsicApySources),
     createMyProvider(intrinsicApySources),  // new
   ]
   ```
5. Add the API domain to the CSP `connect-src` in `nuxt.config.ts`

## Adding New Tokens

### DefiLlama

1. Find the pool on [DefiLlama Yields](https://defillama.com/yields) and copy its pool UUID from the URL
2. Add an entry to `intrinsicApySources`:
   ```typescript
   { provider: 'defillama', chainId: 1, address: '0x...token', poolId: 'uuid-from-defillama' }
   ```

### Pendle PT

1. Find the PT token address and its Pendle market address (from the Euler API token metadata or Pendle's app)
2. Add an entry:
   ```typescript
   { provider: 'pendle', address: '0x...pt-token', chainId: 1, pendleMarket: '0x...market' }
   ```
3. Pendle PTs mature — periodically remove expired entries and add new ones

## Files

| File | Purpose |
|------|---------|
| `entities/intrinsic-apy.ts` | Type definitions (`IntrinsicApyInfo`, `IntrinsicApyProvider`, `IntrinsicApyResult`) |
| `entities/custom.ts` | Config array mapping tokens to providers (`intrinsicApySources`) |
| `services/intrinsicApy/defillamaProvider.ts` | DefiLlama provider (bulk pool fetch, poolId matching) |
| `services/intrinsicApy/pendleProvider.ts` | Pendle provider (per-market API, batch concurrency, maturity detection) |
| `composables/useIntrinsicApy.ts` | Orchestrator composable (TTL cache, multi-provider, address lookup) |
| `components/entities/vault/VaultSupplyApyModal.vue` | Supply APY modal with source attribution |
| `components/entities/vault/VaultBorrowApyModal.vue` | Borrow APY modal with source attribution |
