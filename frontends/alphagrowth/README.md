# Euler Lite — Balancer

Euler Finance lending/borrowing interface customized for Balancer V3 BPT vault markets on Monad.

**Live at:** `balancer.alphagrowth.fun`
**Repo:** `rootdraws/ag-euler-lite-balancer`
**Forked from:** `euler-lite` (shared AG frontend)

## What this adds

On top of the standard Euler Lite features (lending, borrowing, portfolio, rewards), this frontend adds:

- **Zap BPT** — convert AUSD or WMON into Balancer Pool Tokens from a dedicated page (single transaction)
- **Multiply/Leverage** for BPT collateral vaults — borrow against BPT to loop into more BPT, using Enso Finance routing or a custom BalancerBptAdapter (via the standard borrow page)
- **Enso Finance integration** — server-side proxy for Enso's routing API, used for zap, multiply, and repay operations

## Markets

Four Balancer V3 pools on Monad (chain 143):

| Pool | Collateral | Borrow Asset | Multiply Route |
|------|-----------|-------------|----------------|
| Pool 1 | wnAUSD/wnUSDC/wnUSDT0 (Stableswap) | AUSD | Adapter |
| Pool 2 | sMON/wnWMON (Kintsu) | WMON | Enso |
| Pool 3 | shMON/wnWMON (Fastlane) | WMON | Enso |
| Pool 4 | wnLOAZND/AZND/wnAUSD | AUSD | Adapter |

Contract addresses and adapter details: see `../balancer-contracts/balancer-claude.md`.

## Prerequisites

