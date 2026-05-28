# AG-Euler

Alpha Growth's Euler V2 deployment monorepo. Contracts, deployment scripts, labels, and a consolidated frontend for each partner market.

```bash
git clone --recurse-submodules https://github.com/rootdraws/ag-euler.git
```

---

## Deployments

| Partner | Chain | Contracts | Status |
|---|---|---|---|
| Balancer | Monad (143) | [contracts/balancer-contracts/](contracts/balancer-contracts/) | **Live** |
| Origin Protocol | Ethereum (1) | [contracts/origin-contracts/](contracts/origin-contracts/) | **Live** — needs ETH supply |
| Frax | Base (8453) | [contracts/frax-contracts/](contracts/frax-contracts/) | Deployed — needs frxUSD supply |
| Venice (VVV) | Base (8453) | [contracts/venice-contracts/](contracts/venice-contracts/) | **Live** — 3 markets (VVV/USDC/ETH) |
| ZRO (LayerZero) | Base (8453) | [contracts/zro-contracts/](contracts/zro-contracts/) | **Live** — added to Venice cluster |
| AERO | Base (8453) | [contracts/aero-contracts/](contracts/aero-contracts/) | **Live** — added to Venice cluster |
| VIRTUAL | Base (8453) | [contracts/virtual-contracts/](contracts/virtual-contracts/) | **Live** — added to Venice cluster |
| BNB cluster | BSC (56) | [contracts/bnb-contracts/](contracts/bnb-contracts/) | **Live** — USDT/BNB cross-margin |
| AG Mainnet (ETH/USDC/WBTC) | Ethereum (1) | [contracts/mainnet-contracts/](contracts/mainnet-contracts/) | **Live** — extends Origin cluster |
| AG VVV LP (experimental) | Base (8453) | [contracts/ag-vvv-lp-contracts/](contracts/ag-vvv-lp-contracts/) | Isolated canary — agVVVWETHlp Vault7540 → USDC |
| Cork Protocol | Ethereum (1) | [contracts/cork-contracts/](contracts/cork-contracts/) | **Standby** — negotiations open |

Frontend: `euler.alphagrowth.io` — managed by Michael (AG webmaster). Upstream submodule at `frontend/app/`, branded/consolidated layer at `frontends/alphagrowth/`.

AG operational tooling (Safe batches, governance transfers, fee tracker, per-cluster analyses) lives in `ADMIN/`.

---

## Structure

```
AG-Euler/
├── contracts/
│   ├── aero-contracts/         ← AERO collateral, Venice cluster (Base)
│   │   └── script/             ← 7 scripts + DEPLOYED.md
│   ├── ag-vvv-lp-contracts/    ← Experimental: USDC borrow vs agVVVWETHlp (Base)
│   │   ├── script/             ← 7 scripts
│   │   └── vvv-lp-claude.md
│   ├── balancer-contracts/     ← Balancer BPT vaults (Monad)
│   │   ├── src/                ← BalancerBptAdapter
│   │   ├── script/             ← 12 deployment + admin scripts
│   │   └── balancer-claude.md
│   ├── bnb-contracts/          ← BNB cluster, USDT/BNB cross-margin (BSC)
│   │   └── script/             ← 7 scripts + DEPLOYED.md
│   ├── cork-contracts/         ← Cork Protocol (Ethereum mainnet) — standby
│   │   ├── src/                ← oracle, hook, liquidator, vault
│   │   ├── script/             ← 7 deployment scripts + bot/
│   │   └── cork-claude.md
│   ├── frax-contracts/         ← Frax ICHI vaults (Base)
│   │   ├── src/ + ichi-oracle-kit/  ← ICHIVaultOracle + keeper
│   │   ├── script/             ← 8 deployment scripts
│   │   └── frax-claude.md
│   ├── mainnet-contracts/      ← AG ETH/USDC/WBTC triad (Ethereum), shares Origin router
│   │   ├── script/             ← 7 scripts (Safe calldata flow)
│   │   └── safe-batches/       ← AG Safe batch JSONs
│   ├── origin-contracts/       ← Origin ARM × WETH (Ethereum mainnet)
│   │   ├── script/             ← 7 deployment scripts
│   │   └── origin-arm-euler-spec.md
│   ├── venice-contracts/       ← Venice VVV/USDC/ETH cluster (Base)
│   │   └── script/             ← 10 deployment scripts
│   ├── virtual-contracts/      ← VIRTUAL collateral, Venice cluster (Base)
│   │   └── script/             ← 7 scripts + DEPLOYED.md
│   └── zro-contracts/          ← ZRO added to Venice cluster (Base)
│       └── script/             ← 7 scripts (adapter, IRM, router, vault, wire, config, fee)
├── frontend/
│   └── app/                    ← Upstream euler-lite submodule (latest from upstream)
├── frontends/
│   ├── alphagrowth/            ← Consolidated branded frontend (all partners, feature-flagged)
│   │   ├── pages/cork-borrow.vue         ← Cork dual-collateral borrow
│   │   ├── composables/useArmRoute.ts    ← Origin ARM multiply routing
│   │   ├── composables/useEnsoRoute.ts   ← Balancer BPT multiply routing
│   │   └── .env                          ← All chains + feature flags
│   └── labels/
│       ├── alphagrowth/        ← Consolidated labels (chains 1, 56, 143, 8453)
│       │   ├── 1/              ← Cork + Origin + AG mainnet triad (Ethereum)
│       │   ├── 56/             ← BNB cluster (BSC)
│       │   ├── 143/            ← Balancer (Monad)
│       │   └── 8453/           ← Frax + Venice + ZRO + AERO + VIRTUAL (Base)
│       └── euler-submission/
│           └── euler-labels/   ← Fork of euler-xyz/euler-labels (official listing PRs)
├── ADMIN/                      ← Operational tooling: Safe batches, governance transfers, fee tracker, cluster analyses
├── reference/                  ← Upstream read-only repos (submodules + clones)
│   ├── ethereum-vault-connector/
│   ├── euler-interfaces/       ← Core addresses, ABIs, oracle adapters per chain
│   ├── euler-labels/           ← Upstream euler-labels (read-only reference)
│   ├── euler-price-oracle/
│   ├── euler-vault-kit/
│   ├── euler-vault-scripts/
│   ├── evk-periphery/
│   └── ...
├── compost-contracts/          ← Archived experimental work (infinifi-contracts)
├── compost-frontend/           ← Archived frontend forks (cork, origin)
├── CLAUDE.md                   ← AI context: contracts, labels, integration
├── TODO.md                     ← Task tracker (all partners)
├── pending-markets.md          ← Candidate market research (perp FR arb, Pendle PT)
├── new_market.md               ← New market deployment SOP
└── README.md
```

