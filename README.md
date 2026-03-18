# AG-Euler

Alpha Growth's Euler deployment monorepo. Each subdirectory is a partner deployment — custom contracts, deployment scripts, and docs. Shared frontend ([ag-euler-lite](https://github.com/rootdraws/ag-euler-lite)) configured per partner via env vars in Vercel, with per-partner forks when custom UX is needed.

```bash
git clone --recurse-submodules https://github.com/rootdraws/ag-euler.git
```

---

## Deployments

| Partner | URL | Contracts | Frontend | Status |
|---|---|---|---|---|
| Cork Protocol | [cork.alphagrowth.fun](https://cork.alphagrowth.fun) | [cork-contracts/](cork-contracts/) | [ag-euler-lite-cork](https://github.com/rootdraws/ag-euler-lite-cork) | Live (Tenderly demo) |
| Balancer | [balancer.alphagrowth.fun](https://balancer.alphagrowth.fun) | [balancer-contracts/](balancer-contracts/) | [ag-euler-lite-balancer](https://github.com/rootdraws/ag-euler-lite-balancer) | **Live** |
| Origin Protocol | [origin.alphagrowth.fun](https://origin.alphagrowth.fun) | [origin-contracts/](origin-contracts/) | [ag-euler-lite-origin](https://github.com/rootdraws/ag-euler-lite-origin) | **Live** |

---

## Structure

```
AG-Euler/
├── cork-contracts/          ← Cork Protocol deployment (Ethereum mainnet)
│   ├── src/                 ← oracle, hook, liquidator, vault
│   ├── script/              ← 7 deployment scripts + bot/
│   │   └── bot/             ← liquidation bot (setup.sh, run.sh, .env.example)
│   ├── cork-README.md
│   ├── cork-implementation.md
│   └── cork-claude.md
├── euler-lite-cork/         ← Cork frontend (separate repo → rootdraws/ag-euler-lite-cork)
├── euler-lite/              ← shared frontend (independent repo → rootdraws/ag-euler-lite)
├── balancer-contracts/      ← Balancer BPT vault deployment (Monad, chain 143)
│   ├── src/                 ← BalancerBptAdapter (single-sided LP + ERC4626 wrapping)
│   ├── script/              ← 9 deployment scripts + test scripts
│   └── balancer-claude.md
├── euler-lite-balancer/     ← Balancer frontend (separate repo → rootdraws/ag-euler-lite-balancer)
├── origin-contracts/        ← Origin ARM x Euler deployment (Ethereum mainnet)
│   ├── script/              ← 7 deployment scripts (IRM, router, vaults, oracle, cluster, fee receiver)
│   └── origin-arm-euler-spec.md
├── origin-labels/           ← Origin labels (local copy → rootdraws/ag-euler-origin-labels)
├── euler-lite-origin/       ← Origin frontend (separate repo → rootdraws/ag-euler-lite-origin)
├── reference/               ← upstream read-only repos (submodules)
│   ├── ethereum-vault-connector/
│   ├── euler-interfaces/
│   ├── euler-labels/
│   ├── euler-vault-kit/
│   ├── euler-vault-scripts/
│   └── phoenix/
├── TODO.md                  ← consolidated task tracker (all partners)
├── CLAUDE.md                ← AG-wide frontend context
└── README.md
```

---

## The Core Insight

Everything lives in one place. Most partner deployments are just a different set of env vars on the shared frontend.

**Repos:**

```
AG-Euler/  (this repo)                ← all development happens here
rootdraws/ag-euler-lite               ← shared frontend, Vercel watches it
rootdraws/ag-euler-lite-cork          ← Cork-specific frontend (custom dual-collateral borrow flow)
rootdraws/ag-euler-lite-balancer      ← Balancer-specific frontend (BPT zap, Enso/adapter multiply)
rootdraws/ag-euler-lite-origin        ← Origin-specific frontend (ARM deposit adapter multiply)
rootdraws/ag-euler-<partner>-labels   ← one per partner, fetched at runtime
```

**N Vercel projects:**

```
rootdraws/ag-euler-lite
  └── Vercel Project: infinifi.alphagrowth.fun → InfiniFi env vars (future)

rootdraws/ag-euler-lite-cork
  └── Vercel Project: cork.alphagrowth.fun     → Cork env vars

rootdraws/ag-euler-lite-balancer
  └── Vercel Project: balancer.alphagrowth.fun → Balancer env vars

rootdraws/ag-euler-lite-origin
  └── Vercel Project: origin.alphagrowth.fun  → Origin env vars
```

**Default model:** Changing env vars in Vercel morphs the shared frontend completely — no per-partner repo needed.

**When to fork:** Cork and Balancer both required separate frontend repos. Cork's dual-collateral borrow flow (vbUSDC + cST) couldn't be feature-flagged. Balancer's BPT zap page, Enso routing integration, and adapter-based multiply are too specialized for the shared codebase. If a partner needs custom swap routing, non-standard collateral flows, or dedicated pages, fork `ag-euler-lite` into `ag-euler-lite-<partner>`.

---

## The Frontend Model

`ag-euler-lite` is one Nuxt 3 SPA. Every partner site is a Vercel project pointed at `rootdraws/ag-euler-lite` with a different env var set:

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

For custom UI: first try feature-flagged Vue pages in `ag-euler-lite` toggled via `NUXT_PUBLIC_CONFIG_ENABLE_<FEATURE>`. If the customization is too deep (e.g. Cork's dual-collateral borrow, Balancer's Enso/adapter routing), fork into `ag-euler-lite-<partner>` and point a separate Vercel project at it.

Reference repos (`euler-vault-kit`, `ethereum-vault-connector`, `euler-interfaces`, `euler-labels`, `phoenix`) are submodules — pinned upstream sources. Labels repos (`rootdraws/ag-euler-<partner>-labels`) are standalone, managed independently.

---

## The 7-Script Deployment Pattern

| Script | Reusable? | What changes per partner |
|---|---|---|
| `01_DeployRouter.s.sol` | Identical — copy as-is | Nothing |
| `02_DeployOracles.s.sol` | Custom | Oracle formula, constructor args |
| `03_DeployVaults.s.sol` | Mostly reusable | Asset addresses, vault names |
| `04_WireRouter.s.sol` | Mostly reusable | Oracle + asset addresses |
| `05_DeployHookAndWire.s.sol` | Custom | Hook invariant logic |
| `06_ConfigureCluster.s.sol` | Mostly reusable | LTVs, IRM params, fee receiver |
| `07_DeployLiquidator.s.sol` | Custom | Liquidation exit path |

---

## Per-Deployment Checklist

**Contracts:**
- [ ] Create `<partner>/contracts/src/` with custom oracle, hook, liquidator
- [ ] Copy 7 scripts from a prior deployment, update constants + addresses
- [ ] Create `<partner>/contracts/.env` — RPC, private key, Etherscan key, protocol addresses
- [ ] Run scripts 01–07, paste each deployed address into `.env` before next step
- [ ] Send liquidator address to partner team for whitelist if required

**Frontend:**
- [ ] Create new Vercel project → source: `rootdraws/ag-euler-lite` → set partner env vars
- [ ] Set custom domain `<partner>.alphagrowth.fun`

**Labels:**
- [ ] Create `rootdraws/ag-euler-<partner>-labels` on GitHub
- [ ] Add `1/products.json`, `1/vaults.json`, `1/entities.json`, `1/points.json`, `1/opportunities.json`
- [ ] Add `logo/alphagrowth.svg`, `logo/euler.svg`, `logo/<partner>.svg`
- [ ] Set `NUXT_PUBLIC_CONFIG_LABELS_REPO=rootdraws/ag-euler-<partner>-labels` in Vercel

**Docs:**
- [ ] Add partner section to `TODO.md` at repo root
- [ ] Add `<partner>-contracts/<partner>-claude.md` with deployment learnings

---

## Shared Lib Migration

`cork-contracts/lib/` contains its own copies of `evk-periphery` (1.1G) and `euler-price-oracle` (203M). When adding the first new partner:

1. Move to `shared/lib/` at repo root
2. Update each partner's `foundry.toml` to reference `../../shared/lib/`
3. Delete duplicated copies

Do this once when adding `balancer/contracts/` — not before.
