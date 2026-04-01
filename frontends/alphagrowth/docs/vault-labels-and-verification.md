# Vault Labels & Verification

This document explains how euler-lite discovers, categorizes, verifies, and displays vault identity information using the Euler labels system.

## Overview

Not all vaults on-chain are equal. Some are curated by the Euler UI listing process, while others may be unknown or even malicious. The labels system provides a trust layer that maps on-chain vault addresses to off-chain metadata (names, logos, descriptions, deprecation status) and determines whether a vault is **verified** or **unknown**.

## Label Data Sources

Labels are fetched from the [euler-labels](https://github.com/euler-xyz/euler-labels) GitHub repository. Each supported chain has a directory containing JSON files:

| File | Contents |
|------|----------|
| `products.json` | Vault-to-product mapping (names, entities, deprecation) |
| `entities.json` | Organization/entity info (logos, social links, addresses) |
| `points.json` | Points/rewards configuration (campaigns, turtle club) |

**Caching**: Labels are cached for 5 minutes (`CACHE_TTL = 5 * 60 * 1000`). Subsequent calls within the TTL return cached data without network requests.

**Address normalization**: All addresses from labels are checksummed via `ethers.getAddress()` before storage, ensuring consistent lookups regardless of input casing.

## Label Types

### `EulerLabelProduct`

Represents a vault product (e.g. "USDC Vault" or "wstETH/WETH Borrow"):

```typescript
interface EulerLabelProduct {
  name: string                    // Display name
  description: string             // Product description
  entity: string                  // Owning entity name
  vaults: string[]                // Active vault addresses
  deprecatedVaults?: string[]     // Phased-out vault addresses
  deprecationReason?: string      // Why deprecated
  isGovernanceLimited?: boolean   // Governance-limited flag
}
```

### `EulerLabelEntity`

Represents an organization that governs one or more vaults:

```typescript
interface EulerLabelEntity {
  name: string
  logo?: string                   // Filename in euler-labels repo
  description?: string
  addresses?: string[]            // Governance/admin addresses
  website?: string
  twitter?: string
  github?: string
  telegram?: string
  discord?: string
}
```

### `EulerLabelPoint`

Represents a points/rewards campaign:

```typescript
interface EulerLabelPoint {
  name: string
  logo?: string
  collateralVaults?: string[]     // Vaults eligible for points
  isTurtleClub?: boolean          // Whether this is a Turtle Club campaign
  rewards?: EulerLabelPointReward[]
}
```

## Vault Verification

### Building the Verified Set

The `useEulerLabels` composable builds a set of verified vault addresses from the labels data. A vault is considered verified if it appears in any product's `vaults` array (including deprecated vaults).

### How `vault.verified` Is Set

Verification is determined during vault loading in `useVaultRegistry`:

| Vault Source | Verification Method |
|-------------|---------------------|
| **EVK vaults** | Address appears in `verifiedVaultAddresses` from labels |
| **Earn vaults** | Default repo: loaded from `eulerEarnGovernedPerspective` on-chain. Alternative repos: verified if in `earnVaults` from labels (`earn-vaults.json`) |
| **Escrow vaults** | Loaded from `escrowedCollateralPerspective` on-chain (always verified) |
| **Securitize vaults** | Address appears in `verifiedVaultAddresses` from labels |
| **Unknown vaults** | Resolved via subgraph; verified only if in labels |

### On-Chain Perspectives

Two on-chain perspective contracts provide additional verification:

- **`escrowedCollateralPerspective`**: Lists all verified escrow collateral vaults. Vaults from this perspective are marked `verified: true` and `vaultCategory: 'escrow'`.
- **`eulerEarnGovernedPerspective`**: Lists all governed EulerEarn vaults. Vaults from this perspective are always verified.

## Vault Categories and Types

### Categories

Every EVK vault belongs to one of two categories:

| Category | Description |
|----------|-------------|
| `'standard'` | Regular lending/borrowing vaults |
| `'escrow'` | Escrow collateral vaults (from escrow perspective) |

### Types

The vault type determines how the vault is fetched and displayed:

| Type | Description |
|------|-------------|
| `'evk'` | Standard Euler Vault Kit vault (lending + borrowing) |
| `'earn'` | EulerEarn aggregator vault (yield optimization) |
| `'securitize'` | Securitize vault (ERC-4626 without borrowing) |

Type is detected in `useVaultRegistry` based on the vault's factory address queried from the subgraph.

## Unknown Vault Resolution

When a vault address is encountered that isn't in the registry (e.g. from a user's on-chain positions), it goes through resolution:

```
Unknown vault address
       |
       v
  Query subgraph for factory address
       |
       v
  Match factory → type assignment
  (securitize factory → 'securitize',
   earn factory → 'earn',
   otherwise → 'evk')
       |
       v
  Fetch full vault data via appropriate lens
       |
       v
  Check if address is in verified set
       |
       v
  Register in vault registry
```

The `getOrFetch()` method on the vault registry handles this flow. It first checks the in-memory registry, then falls back to on-chain resolution.

## Deprecated Vaults

Deprecation is tracked in the labels data:

- `EulerLabelProduct.deprecatedVaults` lists addresses of phased-out vaults
- `EulerLabelProduct.deprecationReason` explains why
- `isVaultDeprecated(address)` checks if a vault address appears in any product's deprecated list
- Deprecated vaults are hidden from discovery tables (lend, borrow, earn) but remain visible in the user's portfolio

## Entity Identification

Entities are matched to vaults through two mechanisms:

1. **Labels**: `EulerLabelProduct.entity` names the owning entity, which is looked up in `entities.json`
2. **Governor admin**: `vault.governorAdmin` is compared against `EulerLabelEntity.addresses[]` to identify the governing entity

The `getEntitiesByVault(address)` function resolves entities for a given vault.

## UI Display

### VaultDisplayName Component

`components/entities/vault/VaultDisplayName.vue` renders the vault name with verification state:

- **Verified vaults**: Display the vault name normally
- **Unverified vaults**: Show "Unknown" with a red warning icon

### VaultUnverifiedDisclaimerModal

`components/entities/vault/VaultUnverifiedDisclaimerModal.vue` is a security warning modal shown when users attempt to interact with an unverified vault. It warns about potential phishing risks and requires explicit confirmation.

### VaultLabelsAndAssets Component

`components/entities/vault/VaultLabelsAndAssets.vue` displays the vault's entity logo, asset icon, points badges, and type chip in a unified row.

## Files

| File | Purpose |
|------|---------|
| `composables/useEulerLabels.ts` | Label fetching, caching, and reactive composables |
| `composables/useVaultRegistry.ts` | Vault registry with type detection and unknown resolution |
| `entities/vault/` | Vault types, fetching, and data processing (split into `types.ts`, `fetcher.ts`, `factory.ts`, etc.) |
| `entities/euler/labels.ts` | Label type definitions and helpers |
| `components/entities/vault/VaultDisplayName.vue` | Name display with verification state |
| `components/entities/vault/VaultUnverifiedDisclaimerModal.vue` | Security warning for unverified vaults |
| `components/entities/vault/VaultLabelsAndAssets.vue` | Combined label/asset display |
| `components/entities/vault/VaultTypeChip.vue` | Vault type badge (EVK, Earn, Securitize) |
