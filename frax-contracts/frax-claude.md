# Frax ICHI Vault Cluster — Contract Context (Base 8453)

AI context file for the Frax ICHI vault deployment on Base. Auto-loaded by Cursor as a workspace rule.

---

## Overview

5 ICHI vault collateral markets + 1 shared frxUSD borrow vault on Base. All collateral is single-sided frxUSD deposit ICHI vault shares on Hydrex (Algebra V3 DEX). The custom ICHIVaultOracle adapter provides TWAP-hardened pricing — reads the Algebra VolatilityOracle plugin instead of spot price to resist flash-loan manipulation.

**Unit of account:** frxUSD. Debt pricing is trivial (frxUSD → frxUSD = 1:1 in the router).

---

## Cluster

| # | ICHI Vault | Pair | ICHI Address |
|---|---|---|---|
| 1 | frxUSD/BRZ | Brazilian Real | `0x80CBb36F48fad69069a3B93989EEE3bAD8f3f103` |
| 2 | tGBP/frxUSD | British Pound | `0x52801C578172c7cb60a0646fc0af6a42A47bA403` |
| 3 | USDC/frxUSD | USD Coin | `0x6F28872Ed9b0dAe3273f5d9eadBeD224f8D24c19` |
| 4 | IDRX/frxUSD | Indonesian Rupiah | `0x1ffEa4b2d372d2c85fE3A7f28BB1B213dF8c58ED` |
| 5 | KRWQ/frxUSD | Korean Won | `0xdD01Aa17Db58068b877001f3741422DF439c0E0d` |

**Direct token collateral (added post-deploy via script 08):**

| # | Token | Description | Address |
|---|---|---|---|
| 6 | BRZ | Brazilian Digital Real (raw ERC-20) | `0xE9185Ee218cae427aF7B9764A011bb89FeA761B4` |

Borrow asset: frxUSD (`0xe5020A6d073a794B6E7f05678707dE47986Fb0b6`)

---

## Deployed Addresses (Base 8453)

| Contract | Address |
|---|---|
| KinkIRM | `0xDa930180CC4203d2Fad620c56828b0a1807a9D27` |
| EulerRouter | `0x6565475B4Ed91aD20Ea9C3799fB04648D1a170CA` |
| ICHIVaultOracleFactory | `0x279901f966160dCf3D53236EbEAc08DC372e0821` |
| Oracle (frxUSD/BRZ) | `0xAf9063c6155D11aFe6FB049c11d8014046702F12` |
| Oracle (tGBP/frxUSD) | `0x570E49e1fe27403619446ec348Ba6397019Bd6B7` |
| Oracle (USDC/frxUSD) | `0x53c04a2FF4B8c1F9F3695dBe4d7fE295EdA23ff2` |
| Oracle (IDRX/frxUSD) | `0x8A24Ac8fbA59ebb328Ea2de5DccD19e7EDd450a5` |
| Oracle (KRWQ/frxUSD) | `0xB00D6E2a06a5bD8e624B2b0E0D4D391854431583` |
| OraclePoke | `0x455587b12e079bd1dAc1a16C7470df8F7Fbe69BC` |
| frxUSD Borrow Vault | `0x42BA0a943EDcc846333642d62F500894b199A798` |
| Collateral Vault (frxUSD/BRZ) | `0xB5587B4BE26608c7a6E6081B50C43AEBbA09E187` |
| Collateral Vault (tGBP/frxUSD) | `0xd8277Cbb6576085C192b9F920c5447aa5624a84B` |
| Collateral Vault (USDC/frxUSD) | `0x417E102f1d2BF2E52d0599Da14Fb79dDb4B0b89F` |
| Collateral Vault (IDRX/frxUSD) | `0x3371667cB5f6676fa14d95c3839da77705E46A39` |
| Collateral Vault (KRWQ/frxUSD) | `0x764Fb38Fe7519d2544BACBc8A495Cf64c0505b44` |
| Chainlink BRZ/USD feed | `0x0b0E64c05083FdF9ED7C5D3d8262c4216eFc9394` (raw aggregator — not an Euler adapter) |
| ChainlinkOracle adapter (BRZ) | `0x0c2bBe2DeaaE05f834196cd2Bb201b7357dE0ebe` |
| Collateral Vault (BRZ token) | `0x92f8b6bfC276E9A38545bE6517d3295593060D00` |

