# Alpha Growth — Euler Lite Frontend Context

AI context file for the **shared** `euler-lite/` frontend. For project overview see `README.md`. For task tracking see `TODO.md`. For contract context see `<partner>-contracts/<partner>-claude.md`.

**Cork has its own frontend:** `euler-lite-cork/` (repo: `rootdraws/ag-euler-lite-cork`). See `euler-lite-cork/euler-lite-claude.md` for Cork-specific context.
**Balancer has its own frontend:** `euler-lite-balancer/` (repo: `rootdraws/ag-euler-lite-balancer`). See `euler-lite-balancer/euler-lite-balancer-claude.md` for Balancer-specific context.
**Origin has its own frontend:** `euler-lite-origin/` (repo: `rootdraws/ag-euler-lite-origin`). See `euler-lite-origin/origin-claude.md` for Origin-specific context.

Everything below applies to the shared frontend used by all other partners.

---

## Repo Overview

**Stack:** Nuxt 3 (Vue 3) + TypeScript + Tailwind CSS + SCSS + Viem + Wagmi + Reown (WalletConnect)

**SSR:** Disabled (`ssr: false` in nuxt.config.ts). Client-side SPA with a Nitro server for API proxying (RPC, wallet screening, Tenderly).

**Key directories:**

```
entities/custom.ts          ← THEME HUE + intrinsic APY sources
assets/styles/variables.scss ← Full color palette, shadows, radii
composables/useEnvConfig.ts  ← API URLs, app title/desc (driven by env vars)
composables/useDeployConfig.ts ← Feature flags, labels repo, social URLs (driven by env vars)
composables/useChainConfig.ts  ← Chains auto-detected from RPC_URL_HTTP_<chainId> env vars
composables/useEulerConfig.ts  ← Combines all config, builds labels URLs from repo setting
entities/menu.ts             ← Navigation items (Portfolio, Explore, Earn, Lend, Borrow)
plugins/00.wagmi.ts          ← Wallet connection setup (reads env config)
server/plugins/app-config.ts ← Injects env vars into HTML as window.__APP_CONFIG__
server/plugins/chain-config.ts ← Injects chain config into HTML as window.__CHAIN_CONFIG__
nuxt.config.ts               ← Meta tags, runtime config defaults, modules
public/entities/             ← Entity logos (alphagrowth.svg exists)
public/favicons/             ← Favicon files
assets/tokens/               ← Token icon overrides by symbol
```

---

## Architecture

### Data Flow

```
User → Pages (Vue) → Composables → Entities/Utils → External APIs
 ├── Euler Indexer API (token data, vault data)
 ├── Euler Swap API
 ├── Euler Price API
 ├── Subgraph (vault registry, positions)
 ├── RPC (via server proxy at /api/rpc/<chainId>)
 ├── Pyth (oracle prices)
 ├── GitHub Labels Repo (products, entities, earn-vaults)
 └── Merkl/Brevis (rewards)
```

### Vault Discovery & Filtering (Critical)

**Vault visibility is NOT controlled by the subgraph.** The subgraph returns all Euler vaults on a chain. Filtering happens at the **labels layer**.

1. `useEulerLabels.ts` fetches `products.json` from the configured labels repo:
   `https://raw.githubusercontent.com/<LABELS_REPO>/refs/heads/<BRANCH>/<chainId>/products.json`
2. `normalizeProducts()` extracts every vault address from all products → `verifiedVaultAddresses`
3. `fetchVaults()` in `entities/vault/fetcher.ts` (line 407) uses `verifiedVaultAddresses` as the vault list:
   ```typescript
   const verifiedVaults = vaultAddresses || verifiedVaultAddresses.value
   ```
4. Only vaults in this list get fetched via the Lens contract and displayed in the UI
5. `getVerifiedEvkVaults()` further filters to `v.verified === true` — set when the vault address exists in `verifiedVaultAddresses`

**If a vault address is NOT in your labels repo's `products.json`, it does not exist in the UI. Period.**

### Labels File Schema

Each labels repo has five files per chain plus a shared `logo/` directory:

| File | Keyed by | Frontend effect |
|---|---|---|
| `products.json` | product slug | Defines vault clusters. Every vault address in every product's `vaults` array becomes `verifiedVaultAddresses`. **If a vault isn't here, it's invisible.** |
| `vaults.json` | checksum address | Per-vault display name, description, and entity ID. Falls back to on-chain asset symbol if missing. |
| `entities.json` | entity slug | Org name, logo filename, website, addresses, socials. Entity logo badges appear on every vault card. |
| `points.json` | array | Incentive/points programs mapped to vault addresses. Rendered as tooltips. Use `[]` if none. |
| `opportunities.json` | checksum address | Maps vault addresses to Cozy Finance safety modules. Use `{}` if not applicable. |

`logo/` — SVG or PNG files referenced by `entities.json` and `points.json`. Fetched from raw GitHub URL.

Labels repos follow the naming convention `rootdraws/ag-euler-<partner>-labels`. Labels are always fetched from GitHub raw URLs — no local path support. `useEulerConfig.ts` line 27 hardcodes: `https://raw.githubusercontent.com/${labelsRepo}/refs/heads/${labelsRepoBranch}`.

### Key Composables

| Composable | Purpose |
|---|---|
| `useVaults` | Fetches vault list from subgraph, enriches with labels/prices |
| `useEulerOperations` | Transaction builders (deposit, borrow, repay, withdraw) |
| `useWagmi` / `useWallets` | Wallet connection state |
| `useEulerAccount` | User's Euler account positions |
| `useAccountPositions` | Computed position data per vault |
| `useVaultRegistry` | On-chain vault metadata via multicall |
| `useOracleAdapterPrices` | Oracle price resolution |
| `useSwapApi` | Swap routing for deposits/withdrawals |
| `useMarketGroups` | Groups related vaults for display |

### Pages

| Route | Page | Notes |
|---|---|---|
| `/` | Redirects to default page | Default order: explore → earn → lend → borrow → portfolio |
| `/earn` | EulerEarn vaults | Toggled by `ENABLE_EARN_PAGE` |
| `/lend` | Individual lending vaults | Toggled by `ENABLE_LEND_PAGE` |
| `/borrow` | Borrowing interface | Always enabled |
| `/explore` | Vault explorer | Toggled by `ENABLE_EXPLORE_PAGE` |
| `/portfolio` | User positions | Always enabled |
| `/position/[chainId]/[vault]` | Individual vault detail | Deposit/withdraw/borrow UI |

---

## Theme & Branding

AG is the brand. Partners and Euler are co-branded via entity logos.

`entities/custom.ts` has a legacy `themeHue` value. The current SCSS in `assets/styles/variables.scss` uses a fixed institutional palette (navy/gold):

- `--primary-*`, `--accent-*`, `--aquamarine-*` CSS variable families control the entire palette
- `--aquamarine-*` controls accent/CTA colors (currently gold/bronze)
- `--euler-dark-*` controls the surface/background hierarchy
- Dark theme overrides are in `[data-theme="dark"]` block

Partner differentiation comes from app title (env var), entity logos in the labels repo, and vault descriptions in `products.json`.

The `themeHue` in `custom.ts` is referenced by `plugins/theme.client.ts` but the SCSS palette is hardcoded — changing themeHue alone won't shift the look. Edit the SCSS variables.

### Meta Tags

`nuxt.config.ts` → `app.head` has hardcoded "Euler Lite" references. `title` and `description` are overridden at runtime by env vars, BUT `og:title`, `og:description`, `twitter:title`, `twitter:description` are hardcoded. Update per deployment or make them dynamic (pull from env vars).

---

## File Edit Quick Reference

| To change... | Edit this file |
|---|---|
| Brand colors (full palette) | `assets/styles/variables.scss` |
| Theme hue (legacy) | `entities/custom.ts` line 1 |
| App title & description | `.env` → `NUXT_PUBLIC_CONFIG_APP_TITLE`, `NUXT_PUBLIC_CONFIG_APP_DESCRIPTION` |
| Social links | `.env` → `NUXT_PUBLIC_CONFIG_X_URL`, `DISCORD_URL`, `TELEGRAM_URL`, `GITHUB_URL` |
| Docs link | `.env` → `NUXT_PUBLIC_CONFIG_DOCS_URL` |
| OG/Twitter meta tags | `nuxt.config.ts` → `app.head.meta` |
| Enabled chains | `.env` → add `RPC_URL_HTTP_<chainId>` + matching `NUXT_PUBLIC_SUBGRAPH_URI_<chainId>` |
| Navigation pages | `.env` → `NUXT_PUBLIC_CONFIG_ENABLE_EARN_PAGE`, `ENABLE_LEND_PAGE`, `ENABLE_EXPLORE_PAGE` |
| Entity logos | `public/entities/<name>.png` or `.svg` |
| Favicons | `public/favicons/` |
| Token icons | `assets/tokens/<symbol>.png` |
| Vault curation | Labels repo → `products.json`. Set `NUXT_PUBLIC_CONFIG_LABELS_REPO`. Empty products = zero vaults. |
| Tailwind extensions | `tailwind.config.js` |
| Wallet connect metadata | Reads from env config automatically |

---

## Multiply Positions (Leveraged Looping)

The multiply feature creates leveraged positions in a single atomic transaction. euler-lite already has a full implementation for standard token-to-token multiplies.

### Existing Multiply Architecture

| Component | File | Purpose |
|---|---|---|
| Form logic | `composables/borrow/useMultiplyForm.ts` | Multiplier slider, quote fetching, debt calculation |
| EVC batch builder | `composables/useEulerOperations/vault.ts` → `buildMultiplyPlan()` | Constructs the full EVC batch: deposit → enableController → enableCollateral → borrow → swap → verify → deposit |
| Position multiply page | `pages/position/[number]/multiply.vue` | UI for increasing leverage on existing positions |
| Leverage math | `utils/leverage.ts` | `getMaxMultiplier(borrowLTV)` — max = `1/(1-LTV)` minus 50bps safety |
| Swap quotes | `composables/useSwapQuotesParallel.ts` | Parallel quote fetching from swap providers |
| Swap API client | `composables/useSwapApi.ts` | HTTP client to Euler Swap API (`/swaps`, `/providers`) |
| Swap verification | `composables/useEulerOperations/swaps/verify.ts` | `verifyAmountMinAndSkim` / `verifyDebtMax` / `verifyAmountMinAndTransfer` |

The standard flow: borrow → send to Swapper → Swapper.multicall (executes DEX route) → SwapVerifier.verify → output deposited as collateral. All inside one EVC `batch()` call.

### Balancer BPT Multiply (Implemented)

**Balancer has its own frontend:** `euler-lite-balancer/` (repo: `rootdraws/ag-euler-lite-balancer`). See `euler-lite-balancer/euler-lite-balancer-claude.md` for the full implementation. Summary below.

For Balancer BPT vaults on Monad, the "swap" step is not a DEX trade — it's a Balancer V3 `addLiquidityUnbalanced` call. The architecture is **EVC Batch + custom routing** (Architecture B):

- **Pools 1, 4** (ERC4626-wrapped tokens): Custom `BalancerBptAdapter` handles wrapping + single-sided deposit. Invoked via Euler Swapper's `GenericHandler` within the EVC batch.
- **Pools 2, 3** (native tokens): Enso Finance `/route` API routes borrow asset → BPT. Called within the same EVC batch via `GenericHandler`.
- **Repay** (all pools): Enso `/route` handles BPT → borrow asset.