- **Node.js** 18+ (recommended: 20.12.2)
- **npm** package manager
- **Git**
- A **Reown Project ID** (formerly WalletConnect) — get one at [reown.com](https://reown.com/)
- An **Enso Finance API key** — for multiply/repay/loop-zap routing

## Quick Start

### 1. Clone and Install

```bash
git clone https://github.com/rootdraws/ag-euler-lite-balancer.git
cd ag-euler-lite-balancer
npm install
```

### 2. Environment Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

#### Required Variables

| Variable | Description |
|----------|-------------|
| `APPKIT_PROJECT_ID` | Reown (WalletConnect) project ID |
| `NUXT_PUBLIC_APP_URL` | Your app's public URL |
| `RPC_URL_HTTP_143` | Monad RPC endpoint |
| `NUXT_PUBLIC_SUBGRAPH_URI_143` | Monad subgraph URI |
| `ENSO_API_KEY` | Enso Finance API key (server-side only) |

#### Balancer-Specific Variables

| Variable | Description |
|----------|-------------|
| `ENSO_API_KEY` | Enso Finance API key (never exposed to client) |
| `ENSO_API_URL` | Enso API base URL (default: `https://api.enso.build`) |
| `NUXT_PUBLIC_CONFIG_ENABLE_ENSO_MULTIPLY` | `true` to enable multiply with Enso/adapter routing |
| `NUXT_PUBLIC_CONFIG_ENABLE_LOOP_ZAP_PAGE` | `true` to show Zap BPT in navigation |
| `NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG` | JSON map of collateral vault → adapter config (see `.env.example`) |

#### API URLs

| Variable | Default | Description |
|----------|---------|-------------|
| `EULER_API_URL` | — | Euler indexer API (token data, logos) |
| `SWAP_API_URL` | — | Euler swap API |
| `PRICE_API_URL` | — | Euler price API |
| `PYTH_HERMES_URL` | `https://hermes.pyth.network` | Pyth oracle endpoint |

#### Branding & Feature Flags

These use Nuxt's `runtimeConfig` and are set via `NUXT_PUBLIC_CONFIG_*` env vars:

| Variable | Default | Description |
|----------|---------|-------------|
| `NUXT_PUBLIC_CONFIG_APP_TITLE` | `Euler Lite` | App title (SEO, meta tags) |
| `NUXT_PUBLIC_CONFIG_APP_DESCRIPTION` | `Lightweight interface for Euler Finance.` | App description |
| `NUXT_PUBLIC_CONFIG_LABELS_REPO` | `euler-xyz/euler-labels` | GitHub labels repo |
| `NUXT_PUBLIC_CONFIG_LABELS_REPO_BRANCH` | `master` | Branch to fetch labels from |
| `NUXT_PUBLIC_CONFIG_DOCS_URL` | — | Documentation link |
| `NUXT_PUBLIC_CONFIG_X_URL` | — | X (Twitter) link |
| `NUXT_PUBLIC_CONFIG_DISCORD_URL` | — | Discord link |
| `NUXT_PUBLIC_CONFIG_TELEGRAM_URL` | — | Telegram link |
| `NUXT_PUBLIC_CONFIG_GITHUB_URL` | — | GitHub link |
| `NUXT_PUBLIC_CONFIG_ENABLE_EARN_PAGE` | `true` | Show Earn page |
| `NUXT_PUBLIC_CONFIG_ENABLE_LEND_PAGE` | `true` | Show Lend page |
| `NUXT_PUBLIC_CONFIG_ENABLE_EXPLORE_PAGE` | `true` | Show Explore page |

#### Chain Configuration

Chains are configured dynamically at runtime. Each chain requires:

```bash
RPC_URL_HTTP_143=https://your-monad-rpc.com
NUXT_PUBLIC_SUBGRAPH_URI_143=https://api.goldsky.com/.../euler-simple-monad/latest/gn
```

The app scans for `RPC_URL_HTTP_<chainId>` env vars at server startup and automatically enables those chains.

### 3. Development

```bash
npm run dev
```

The app will be available at `http://localhost:3000`.

### 4. Build for Production

```bash
npm run build
npm run preview   # preview locally
```

## Deployment (Vercel)

The app is deployed on Vercel (project `ag-euler-balancer`). Environment variables are set in the Vercel dashboard. Key settings:

- **Framework:** Nuxt.js
- **Build command:** `npm run build`
- **All `ENSO_*` vars** are set as non-public (server-side only)
- **`NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG`** is the full JSON string with adapter addresses

## Project Structure (Balancer additions)

```
composables/
  useEnsoRoute.ts            # Enso + adapter quote/swap logic, preview helpers
  useLoopZap.ts              # Zap BPT composable (useZapBpt)
  borrow/useMultiplyForm.ts  # Multiply form with Enso/adapter routing + safety margin
  repay/useCollateralSwapRepay.ts  # Repay with Enso routing
  useEulerOperations/vault.ts  # buildMultiplyPlan (EVC batch builder)
  useDeployConfig.ts         # bptAdapterConfig parsing
pages/
  loop-zap/index.vue         # Zap BPT page
  position/[number]/multiply.vue  # Existing position multiply (increase leverage)
server/
  api/enso/route.get.ts      # Enso API proxy (rate-limited, auth)
  utils/enso.ts              # Enso config resolver
abis/
  vault.ts                   # vaultPreviewDepositAbi for ERC4626
entities/
  menu.ts                    # Zap BPT menu item
```

## Available Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Start development server |
| `npm run build` | Build for production |
| `npm run preview` | Preview production build locally |
| `npm run generate` | Generate static site |
| `npm run postinstall` | Prepare Nuxt (runs automatically) |

## Multiply Details

The multiplier slider represents total exposure relative to initial deposit (2x = borrow equal to deposit, 10x = borrow 9x deposit). Max multiplier is bounded by LTV: `max = 1 / (1 - LTV)`. At 95% LTV, theoretical max is 20x.

A safety margin reduces the actual borrow amount by `max(3× slippage, 1%)` to prevent on-chain health check failures from swap price impact. This makes the effective max slightly lower than the theoretical max, especially for Enso-routed pools (2, 3) where price impact is ~1%.

Available leverage is also capped by **borrow vault supply** — if the vault only has 5 AUSD deposited, you can't borrow more than 5 AUSD regardless of multiplier.

## Known Issues & Constraints

1. **Monad SwapVerifier lacks `transferFromSender`.** Any flow that needs to pull user tokens into an EVC batch atomically will fail. The SwapVerifier is immutable. This is why the Zap BPT page exists separately from multiply.

2. **`queryAddLiquidityUnbalanced` reverts on Monad.** Balancer V3 Router's query function requires a static call context. Adapter BPT previews use `ERC4626.previewDeposit` + decimal scaling as a workaround.

3. **Pool hooks block single-sided LP removal.** `removeLiquiditySingleTokenExactIn` reverts with `AfterRemoveLiquidityHookFailed` on all pools. Repay uses Enso routing which works around this.

## AI Context

See `euler-lite-balancer-claude.md` for detailed AI context including architecture, composable documentation, routing decisions, and gotchas.
See `../balancer-contracts/balancer-claude.md` for deployed contracts, adapter details, and hard-won lessons.
