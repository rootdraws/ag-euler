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

### Cork Architecture Pivot — Redemption Pool (from Mar 9, 2026 call)

Cork is shifting from an insurance/depeg-protection model to a **redemption pool** model. Key changes:

**Redemption pool vs insurance pool:**
- The Cork pool functions as a redemption facility, not depeg insurance. It buys the collateral asset (e.g. hgETH) at its NAV or slight discount — not 1:1.
- cST tokens are "tickets" that enable access to the redemption pool. They don't have independent value — they're the key that makes the redemption happen.
- Cork's profit model: extracting a portion of position NAV when pools transition between epochs. Pools have a fixed lifespan, then cST goes to 0.

**Oracle change needed:**
- Current liquidator assumes 1:1 exchange (ref asset to collateral asset). This is wrong for a redemption pool.
- Must use the actual exchange rate between collateral asset and reference asset. Cork has a `previewSwap` function for this.
- Example: if hgETH = 1.1 ETH and rsETH = 1.2 ETH, you need ~1.09 hgETH to redeem 1 rsETH. The ratio fluctuates.

**New market needed:**
- Deploy a Cork pool for hgETH / rsETH
- Deploy a new Euler market for hgETH / ETH
- The liquidator needs to be multi-step (manageable via EVC batching)

**Multiply / looping with cST:**
- Looping requires acquiring cST tokens within the multiply EVC batch (you need cST + collateral as a pair)
- Cork has a limit order system (built on 1inch protocol) for cST purchases
- Options: (a) integrate Cork's limit orders into the EVC batch via GenericHandler, (b) ask Euler to add Cork routing to their swap API, (c) Cork builds a zap contract around their limit order system
- Unwinding = selling/redeeming cST in the opposite direction

**cST rollover / epoch migration:**
- cST tokens expire (e.g. every 90 days). At expiry, cST goes to 0.
- Before expiry, a rollover operator must migrate all cST_old to cST_new via EVC batch
- Users pay a premium (cost of ongoing insurance) to extend — taken from ref asset value
- The oracle must accept multiple cST addresses simultaneously (overlap period where both cST_old and cST_new are valid collateral)
- Users must delegate collateral management to an operator who can perform the swap
- Cork will provide a `CorkSeriesRegistry` contract for tracking valid cST addresses
- Hard deadline: cST_old becomes worthless at expiry. Rollover operator must act before this.
- The governor/bot needs to: add new cST collaterals to the market, perform debt swaps, migrate positions — all before expiry via EVC batching

**Open items (blocked on Cork):**

- [ ] **Cork to provide rollover contract MVP** — allows testing cST_old to cST_new migration on Tenderly
- [ ] **Cork to provide `CorkSeriesRegistry`** — on-chain registry of valid cST addresses per pool
- [ ] **Cork to clarify limit order integration** — how to buy cST within an EVC batch for multiply
- [ ] **Deploy hgETH / rsETH Cork pool** — new pool for redemption-model testing
- [ ] **Deploy hgETH / ETH Euler market** — new market with multi-step liquidator
- [ ] **Update oracle to use `previewSwap` exchange rate** — not 1:1, use actual CA/RA ratio
- [ ] **Update liquidator for redemption model** — seize at NAV exchange rate, not 1:1
- [ ] **Test cST expiry scenarios** — what happens to positions when cST approaches 0
- [ ] **Build rollover governor bot** — automated EVC batch that adds new cST collaterals and migrates positions before expiry

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

### Launch (pending Euler app.euler.finance listing)