**Governor/deployer:** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448`

---

## Risk Parameters

| Parameter | Value |
|---|---|
| IRM | Base=0%, Kink(95%)=6% APY, Max=80% APY |
| IRM Constants | slope1=452541450, slope2=78136798523, kink=4080218930 |
| Borrow LTV (ICHI vaults) | 95% (9500) |
| Liquidation LTV (ICHI vaults) | 97% (9700) |
| Borrow LTV (BRZ token) | 85% (8500) |
| Liquidation LTV (BRZ token) | 90% (9000) |
| Max Liquidation Discount | 3% (300) |
| Liquidation Cool-Off | 1 second |
| Caps | Unlimited (0,0) — tighten before production |
| Fee Receiver | Not set — call `setFeeReceiver()` post-deploy |

**Rationale:** ICHI vault collaterals are 80-90% frxUSD underlying, so 95%/97% LTV is appropriate. Raw BRZ is an FX stablecoin pegged to BRL with more price volatility and a 24 h Chainlink heartbeat, so 85%/90% LTV is a conservative default — tighten before production.

---

## Oracle Architecture

The `ICHIVaultOracle` (in `ichi-oracle-kit/src/`) is a Euler `BaseAdapter` that prices ICHI vault shares using TWAP instead of spot:

1. Reads position liquidity from the ICHI vault (base + limit positions)
2. Fetches TWAP tick from the Algebra VolatilityOracle plugin
3. Recomputes token amounts using TWAP-derived sqrtPrice (not spot)
4. Adds idle vault balances (real, not spot-dependent)
5. Prices total vault value in the quote token (frxUSD), divides by totalSupply

One oracle per vault. Deployed via `ICHIVaultOracleFactory` (KRWQ deployed directly with relaxed maxStaleness). Two-layer router wiring:

1. `govSetConfig(ichiVault, frxUSD, oracle)` — prices ICHI shares in frxUSD
2. `govSetResolvedVault(collateralEVault, true)` — resolves eVault.asset() to the ICHI shares

The collateral eVaults ARE ERC-4626 (standard Euler eVaults wrapping ICHI shares). `govSetResolvedVault` is needed so Euler can look up the oracle when pricing collateral during `setLTV`.

---

## Keeper (OraclePoke)

The Algebra VolatilityOracle only writes timepoints on swaps. Exotic FX pairs may go hours without trades. The `OraclePoke` contract executes 1-wei dust swaps to trigger fresh timepoints.

- **On-chain:** `OraclePoke.sol` — `pokeStale()` iterates pools, pokes stale ones
- **Off-chain:** `keeper.ts` — viem-based cron bot, checks `getStalePoolIndices()`, calls `pokeStale()`
- **Threshold:** Poke if stale > 30 minutes. Oracle reverts if stale > 2 hours.
- **Cost:** Fractions of a cent per poke on Base

**Setup:** Seed the OraclePoke contract with frxUSD (0.1 frxUSD lasts effectively forever — each poke uses 1 wei). Run `keeper.ts` every 10 minutes via cron.

**Gas limit:** The `pokeStale()` call MUST use an explicit gas limit (500k+). Default gas estimation is too tight for the KRWQ pool's `beforeSwap` hook + community vault transfer, causing the swap to silently OOG inside the try/catch. The other 4 pools work with default gas, but use a high limit for all to be safe.

---

## Deployment Pipeline

7 Foundry scripts for the initial deploy, plus 1 add-on script for BRZ token collateral:

| Step | Script | What |
|---|---|---|
| 1 | `01_DeployIRM.s.sol` | Deploy KinkIRM via factory |
| 2 | `02_DeployRouter.s.sol` | Deploy EulerRouter (deployer=governor) |
| 3 | `03_DeployOracles.s.sol` | ICHIVaultOracleFactory + 5 ICHIVaultOracle adapters + OraclePoke + register pools |
| 4 | `04_DeployBorrowVault.s.sol` | frxUSD borrow vault (uoa=frxUSD) |
| 5 | `05_DeployCollateralVaults.s.sol` | 5 ICHI vault collateral eVaults |
| 6 | `06_WireRouter.s.sol` | 5x govSetConfig + 5x govSetResolvedVault |
| 7 | `07_ConfigureCluster.s.sol` | IRM, LTVs, caps, liquidation params |
| 8 | `08_AddBrzTokenCollateral.s.sol` | ChainlinkOracle adapter (BRZ/USD feed) + BRZ eVault + wire router + setLTV |

**Oracle adapter distinction:** Steps 3–6 use `ICHIVaultOracle` (TWAP-hardened, reads Algebra VolatilityOracle). Step 8 uses `ChainlinkOracle` (euler-price-oracle's push-based Chainlink adapter) wrapping the existing BRZ/USD aggregator feed.

Each script outputs addresses to add to `.env` for the next script.

---

## Key Files

| File | Purpose |
|---|---|
| `ichi-oracle-kit/src/ICHIVaultOracle.sol` | Core TWAP oracle adapter |
| `ichi-oracle-kit/src/ICHIVaultOracleFactory.sol` | Oracle deployment registry |
| `ichi-oracle-kit/src/keeper/OraclePoke.sol` | Keeper for oracle freshness |
| `ichi-oracle-kit/src/keeper/keeper.ts` | Off-chain cron bot |
| `ichi-oracle-kit/src/interfaces/IMinimal.sol` | Minimal ICHI/Algebra interfaces |
| `ichi-oracle-kit/src/lib/LiqAmounts.sol` | Inlined liquidity math |
| `script/Addresses.sol` | All Base addresses (Euler core, tokens, ICHI vaults) |
| `script/01-07_*.s.sol` | 7-step deployment pipeline |
| `script/FixKRWQOracle.s.sol` | Deployed relaxed KRWQ oracle (maxStaleness=1w) |
| `foundry.toml` | Forge config (solc 0.8.20, cancun EVM) |
| `remappings.txt` | Import path mappings |

---

## Frontend

**Repo:** `euler-lite-frax/` in AG-Euler workspace
**Labels:** `rootdraws/ag-euler-frax-labels` on GitHub
**Vercel:** `ag-euler-lite-frax` (to be created)

The frontend shows the cluster as a standard Euler lending market. ICHI vault shares appear as regular collateral tokens — the oracle handles pricing transparently. No custom frontend logic needed for ICHI specifics.
