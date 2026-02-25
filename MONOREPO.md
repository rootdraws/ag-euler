# AG-Euler — Monorepo Architecture

## The Core Insight

There is no forking. Everything lives in one place, and every partner deployment is just a different set of env vars.

**Three repos, total:**

```
AG-Euler/  (this repo)                ← all development happens here
rootdraws/euler-lite                  ← one frontend, Vercel watches it
rootdraws/ag-euler-<partner>-labels   ← one per partner, fetched at runtime
```

**N Vercel projects, one codebase:**

```
rootdraws/euler-lite
  └── Vercel Project: cork.alphagrowth.fun     → Cork env vars
  └── Vercel Project: balancer.alphagrowth.fun → Balancer env vars
  └── Vercel Project: infinifi.alphagrowth.fun → InfiniFi env vars
```

Changing env vars in Vercel morphs the site completely. No partner ever gets their own frontend repo.

---

## Repo Structure

### Current (Cork only)

```
AG-Euler/
├── cork-contracts/    ← Cork contracts + deployment scripts
├── cork-docs/         ← Cork protocol documentation
├── cork-labels/       ← local copy, pushed to rootdraws/ag-euler-cork-labels
├── euler-lite/        ← frontend dev copy, pushed to rootdraws/euler-lite
├── euler-vault-scripts/
├── phoenix/           ← Cork Protocol contracts (read-only reference)
├── implementation.md  ← Cork deployment spec
├── TODO.md            ← Cork post-deployment tasks
├── claude.md          ← AG-wide frontend pipeline + Cork context
├── README.md
└── MONOREPO.md
```

### Target (multi-partner)

```
AG-Euler/
├── shared/
│   └── lib/           ← evk-periphery (1.1G), euler-price-oracle (203M), forge-std
├── cork/
│   ├── contracts/     ← src/ + script/ + foundry.toml (references shared/lib/)
│   └── docs/
├── balancer/
│   ├── contracts/     ← src/ + script/ + foundry.toml
│   └── docs/
├── <partner>/
│   ├── contracts/
│   └── docs/
├── euler-lite/        ← one codebase, N Vercel deployments
├── claude.md
├── README.md
└── MONOREPO.md
```

Labels repos remain standalone GitHub repos — `euler-lite` fetches them at runtime via:
`https://raw.githubusercontent.com/<repo>/refs/heads/<branch>/<chainId>/products.json`

---

## The Frontend Model

`euler-lite` is one Nuxt 3 SPA. Every partner site is a Vercel project pointed at `rootdraws/euler-lite` with a different env var set. The env vars control everything visible:

| Env Var | Controls |
|---|---|
| `NUXT_PUBLIC_CONFIG_LABELS_REPO` | Which vaults appear — the entire product |
| `NUXT_PUBLIC_CONFIG_APP_TITLE` | Page title and header branding |
| `NUXT_PUBLIC_CONFIG_APP_DESCRIPTION` | Meta description |
| `NUXT_PUBLIC_CONFIG_DOCS_URL` | Docs link in nav |
| `NUXT_PUBLIC_CONFIG_ENABLE_EARN_PAGE` | Show/hide Earn page |
| `NUXT_PUBLIC_CONFIG_ENABLE_LEND_PAGE` | Show/hide Lend page |
| `NUXT_PUBLIC_CONFIG_ENABLE_EXPLORE_PAGE` | Show/hide Explore page |
| `RPC_URL_HTTP_<chainId>` | Which chains are active |
| `NUXT_PUBLIC_SUBGRAPH_URI_<chainId>` | Subgraph per chain |
| `NUXT_PUBLIC_CONFIG_X_URL` etc. | Social links |

**For custom UI** (partner-specific pages, dashboards, new components): add feature-flagged Vue pages to `euler-lite` toggled via `NUXT_PUBLIC_CONFIG_ENABLE_<FEATURE>`. Develop in `euler-lite/` in this monorepo, push to `rootdraws/euler-lite`, all Vercel projects redeploy automatically. Do NOT create per-partner frontend repos.

---

## The 7-Script Deployment Pattern

Every partner deployment uses the same 7-script sequence. Copy Cork's scripts, update the partner-specific parts.

| Script | Reusable? | What changes per partner |
|---|---|---|
| `01_DeployRouter.s.sol` | Identical — copy as-is | Nothing |
| `02_DeployOracles.s.sol` | Custom | Oracle formula, constructor args, protocol interfaces |
| `03_DeployVaults.s.sol` | Mostly reusable | Asset addresses, vault names/symbols |
| `04_WireRouter.s.sol` | Mostly reusable | Oracle addresses, asset addresses |
| `05_DeployHookAndWire.s.sol` | Custom | Hook invariant logic, hook constructor args |
| `06_ConfigureCluster.s.sol` | Mostly reusable | LTVs, IRM params, fee receiver, caps |
| `07_DeployLiquidator.s.sol` | Custom | Liquidation exit path, protocol-specific calls |

The custom ~12% per deployment:
- **Oracle** — pricing formula specific to the protocol (Cork: `min(NAV, swapRate × sUSDe/USD × (1-fee) × hPool)`. Balancer: BPT pricing via Balancer pool math.)
- **Hook** — invariant specific to the collateral structure (Cork: cST pairing. Balancer: BPT/debt ratio.)
- **Liquidator** — exit path specific to the protocol (Cork: `exercise()`. Balancer: Balancer pool exit.)

---

## Per-Deployment Checklist

### Contracts

- [ ] Create `<partner>/contracts/src/` with custom oracle, hook, liquidator
- [ ] Copy 7 scripts from `cork-contracts/script/` into `<partner>/contracts/script/`
- [ ] Update script constants: asset addresses, pool IDs, expiries, LTVs, IRM params
- [ ] Create `<partner>/contracts/.env` — RPC, private key, Etherscan key, partner protocol addresses
- [ ] Run scripts 01–07 sequentially, paste each deployed address into `.env` before next step
- [ ] Confirm all contracts verified on Etherscan
- [ ] Send liquidator address to partner team for any required whitelist calls

### Frontend

- [ ] Create new Vercel project → source: `rootdraws/euler-lite`
- [ ] Set all partner env vars in Vercel dashboard
- [ ] Set custom domain `<partner>.alphagrowth.fun`

### Labels

- [ ] Create `rootdraws/ag-euler-<partner>-labels` on GitHub
- [ ] Add `1/products.json` — vault addresses grouped into products
- [ ] Add `1/vaults.json` — display names and descriptions per vault
- [ ] Add `1/entities.json` — entries for `alphagrowth`, `euler`, `<partner>`
- [ ] Add `1/points.json` — `[]` if no points program
- [ ] Add `1/opportunities.json` — `{}` if no Cozy protection
- [ ] Add `logo/alphagrowth.svg`, `logo/euler.svg`, `logo/<partner>.svg`
- [ ] Set `NUXT_PUBLIC_CONFIG_LABELS_REPO=rootdraws/ag-euler-<partner>-labels` in Vercel

### Docs

- [ ] Add `<partner>/docs/` with protocol-specific implementation notes
- [ ] Update deployment registry in this file

---

## Shared Lib Migration

`cork-contracts/lib/` currently contains its own copies of `evk-periphery` (1.1G) and `euler-price-oracle` (203M). Every new partner that duplicates this adds another 1.3G to the repo.

**Plan:** When adding `balancer/contracts/`:
1. Move `cork-contracts/lib/evk-periphery`, `cork-contracts/lib/euler-price-oracle`, and `cork-contracts/lib/forge-std` to `shared/lib/`
2. Update `cork-contracts/foundry.toml` to reference `../shared/lib/` paths
3. Wire `balancer/contracts/foundry.toml` to the same `../shared/lib/` paths
4. Each partner brings only its own protocol-specific lib (e.g. Balancer SDK interfaces)

Do this once when adding the first new partner — not before.

---

## Deployment Registry

| Partner | URL | Vercel Project | Labels Repo | Contracts Dir | Status |
|---|---|---|---|---|---|
| Cork | cork.alphagrowth.fun | cork | ag-euler-cork-labels | cork-contracts/ | Live |
| Balancer | balancer.alphagrowth.fun | balancer | ag-euler-balancer-labels | balancer/ | Planned |
