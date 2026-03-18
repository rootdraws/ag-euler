# AG-Euler — TODO

Consolidated task tracker across all partner deployments and repo-wide work.

---

## Repo-Wide

### Repo Reorganization + Shared Lib Deduplication

Current layout (`cork-contracts/`, `balancer-contracts/`) doesn't scale — adding a third partner means `threshold-contracts/`, `infinifi-contracts/`, etc. Reorganize into a cleaner structure:

```
AG-Euler/
├── contracts/
│   ├── cork/
│   ├── balancer/
│   ├── <next-partner>/
│   └── shared/           ← deduplicated libs (forge-std, euler-price-oracle, evk-periphery)
├── labels/
│   ├── cork/             ← currently rootdraws/ag-euler-cork-labels (separate repo)
│   ├── balancer/         ← currently rootdraws/ag-euler-balancer-labels (separate repo)
│   └── <next-partner>/
├── euler-lite/
├── reference/
└── ...
```

Do this carefully — nothing should break.

- [ ] Plan the migration (verify no hardcoded paths in scripts, CI, or Vercel)
- [ ] Move `cork-contracts/` → `contracts/cork/`
- [ ] Move `balancer-contracts/` → `contracts/balancer/`
- [ ] Move `origin-contracts/` → `contracts/origin/`
- [ ] Create `contracts/shared/` with deduplicated `forge-std`, `euler-price-oracle`, `evk-periphery`
- [ ] Update each partner's `foundry.toml` and `remappings.txt` to point at `../shared/`
- [ ] Delete duplicated copies from each partner dir
- [ ] Verify both `forge build` still compile clean
- [ ] Decide whether labels stay as separate GitHub repos or move into `labels/` (labels must be fetchable via raw GitHub URL — local paths won't work without a frontend change)

---

## Cork Protocol — Ethereum Mainnet

Contracts deployed and verified. Labels live at `rootdraws/ag-euler-cork-labels`. Frontend at [cork.alphagrowth.fun](https://cork.alphagrowth.fun).

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
- [x] Frontend deployed at cork.alphagrowth.fun (Tenderly fork demo)
- [ ] **Acquire mainnet test assets:**
  - vbUSDC: approve USDC → deposit into Cork's vbUSDC vault (1:1)
  - sUSDe: buy via Ethena or DEX
  - cST: `CorkPoolManager.mint()` — requires Cork whitelist on deployer EOA
- [ ] **Switch cork.alphagrowth.fun to mainnet** — update `.env` from Tenderly RPC to mainnet RPC, remove fork chain mapping if not needed
- [ ] **Verify on cork.alphagrowth.fun** — cluster appears, vaults load, deposit/borrow UI works on real mainnet
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

**Status: LIVE.** Contracts deployed, frontend live at [origin.alphagrowth.fun](https://origin.alphagrowth.fun). Lending, borrowing, and multiply (direct ARM deposit, zero-slippage looping) all functional.

**Frontend repo:** `rootdraws/ag-euler-lite-origin` (fork of euler-lite, customized for ARM adapter multiply)
**Labels repo:** `rootdraws/ag-euler-origin-labels`
**Vercel project:** `ag-euler-lite-origin`

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
- [x] Labels repo created and configured
- [x] Frontend deployed on Vercel (`ag-euler-lite-origin`) with Alchemy RPC
- [x] Lending (deposit WETH into borrow vault)
- [x] Borrowing (borrow WETH against ARM collateral)
- [x] Multiply — direct ARM `deposit()` via GenericHandler (zero-slippage leveraged looping)
- [x] Intrinsic APY sourced from DeFi Llama

### Remaining TODOs

- [ ] **Add `origin.svg` logo** to `origin-labels/logo/` — currently missing
- [ ] **EulerSwap pool deployment** — Origin deploys via Maglev. Needed for ARM → WETH instant liquidity, unwind, and liquidations.
- [ ] **ARM CapManager check** — if per-LP caps are active, the Swapper contract may need whitelisting for ARM deposits
- [ ] **`setCaps()`** — tighten supply/borrow caps once ready for production. Currently unlimited (0,0).
- [ ] **EulerSwap equilibrium price updates** — determine if periodic updates are needed as ARM exchange rate drifts up
- [ ] **Initial liquidity** — determine WETH and ARM-WETH-stETH amounts for EulerSwap pool
- [ ] **Liquidation testing** — confirm liquidation works end-to-end for ARM-collateralized positions
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable

---

## Balancer — Monad (Chain 143)

**Status: LIVE.** Contracts deployed and verified on MonadScan, frontend live at [balancer.alphagrowth.fun](https://balancer.alphagrowth.fun). Lending, borrowing, multiply (Pools 1, 2, 4), Zap BPT, and repay all functional. Balancer preparing pool incentives.

**Frontend repo:** `rootdraws/ag-euler-lite-balancer` (fork of euler-lite, customized for Balancer BPT markets)
**Labels repo:** `rootdraws/ag-euler-balancer-labels`
**Vercel project:** `ag-euler-balancer`

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
- [x] Labels repo created and configured
- [x] Frontend deployed on Vercel (`ag-euler-balancer`)
- [x] Lending (deposit into borrow vaults)
- [x] Borrowing (borrow against BPT collateral)
- [x] Multiply — Pool 1 (adapter) and Pool 4 (adapter) — working
- [x] Multiply — Pool 2 (Enso) — working (with safety margin for swap slippage)
- [x] Zap BPT — all 4 pools (Enso for 1-3, adapter for Pool 4)
- [x] Repay — all pools via Enso
- [x] Oracle pricing verified on-chain
- [x] All contracts verified on MonadScan (source-verified + proxy-linked via Etherscan V2 API)

### Architecture Decisions (Resolved)

| Decision | Outcome |
|---|---|
| Enso Bundle vs EVC Batch | **EVC Batch + Enso Route** (Architecture B). Enso does not support Euler V2 on Monad. |
| Forward routing (borrow→BPT) | Adapter for Pools 1,4 (ERC4626 wrapped tokens). Enso Route for Pools 2,3. |
| Reverse routing (BPT→borrow) | Enso for all pools. Adapter `zapOut` blocked by pool hooks. |
| Swapper multicall strategy | `swap` + `sweep` (not `deposit`). `deposit()` consumes tokens, breaking `verifyAmountMinAndSkim`. |
| BPT preview method | `ERC4626.previewDeposit` + decimal scaling. `queryAddLiquidityUnbalanced` reverts with `NotStaticCall()` on Monad. |
| Debt safety margin | `max(3× slippage, 1%)` reduction on borrow amount to account for swap price impact. |

### Remaining TODOs

- [ ] **`setFeeReceiver(agAddress)`** on both borrow vaults — once AG has a Monad fee address. Currently revenue goes nowhere.
- [ ] **`setCaps()`** — tighten supply/borrow caps on both borrow vaults. Currently unlimited (0,0). Set sensible limits before any real capital flows.
- [ ] **Pool 3 multiply** — untested. Should work via Enso (same path as Pool 2) but needs verification.
- [ ] **Liquidation testing** — confirm liquidation works end-to-end for BPT-collateralized positions.
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable.
- [ ] **Balancer incentives** — Balancer is preparing to incentivize the pools. Monitor TVL and adjust caps/IRM parameters as liquidity grows.

---

## Frax — Base (Chain 8453)

**Status: DEPLOYED.** All contracts live on Base. Labels updated. Frontend cloned and configured.

**Contract dir:** `frax-contracts/` (Foundry project with `ichi-oracle-kit/` oracle adapter)
**Frontend repo:** `euler-lite-frax/` (fork of euler-lite)
**Labels repo:** `rootdraws/ag-euler-frax-labels` (to be pushed to GitHub)
**Context doc:** `frax-contracts/frax-claude.md`
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
| Collateral: BRZ | `0xB5587B4BE26608c7a6E6081B50C43AEBbA09E187` |
| Collateral: tGBP | `0xd8277Cbb6576085C192b9F920c5447aa5624a84B` |
| Collateral: USDC | `0x417E102f1d2BF2E52d0599Da14Fb79dDb4B0b89F` |
| Collateral: IDRX | `0x3371667cB5f6676fa14d95c3839da77705E46A39` |
| Collateral: KRWQ | `0x764Fb38Fe7519d2544BACBc8A495Cf64c0505b44` |

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

- [x] **Update `frax-claude.md`** with deployed addresses
- [x] **Update `frax-labels/` JSON files** with real eVault addresses
- [ ] **Push labels to GitHub** — `rootdraws/ag-euler-frax-labels`
- [ ] **Seed OraclePoke** with dust tokens (~$1 each of frxUSD + FX tokens per pool)
- [ ] **Start keeper.ts cron** (every 10 min) — keeps oracle timepoints fresh
- [x] **Debug KRWQ poke** — root cause: gas estimation too tight. Fix: explicit gas limit (500k) on `pokeStale()` calls
- [ ] **Set `NUXT_PUBLIC_APP_KIT_PROJECT_ID`** in `euler-lite-frax/.env` (Reown project ID)
- [ ] **Create Vercel project** `ag-euler-lite-frax`, set env vars, deploy
- [ ] **Verify frontend** — vaults appear, deposit/borrow UI works
- [ ] **`setFeeReceiver()`** — set once AG has a Base fee address
- [ ] **`setCaps()`** — tighten supply/borrow caps before production
- [ ] **Liquidation testing** — confirm end-to-end with treasury liquidation flow
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable

