# AG-Euler — TODO

Consolidated task tracker across all partner deployments and repo-wide work.

---

## Repo-Wide

### Frontend & Labels Consolidation (DONE)

All partner frontends consolidated into `frontends/alphagrowth/` — a single euler-lite fork with feature flags for Cork (dual-collateral borrow), Balancer (BPT adapter/Enso multiply, loop-zap), and Origin (ARM multiply). All labels consolidated into `frontends/labels/alphagrowth/` with chain directories for 1 (Cork + Origin), 143 (Balancer), and 8453 (Frax).

- [x] Merge Cork custom code (forkChainMap, cork-borrow page, dual-collateral composable, ERC4626 fallback)
- [x] Merge Origin custom code (ARM ABI, useArmRoute, multiply form ARM branch)
- [x] Merge Balancer custom code (already the base — BPT adapter, Enso, loop-zap)
- [x] Consolidate labels (chains 1, 143, 8453 in one repo)
- [x] Delete per-partner frontends (`euler-lite-cork`, `euler-lite-frax`, `euler-lite-origin`)
- [x] Delete per-partner labels (`cork-labels`, `frax-labels`, `origin-labels`)
- [x] Move `euler-labels` fork to `euler-submission/euler-labels/`

### Remaining Repo Work

- [ ] **Push consolidated labels to GitHub** — the labels repo remote is currently `alphagrowth/ag-euler-balancer-labels`. Either rename it or create a new repo (e.g. `alphagrowth/ag-euler-labels`) and update the `.env` accordingly.
- [ ] **Contracts directory restructure** — consider renaming `cork-contracts/` → `cork/`, etc. under `contracts/` and deduplicating shared libs (forge-std, euler-price-oracle, evk-periphery) into `contracts/shared/`. Not urgent — nothing is broken.

### Vercel / DNS (Michael)

- [ ] **Deploy consolidated frontend** — single Vercel project using `frontends/alphagrowth/`, env vars from `.env`
- [ ] **Configure domain routing** at `euler.alphagrowth.io`

### Repo Updates (Done)

- [x] Update `README.md` for consolidated structure
- [x] Update `TODO.md` for consolidated structure
- [x] Update `CLAUDE.md` for consolidated structure
- [x] Update `new_market.md` for consolidated structure

---

## Cork Protocol — Ethereum Mainnet

Contracts deployed and verified. Labels in `frontends/labels/alphagrowth/1/`. Frontend custom code (dual-collateral borrow) in `frontends/alphagrowth/`.

### Liquidator — CRITICAL: Redeploy Required

The mainnet-deployed liquidator (`0x1e95cC20ad3917ee523c677faa7AB3467f885CFe`) has a **bug in the seizure order** — it seizes vbUSDC before cST, which causes `InvalidParams()` on every liquidation because zero cST is seized when the violator's debt is already cleared. The fixed version (in `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol`) seizes cST first, then vbUSDC, and caps the Cork exercise amount via `previewExercise`. Tested end-to-end on Tenderly fork — full liquidation cycle succeeds.