Official listing PR submitted: [euler-xyz/euler-labels#521](https://github.com/euler-xyz/euler-labels/pull/521). Once approved:

- [ ] **Schedule podcast with Origin** — co-marketing for launch
- [ ] **Prepare incentives campaign** — ready to go at launch, coordinate with Origin on rewards structure

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

### Balancer Frontend Feedback

**Zap-to-Multiply integration** — Balancer wants BPT Zap integrated into the multiply flow. This is not directly possible because multiply uses EVC Batching (Euler Vault to Euler Vault multicalls), while BPT Zap is an Enso routing solution that starts from wallet assets. The constraint: EVC Batches must start within an Euler Vault. So `BPT -> EVC Batch Multiply` works (first step is deposit collateral), but `AUSD -> BPT -> EVC Batch Multiply` does not — because the first leg (AUSD to BPT) happens outside the EVC.

- [ ] **Build transaction sequencer** — Execute the Enso BPT Zap as a separate tx, then trigger an EVC Batch multiply. Two-step flow but presented as one user action. Required for the underlying-asset-to-leveraged-position UX.

- [ ] **Unified multiply UI with underlying asset selectors** — Balancer wants a UI like:
  ```
         [AUSD - USDC - USDT0]          <- click = standard EVC Batch Multiply (already have BPT)
     [AUSD]    [USDC]    [USDT0]        <- click = BPT Zap then sequence into EVC Batch Multiply
  ```
  Clicking the pool token row does a standard multiply. Clicking an individual underlying asset does a Zap + Multiply sequence. Goal: reduce friction from "I hold an asset" to "I hold a looped BPT LP position."

- [ ] **BPT icons match Balancer pool icons** — Use Balancer's pool icon assets for BPT vault display.

- [ ] **Remove `wn` prefixes** — Display `USDT` instead of `wnUSDT`, `USDC` instead of `wnUSDC`, etc. Cosmetic label change in vault display names.

- [ ] **Default route to borrow page** — Main domain should load the borrow page on initial visit, not the lending page.

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

### Launch Plan (from Mar 17-19, 2026 Telegram)

Frontend live at `frax.alphagrowth.fun` — frxUSD borrowable, BRZ as collateral, Chainlink oracle, everything connected. Should also get listed on Euler's official frontend.

**Three things needed for go-live:**

1. **frxUSD supply** — co-incentivization + co-marketing with collateral asset issuers and their LPs through Hydrex. Austin (Hydrex) can set bribes into Hydrex supply-side gauges.
2. **BRZ borrow demand** — users who want to borrow BRZ for Hydrex LP farming. Hydrex can help drive this. Nader (Frax) notes most borrowers prefer setting their own positions, not single-sided vaults.
3. **Liquidator strategy** — two options discussed:
   - Internalized: hold a frxUSD vault, accept BRZ on liquidation
   - Volume-driving: liquidator pushes trades through frxUSD/BRZ LP on Hydrex (Nader's preference — adds volume to Frax pools)

**Contacts:** Nader (Frax), Austin Lee (Hydrex), Pedro (via Austin — can help with all three items)

- [ ] **Submit to Euler official frontend** — get listed on app.euler.finance
- [ ] **Coordinate with Pedro (via Austin)** — key contact for supply, demand, and liquidation
- [ ] **Set up co-incentivization** — AG + Frax + Hydrex bribes for frxUSD supply-side gauges
- [ ] **Build liquidator** — volume-driving through Hydrex frxUSD/BRZ LP (preferred by Frax)
- [ ] **Co-marketing with Frax** — joint announcement once supply + demand are seeded

---

## ZRO (LayerZero) — Base (Chain 8453)

**Status: SCRIPTS READY.** Adding ZRO to an existing USDC/ETH cluster deployed by co-worker (Kyril). ZRO is both borrowable (against USDC + ETH collateral) and usable as collateral (to borrow USDC or ETH). No custom Solidity — uses Euler's `ChainlinkOracle` adapter from reference repos.

**Contract dir:** `contracts/zro-contracts/`
**Chain:** Base (8453)
**Collaborator:** KyrilVlasenko (GitHub) — deploys USDC/ETH/VVV cluster, we add ZRO to it

### Market Design

```
        USDC Vault       ETH Vault      (Kyril deploys)
           |   \         /   |
           |    \       /    |
           |     ZRO Vault   |          (we deploy)
           |    /       \    |
           |   /         \   |
        VVV Vault    (other collaterals)
```

- ZRO Borrow Vault: accepts USDC + ETH vaults as collateral (70% / 75% LTV)
- Existing USDC Vault: accepts ZRO vault as collateral (70% / 75% LTV)
- Existing ETH Vault: accepts ZRO vault as collateral (70% / 75% LTV)
- Unit of account: USD (address(840)) for all vaults

### Key Addresses

| Item | Address |
|---|---|
| ZRO token | `0x6985884C4392D348587B19cb9eAAf157F13271cd` |
| USDC token | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| WETH token | `0x4200000000000000000000000000000000000006` |
| Chainlink ZRO/USD feed | `0xdc31a4CCfCA039BeC6222e20BE7770E12581bfEB` |
| Existing USDC/USD adapter | `0x5C9d3504d64B401BE0E6fDA1b7970e2f5FF75485` |
| Existing ETH/USD adapter | `0xeCa05CC73e67c344d5B146311B13ddB75F7fE4E4` |

### Parameters

| Parameter | ZRO Vault | USDC/ETH Vaults |
|---|---|---|
| IRM | Base=2%, Kink(70%)=15%, Max=200% | Managed by Kyril |
| Borrow LTV | 70% | 70% (for ZRO collateral) |
| Liquidation LTV | 75% | 75% (for ZRO collateral) |
| Max Liq Discount | 5% | Unchanged |
| Interest Fee | 10% | Unchanged |
| Supply Cap | 185,000 ZRO | Managed by Kyril |
| Borrow Cap | 185,000 ZRO | Managed by Kyril |

### Deployment

Scripts 1–4 are standalone (we run). Scripts 5–6 touch existing vaults (Kyril runs — he's governor).

- [ ] **Step 1: Deploy ChainlinkOracle adapter** — ZRO/USD (25h staleness)
- [ ] **Step 2: Deploy IRM** — ZRO curve only
- [ ] **Step 3: Deploy EulerRouter** — for ZRO vault only
- [ ] **Step 4: Deploy ZRO Borrow Vault** — asset=ZRO, unitOfAccount=USD
- [ ] **Step 5: Wire oracles** — wire 3 routers (ZRO, USDC, ETH) with adapters + resolved vaults
- [ ] **Step 6: Configure cluster** — IRM, LTV, caps on ZRO vault + add ZRO collateral to USDC/ETH vaults
- [ ] **Step 7: Set fee receiver** — ZRO vault only

### Prerequisites (from Kyril)

- [ ] **USDC/ETH/VVV cluster deployed** — Kyril provides vault + router addresses for `.env`
- [ ] **Governor access** — Kyril must run scripts 5+6 (or transfer governance)

### Remaining TODOs

- [ ] **Labels** — add ZRO vaults to `frontends/labels/alphagrowth/8453/` (products, vaults, entities)
- [ ] **Official listing** — PR to euler-xyz/euler-labels for app.euler.finance
- [ ] **Coordinate USDC/ETH caps with Kyril** — his caps are shared across all collateral types
- [ ] **Liquidation testing** — confirm end-to-end for ZRO-collateralized positions
- [ ] **Governor transfer** — transfer ZRO vault + router from deployer EOA to multisig

---

## Base Expansion — HIGH PRIORITY (Chain 8453)

New collateral types and LP markets on Base. These add to the existing AG USDC cluster (currently paired with reUSD) and the Kyril USDC/ETH cluster.

### Frankencoin ZCHF — First Priority

Add ZCHF as collateral to AG's existing USDC borrow vault on Base. Chainlink oracle, 90% LTV (Frax-style tight parameters — highly correlated stablecoin pair).

- [ ] **Confirm ZCHF token address on Base** — and verify Chainlink ZCHF/USD feed exists
- [ ] **Deploy ChainlinkOracle adapter** — if no existing adapter on Base (check CSV)
- [ ] **Add ZCHF to existing USDC vault** — Phase 2B pattern (same as ZRO): deploy ZCHF vault + wire into existing USDC router + setLTV
- [ ] **Set LTV 90% / 93%** — stablecoin pair, tight spread
- [ ] **Labels + frontend** — add to Base labels

### Base DeFi / LP Tokens — Hedging, Farming, LP-as-Collateral Loops

Target protocols for LP token collateral markets. The play: deposit LP tokens as collateral, borrow one side to hedge impermanent loss, or loop for leveraged farming.

**Venice**
- [ ] Research Venice LP structure on Base — token addresses, ERC-4626 compatibility, oracle options

**Virtuals**
- [ ] Research Virtuals LP structure on Base — token addresses, oracle options

**Morpheus**
- [ ] Research Morpheus LP structure on Base — token addresses, oracle options

**Aerodrome**
- [ ] Research Aerodrome LP tokens as collateral — concentrated liquidity positions, oracle pricing challenges
- [ ] Already listed on Compound (borrow only), Morpho (collateral only), Euler — check what's missing

**Hydrex**
- [ ] Research Hydrex LP tokens on Base — ties into Frax BRZ work above
- [ ] Coordinate with Austin Lee (Hydrex) on LP-as-collateral structure

---

## USND / USDC — Arbitrum (Chain 42161)

**Status: TODO.** Standard ERC-4626 or Chainlink-priced market. No custom contracts expected. Follow the `new_market.md` SOP.

**Chain:** Arbitrum (42161)
**Market:** Borrow USDC against USND collateral (or cross-margin TBD)
**SOP:** `new_market.md` — Phase 0 through Phase 5

### Deployment Checklist

- [ ] **Phase 0: Research** — confirm USND token address on Arbitrum, check if ERC-4626, find oracle (Chainlink/Pyth feed or resolved vault)
- [ ] **Phase 0: Check existing adapters** — `reference/euler-interfaces/addresses/42161/OracleAdaptersAddresses.csv`
- [ ] **Phase 1: Scaffold** — `contracts/usnd-contracts/`, copy from Origin template, set Arbitrum addresses
- [ ] **Phase 2: Deploy contracts** — IRM, router, vaults, wire oracle, configure cluster, fee receiver
- [ ] **Phase 3: Labels** — add to `frontends/labels/alphagrowth/42161/` (new chain dir if first Arbitrum deployment)
- [ ] **Phase 4: Frontend** — add Arbitrum RPC + subgraph to `.env` if not already present. No custom code expected
- [ ] **Phase 5: Verify** — vaults appear, lending/borrowing works, oracle prices correct
- [ ] **Meeting 4/3** — with USND team

---

## InfiniFi — Credit Pool Structure (Ethereum Mainnet)

**Status: SOLUTION DESIGNED, BLOCKED ON TAYLOR.** The Credit Pool is a liquidation solution for assets with locked or non-atomic redemption periods. The solution is mostly built. Working demo at https://www.alphagrowth.markets/. Diagrams and slides on Figma.

**GTM:** Launch without permission, offer them the tools. Infinifi is busy with portfolio allocation and will respond when available.

**Key contact:** Taylor (InfiniFi) — need to verify market structure before deployment.

### What We're Building

A Credit Pool infrastructure that activates InfiniFi's locked assets (liUSD buckets with various lock durations) for looping, backed by a shared credit facility for liquidations.

**The markets:**
- All liUSD buckets + oracles (one per lock duration)
- EulerSwap V2 pool for each bucket
- Price reconfiguration bot
- iUSD looping pool (borrow iUSD against locked liUSD collateral)
- iUSD Credit Pool (liquidation facility — holds capital until needed)
- Allocator bot + Earn Vault (distributes supply between loop pool and credit pool)
- Liquidator for all buckets

### How It Works

**Loop Pool:** Users deposit locked liUSD buckets as collateral, borrow iUSD, loop for leverage. Standard Euler multiply flow.

**Credit Pool:** Holds inactive capital. When a liquidation occurs on a locked asset that can't be atomically redeemed, the Credit Pool provides the liquidity. InfiniFi must then repay that debt, or they're charged punitive interest.

**Partial liquidations** are the default — required because the underlying assets are locked. The Credit Pool covers the gap until InfiniFi replenishes.

### IR Curves

**Loop Pool:** Kink set below InfiniFi's APR so loops remain profitable. ~6.5% at kink to borrow iUSD.

**Credit Pool:** Punitive rates to encourage fast repayment. Starting at 20%, 30% at kink. Standing credit balances are expensive.

### Revenue Model

InfiniFi supplies ~$20M in iUSD, split between Credit Pool and Loop Pool. With locked assets, loop pool can reach the kink.

AG earns 5% curator share on total utilization:
- Conservative (9M utilization @ 6.5%): ~$29k/yr
- Moderate (13.5M @ 6.5%): ~$44k/yr
- Aggressive (17M @ 6.5%): ~$55k/yr

Credit Pool revenue: AG's share following a $1M liquidation held at 25% for 1 week = $240.

### Risk: iUSD Depeg

If iUSD depegs, the locked bucket oracles (e.g. liUSD-4w) lose proportional value since we're looping in iUSD, not USDC. The oracle for locked assets is directly correlated to iUSD value. The entire structure is iUSD-denominated — if InfiniFi dies, it all dies.

Mitigation: partial liquidations as default + handshake agreement on InfiniFi's replenishment speed.

### Worst Case Allocation

If optimized for supply over safety (19M supply / 1M credit pool), partial liquidations become critical. Need a proactive allocator pushing supply toward the Credit Pool to maintain capacity, while trusting InfiniFi to pay debts.

### Partnerships & Distribution

- **Euler:** Offered a frontend. Will use it. Also offered co-marketing article on the Credit Pool solution.
- **m0:** Euler offered intro — same Credit Pool structure for m0's assets.
- **USDM1:** Potential integration to make credit pool more efficient, apply to reUSD on Katana.
- **alphaUSD:** AG will use this credit pool structure for its own alphaUSD tokens.
- **Co-marketing:** InfiniFi + AlphaGrowth + Euler joint distribution. Key messages: Credit Pool for RWAs on Euler, loop InfiniFi's locked assets, earn on iUSD lending.

### Blockers & Next Steps

- [ ] **Speak with Taylor (InfiniFi)** — verify market structure for all buckets
- [ ] **Modify Credit Pool for partial liquidations** — current implementation needs adjustment
- [ ] **Create pools for all liUSD buckets** — one per lock duration
- [ ] **Connect with Ivan** — how to deploy using AlphaGrowth multisig
- [ ] **Deploy scripts** — mostly ready, need small modifications per bucket
- [ ] **Attract Credit Pool supply** — needs incentivization strategy (Earn Vault, allocator bot)
- [ ] **Euler frontend integration** — use the frontend they offered
- [ ] **Co-marketing with Euler** — article on Credit Pool solution for locked/RWA assets
- [ ] **m0 intro** — follow up on Euler's offer to connect

### Related: Redstone + Symbiotic — Duration Risk Liquidation Infrastructure

Redstone is actively building more efficient liquidation infrastructure for duration risk mismatch assets — the same class of problem the Credit Pool solves. No action required from us right now, but we need to decide which assets to deploy first.

This applies broadly to any collateral with non-atomic redemption (locked liUSD buckets, Pendle PTs with long durations, RWAs with withdrawal queues). The Credit Pool is our current solution; Redstone's work may provide a better or complementary one.

- [ ] **Decide target assets for duration risk markets** — which locked/queued assets do we deploy first? Cross-reference with `pending-markets.md` Part 2 (Pendle PT leverage) and InfiniFi buckets above
- [ ] **Track Redstone progress** — they will deliver improved liquidation tooling. Evaluate when ready and decide if it replaces or supplements the Credit Pool approach

---

## Midas / 0g — Morpho on 0g (Not Euler)

**Status: BLOCKED ON ORACLE INFO.** This is a Morpho deployment on 0g, not Euler — but tracked here since AG manages it. mRocks and mRe7 as collateral on Morpho markets via Oku frontend.

**Repo:** https://github.com/rootdraws/0g-alphagrowth (includes frontend)
**Frontend:** https://0g.alphagrowth.markets/

### What Needs to Happen

1. Deploy mRocks and mRe7 as collateral to Morpho markets on 0g
2. Register the collateral with the MetaMorpho vault
3. Set fees
4. Test the frontend

### Blockers & Next Steps

- [ ] **Requested oracle info from Midas** — need oracle and contract details for mRocks and mRe7
- [ ] **Deploy collateral** — once oracle info received
- [ ] **Register collateral with MetaMorpho vault** — part of the Morpho deployment process
- [ ] **Set fees** — configure curator fees on the vault
- [ ] **Test frontend** — verify 0g.alphagrowth.markets works end-to-end
- [ ] **Ask Merkl about 0g coverage** — need to confirm Merkl supports 0g chain for incentives

---

## Avalanche — CDP or Euler Markets

**Status: INITIAL CONTACT.** They need either a CDP or Euler markets. Meeting scheduled for 2026-04-07.

- [ ] **Meeting 4/7** — understand what they need (CDP vs lending markets, which assets, chain requirements)
- [ ] **Determine deployment path** — Euler V2 on Avalanche (chain 43114) is supported. Check `reference/euler-interfaces/addresses/43114/` for core addresses
- [ ] **Follow up after meeting** — scope the work based on what's discussed

---

## Low Priority

### Coinshift — Fixed Rate Stablecoin Market

Stablecoin issuer backed by Superstate, 7% yield. They want fixed rate lending. Will supply incentives to hit hurdle rates and juice for suppliers. Jonthony is managing this.

Spec doc: https://docs.google.com/document/d/1A1Ih4mDeeE121pcZwPLXXESmmhYuVGZg5tnW-xdZ5P4/edit?tab=t.0

- [ ] **Jonthony to advance** — coordinate with Coinshift on fixed rate structure and incentive plan

### RACC — RWA Stablecoin Lending

RACC wants to lend their RWA stablecoin. Has a Curve pool and frxUSD LP partnership. Jonthony will stone soup with Coinshift — RACC supplies capital.

- [ ] **Jonthony to bundle with Coinshift** — RACC as supply-side partner to Coinshift's market

### BTCY — Euler Market (Long/Short)

Lead from Shardul. BTCY wants an Euler market — possibly long and short against a stablecoin, possibly a loop. Open question: what's the supply side? Doc shared in Telegram: https://aarc.docsend.com/view/s/fwr3pp8myck3hv8e

- [ ] **Review BTCY doc** — understand the token structure and what market design makes sense
- [ ] **Determine supply source** — who provides the other side of the market?