**Enso** (docs: https://docs.enso.build) is used only for its Route API — not the Bundle API. Enso does not support Euler V2 on Monad. Key endpoint: `GET /api/v1/shortcuts/route`.

Key implementation details:
- Swapper multicall uses `swap` + `sweep` (not `deposit`). `deposit()` consumes tokens, breaking `verifyAmountMinAndSkim`.
- Debt calculation includes a safety margin (`max(3× slippage, 1%)`) to prevent `EVC_ControllerViolation` from swap price impact.
- Adapter BPT preview uses `ERC4626.previewDeposit` + decimal scaling (not `queryAddLiquidityUnbalanced`, which reverts on Monad).

See `balancer-contracts/balancer-claude.md` for contract details and `euler-lite-balancer/euler-lite-balancer-claude.md` for frontend architecture.

---

## Official Euler Labels (app.euler.finance Listing)

To make vaults visible on the **official** Euler dApp (app.euler.finance), submit a PR to [euler-xyz/euler-labels](https://github.com/euler-xyz/euler-labels). Our fork is `rootdraws/euler-labels`.

**Template:** See `euler-labels-template.md` in the repo root for copy-paste JSON templates, logo requirements, and the full verify checklist.

**AlphaGrowth is the curator entity.** All AG-deployed vaults use `"entity": "alphagrowth"`. The `alphagrowth.svg` logo already exists in the upstream `logo/` directory. Partner branding goes on the product via the `"logo"` field in `products.json`.

**Process:**
1. Branch from `master` in the `euler-labels/` fork
2. Add partner logo to `logo/` (square SVG/PNG/JPG)
3. Add `alphagrowth` entity to `<chainId>/entities.json` (if not already present on that chain)
4. Add vault entries to `<chainId>/vaults.json` (name, description, entity)
5. Add product to `<chainId>/products.json` (all vaults must be in exactly one product)
6. Run `npm i && node verify.js` — must print `OK`
7. Push and `gh pr create --repo euler-xyz/euler-labels`

**Submitted PRs:**
- Origin stETH ARM / WETH (chain 1): [PR #521](https://github.com/euler-xyz/euler-labels/pull/521)

---

## Gotchas

1. **No RPC env = crash.** The wagmi plugin throws if zero `RPC_URL_HTTP_*` vars are set.
2. **APPKIT_PROJECT_ID required** for wallet connections. Get one free at reown.com.
3. **Subgraph URIs must match chain IDs.** If you set `RPC_URL_HTTP_42161` you need `NUXT_PUBLIC_SUBGRAPH_URI_42161`.
4. **Labels repo must have correct structure.** Each chain needs `<chainId>/products.json`, `entities.json`, etc.
5. **SCSS variables vs Tailwind:** The app uses BOTH. SCSS variables in `variables.scss` define the design tokens. Tailwind config in `tailwind.config.js` maps to those CSS variables. Change the SCSS source of truth.
6. **Entity branding** pulls from the labels repo's `logo/` directory. For custom logos, use a custom labels repo or add files to `public/entities/`.
7. **Empty labels repo = empty frontend.** `products.json` as `{}` = zero vaults shown. Vault discovery is driven entirely by the labels repo, not the subgraph.
8. **Cork is a separate frontend.** Do NOT add Cork-specific pages, composables, or logic to the shared `euler-lite/`. Cork's dual-collateral borrow flow lives in `euler-lite-cork/` (forked from `euler-lite/`). If another partner needs deeply custom UX, fork `euler-lite` into `euler-lite-<partner>` rather than polluting the shared codebase.
9. **MonadScan verification uses Etherscan V2 API, not Sourcify.** Sourcify (`--verifier sourcify`) only shows on MonadVision. For MonadScan, use `curl -X POST "https://api.etherscan.io/v2/api?chainid=143"` with Standard JSON Input generated by `forge verify-contract --show-standard-json-input`. The `MONADSCAN_API_KEY` works with the V2 endpoint. `forge verify-contract --chain 143 --verifier etherscan` fails because forge doesn't know chain 143 — use the curl approach. See `balancer-contracts/balancer-claude.md` lesson #23 for the full command template.