- [ ] **Redeploy fixed `CorkProtectedLoopLiquidator` to mainnet** — run `07_DeployLiquidator.s.sol` with updated source
- [ ] **Send NEW liquidator address to Cork team for whitelist** — old address is useless
- [ ] **Confirm Cork whitelist on new address** — `WhitelistManager.addToMarketWhitelist(poolId, newAddress)`
- [ ] **Also whitelist deployer EOA** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` for minting test cST

### Liquidation Bot — Built, Needs Production Deploy

Bot scripts at `cork-contracts/script/bot/`. Tested manually on Tenderly fork (successful liquidation: ~6000 sUSDe debt cleared, ~291 sUSDe profit). Uses `cast` (Foundry) and runs as a polling loop.

- [x] Bot scripts created (`setup.sh`, `run.sh`, `.env.example`)
- [x] Bot tested on Tenderly fork — full liquidation cycle confirmed
- [ ] **Deploy bot to Digital Ocean** — install Foundry, configure `.env` with mainnet RPC + bot private key
- [ ] **Fund bot wallet with ETH** for gas on mainnet
- [ ] **Run `setup.sh`** on mainnet (enable controller, set operator, approve sUSDe)
- [ ] **Start `run.sh`** as a systemd service or `nohup` background process

### Post-Deployment Testing

- [x] Borrow tested on Tenderly — hook enforces dual-collateral pairing (vbUSDC + cST)
- [x] Liquidation tested on Tenderly — full cycle works with fixed contract
- [x] Frontend custom code merged into consolidated alphagrowth frontend
- [ ] **Acquire mainnet test assets:**
  - vbUSDC: approve USDC → deposit into Cork's vbUSDC vault (1:1)
  - sUSDe: buy via Ethena or DEX
  - cST: `CorkPoolManager.mint()` — requires Cork whitelist on deployer EOA
- [ ] **Switch Cork frontend to mainnet** — update `.env` from Tenderly RPC to mainnet RPC
- [ ] **Verify on euler.alphagrowth.io** — cluster appears, vaults load, deposit/borrow UI works on real mainnet
- [ ] **Test borrow on mainnet** — deposit vbUSDC + cST, borrow sUSDe
- [ ] **Test liquidation on mainnet** — create unhealthy position, confirm end-to-end

### Blocked on Cork Team

Require `CorkSeriesRegistry` which Cork has not deployed.

- [ ] **H_pool auto-reduction near expiry** — oracle should reduce `hPool → 0` if no valid successor cST exists within `liqWindow`. Mitigation: governor manually calls `CorkOracleImpl.setHPool(0)` before expiry.
- [ ] **Borrow restriction within liqWindow** — hook should block new borrows near expiry without successor cST. Same dependency.
- [ ] **Rollover exception in hook** — `RolloverOperator` temporarily moves cST within EVC batch. Not needed until April 19, 2026.

### Ongoing Monitoring

- [ ] **Rollover operator** — keeper for cST_old → cST_new before expiry. Must be operational before April 19, 2026.
- [ ] **hPool governance** — if Cork pool impaired, call `CorkOracleImpl.setHPool(value)` to reduce collateral value.
- [ ] **Governor transfer** — after demo stable, transfer from deployer EOA to multisig via `setGovernorAdmin` (borrow vault) and `transferGovernance` (router).

---

## Origin Protocol — Ethereum Mainnet

**Status: LIVE.** Contracts deployed, frontend custom code (ARM multiply) merged into consolidated alphagrowth frontend. Labels in `frontends/labels/alphagrowth/1/`. Lending, borrowing, and multiply (direct ARM deposit, zero-slippage looping) all functional.

### Deployed Addresses

| Contract | Address |
|---|---|
| KinkIRM | `0xa3AC336b108E698d5e96D96F9E1b56dAa9B28bcC` |
| EulerRouter | `0x1C33Db5FC563ac9732C5352c37B73d95b7015E6f` |
| WETH Borrow Vault | `0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B` |
| ARM-WETH-stETH Collateral Vault | `0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd` |
| Curator Fee Receiver | `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` |

### What's Working

- [x] Contracts deployed (IRM, router, borrow vault, collateral vault, oracle wired, cluster configured)
- [x] Fee receiver set (10% interest fee → `0x4f894Bfc...`)
- [x] Hook config cleared (operations enabled on both vaults)
- [x] Labels consolidated into alphagrowth labels
- [x] Frontend ARM multiply merged into consolidated frontend
- [x] Lending (deposit WETH into borrow vault)
- [x] Borrowing (borrow WETH against ARM collateral)
- [x] Multiply — direct ARM `deposit()` via GenericHandler (zero-slippage leveraged looping)
- [x] Intrinsic APY sourced from DeFi Llama

### Remaining TODOs

- [ ] **Add `origin.svg` logo** to labels — currently using `origin.png` from euler-labels
- [ ] **EulerSwap pool deployment** — Origin deploys via Maglev. Needed for ARM → WETH instant liquidity, unwind, and liquidations.
- [ ] **ARM CapManager check** — if per-LP caps are active, the Swapper contract may need whitelisting for ARM deposits
- [ ] **`setCaps()`** — tighten supply/borrow caps once ready for production. Currently unlimited (0,0).
- [ ] **EulerSwap equilibrium price updates** — determine if periodic updates are needed as ARM exchange rate drifts up
- [ ] **Initial liquidity** — determine WETH and ARM-WETH-stETH amounts for EulerSwap pool
- [ ] **Liquidation testing** — confirm liquidation works end-to-end for ARM-collateralized positions
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable

---

## Balancer — Monad (Chain 143)

**Status: LIVE.** Contracts deployed and verified on MonadScan. Labels in `frontends/labels/alphagrowth/143/`. Frontend custom code (BPT adapter/Enso multiply, loop-zap) in `frontends/alphagrowth/`. Lending, borrowing, multiply (Pools 1, 2, 4), Zap BPT, and repay all functional.

### Deployed Addresses

| Contract | Address |
|---|---|
| KinkIRM | `0x2CB88c8E5558380077056ECb9DDbe1e00fdbC402` |
| EulerRouter | `0x77C3b512d1d9E1f22EeCde73F645Da14f49CeC73` |
| AUSD Borrow Vault | `0x438cedcE647491B1d93a73d491eC19A50194c222` |
| WMON Borrow Vault | `0x75B6C392f778B8BCf9bdB676f8F128b4dD49aC19` |
| Pool1 Vault (wnAUSD/wnUSDC/wnUSDT0) | `0x5795130BFb9232C7500C6E57A96Fdd18bFA60436` |
| Pool2 Vault (sMON/wnWMON) | `0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5` |
| Pool3 Vault (shMON/wnWMON) | `0x6660195421557BC6803e875466F99A764ae49Ed7` |
| Pool4 Vault (wnLOAZND/AZND/wnAUSD) | `0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92` |
| Pool 1 BPT Adapter | `0xC904aAB60824FC8225F6c8843897fFba14c8Bf98` |
| Pool 4 BPT Adapter | `0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832` |

### What's Working

- [x] Contracts deployed (9 scripts: IRM, router, borrow vaults, collateral vaults, oracles, cluster config, operations, 2 adapters)
- [x] Labels consolidated into alphagrowth labels
- [x] Frontend custom code (BPT adapter, Enso, loop-zap) in consolidated frontend
- [x] Lending (deposit into borrow vaults)
- [x] Borrowing (borrow against BPT collateral)
- [x] Multiply — Pool 1 (adapter) and Pool 4 (adapter) — working
- [x] Multiply — Pool 2 (Enso) — working (with safety margin for swap slippage)
- [x] Zap BPT — all 4 pools (Enso for 1-3, adapter for Pool 4)
- [x] Repay — all pools via Enso
- [x] Oracle pricing verified on-chain
- [x] All contracts verified on MonadScan (source-verified + proxy-linked via Etherscan V2 API)

### Remaining TODOs

- [ ] **`setFeeReceiver(agAddress)`** on both borrow vaults — once AG has a Monad fee address. Currently revenue goes nowhere.
- [ ] **`setCaps()`** — tighten supply/borrow caps on both borrow vaults. Currently unlimited (0,0). Set sensible limits before any real capital flows.
- [ ] **Pool 3 multiply** — untested. Should work via Enso (same path as Pool 2) but needs verification.
- [ ] **Liquidation testing** — confirm liquidation works end-to-end for BPT-collateralized positions.
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable.
- [ ] **Balancer incentives** — Balancer is preparing to incentivize the pools. Monitor TVL and adjust caps/IRM parameters as liquidity grows.

---

## Frax — Base (Chain 8453)

**Status: DEPLOYED.** All contracts live on Base. Labels in `frontends/labels/alphagrowth/8453/`. No custom frontend code needed — standard euler-lite flows.

**Contract dir:** `contracts/frax-contracts/` (Foundry project with `ichi-oracle-kit/` oracle adapter)
**Context doc:** `contracts/frax-contracts/frax-claude.md`
**Governor/deployer:** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448`