---

## How It Works

**This repo is the contracts + labels + frontend source of truth.** Each partner gets:
1. A Foundry project under `contracts/` with deployment scripts and custom Solidity
2. Labels entries in `frontends/labels/alphagrowth/<chainId>/` controlling which vaults appear in the UI
3. A context doc (`<partner>-claude.md`) capturing architecture decisions and deployed addresses

**Frontend is consolidated.** All partners share a single euler-lite fork at `frontends/alphagrowth/`. Custom flows (Cork dual-collateral borrow, Balancer BPT adapter multiply, Origin ARM multiply) are feature-flagged via env vars. Michael handles production deployment to `euler.alphagrowth.io`.

**Labels drive vault visibility.** If a vault address isn't in the labels repo's `products.json`, it doesn't exist in the UI. Labels are fetched from GitHub raw URLs at runtime. See `CLAUDE.md` for the schema.

---

## The 7-Script Deployment Pattern

| Script | Reusable? | What changes per partner |
|---|---|---|
| `01_DeployIRM.s.sol` | Identical — copy as-is | Rate curve parameters |
| `02_DeployRouter.s.sol` | Identical — copy as-is | Nothing |
| `03_DeployBorrowVault.s.sol` | Mostly reusable | Asset addresses, vault names |
| `04_DeployCollateralVault.s.sol` | Mostly reusable | Asset addresses |
| `05_WireOracle.s.sol` | Custom | Oracle formula, adapter addresses |
| `06_ConfigureCluster.s.sol` | Mostly reusable | LTVs, IRM params, caps |
| `07_SetFeeReceiver.s.sol` | Identical — copy as-is | Fee receiver address |

Full deployment SOP with templates, parameters, and chain addresses: see `new_market.md`.

---

## Per-Deployment Checklist

**Contracts:**
- [ ] Create `contracts/<partner>-contracts/` with Foundry project
- [ ] Copy deployment scripts from Origin (simplest template) or prior partner
- [ ] Create `.env` — RPC, private key, Etherscan key, protocol addresses
- [ ] Run scripts 01–07, paste each deployed address into `.env` before next step
- [ ] Add custom contracts to `src/` if needed (oracle, hook, liquidator, adapter)

**Labels:**
- [ ] Add chain directory to `frontends/labels/alphagrowth/<chainId>/` (or merge into existing chain)
- [ ] Add `products.json`, `vaults.json`, `entities.json`, `points.json`, `opportunities.json`
- [ ] Add partner logo to `frontends/labels/alphagrowth/logo/`
- [ ] Push labels repo to GitHub so the frontend can fetch them

**Frontend:**
- [ ] If custom flow needed, add to `frontends/alphagrowth/` with feature flag
- [ ] Add chain RPC + subgraph to `.env`
- [ ] Coordinate with Michael for production deployment

**Docs:**
- [ ] Add partner section to `TODO.md`
- [ ] Create `<partner>-claude.md` if custom contracts or non-obvious architecture