### Cluster

5 ICHI vault collateral markets (single-sided frxUSD on Hydrex) + 1 shared frxUSD borrow vault. Custom `ICHIVaultOracle` uses Algebra VolatilityOracle TWAP for flash-loan-resistant pricing.

### Deployed Contracts

| Contract | Address |
|---|---|
| KinkIRM | `0xDa930180CC4203d2Fad620c56828b0a1807a9D27` |
| EulerRouter | `0x6565475B4Ed91aD20Ea9C3799fB04648D1a170CA` |
| ICHIVaultOracleFactory | `0x279901f966160dCf3D53236EbEAc08DC372e0821` |
| OraclePoke | `0x455587b12e079bd1dAc1a16C7470df8F7Fbe69BC` |
| frxUSD Borrow Vault | `0x42BA0a943EDcc846333642d62F500894b199A798` |
| Collateral: BRZ | `0x92f8b6bfC276E9A38545bE6517d3295593060D00` |

### Deployment (COMPLETE)

- [x] **01_DeployIRM** — KinkIRM `0xDa930180CC4203d2Fad620c56828b0a1807a9D27`
- [x] **02_DeployRouter** — EulerRouter `0x6565475B4Ed91aD20Ea9C3799fB04648D1a170CA`
- [x] **03_DeployOracles** — Factory + 5 oracles + OraclePoke (all verified on Basescan)
- [x] **04_DeployBorrowVault** — frxUSD borrow vault
- [x] **05_DeployCollateralVaults** — 5 ICHI collateral eVaults
- [x] **06_WireRouter** — 5x govSetConfig + 5x govSetResolvedVault
- [x] **07_ConfigureCluster** — IRM, 95/97 LTVs, 3% liq discount, unlimited caps

**Note:** KRWQ poke required explicit gas limit (500k) due to gas estimation being too tight for the `beforeSwap` hook + community vault transfer. The `keeper.ts` cron must set an explicit gas limit when calling `pokeStale()`.

### Remaining TODOs

- [x] Labels consolidated into alphagrowth labels
- [ ] **Push labels to GitHub** — included in consolidated labels repo push
- [ ] **Seed OraclePoke** with dust tokens (~$1 each of frxUSD + FX tokens per pool)
- [ ] **Start keeper.ts cron** (every 10 min) — keeps oracle timepoints fresh
- [ ] **Verify frontend** — vaults appear in consolidated frontend, deposit/borrow UI works
- [ ] **`setFeeReceiver()`** — set once AG has a Base fee address
- [ ] **`setCaps()`** — tighten supply/borrow caps before production
- [ ] **Liquidation testing** — confirm end-to-end with treasury liquidation flow
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable
