# Cork Protected Loop — TODO

Resolved design decisions and spec corrections are documented in `implementation.md`. This file tracks only: what must still be done, and how to do it.

---

## Pre-flight

- [ ] **Contact Cork team** — request whitelist additions BEFORE deploying. Two addresses needed:
  - Deployer EOA `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` — to acquire test cST via mint
  - `CorkProtectedLoopLiquidator` contract address — to call `exercise()` during liquidation
  - Cork calls: `WhitelistManager.addToMarketWhitelist(0xab4988...702a, <address>)`

## Deployment Runbook

Execute in order. Capture every deployed address — later steps depend on earlier ones.

### Step 1 — Deploy Oracle Contracts

**1a. Deploy `CorkOracleImpl`**

Constructor args — see `implementation.md` Section 3.2 for full context:
```
corkPoolManager  = 0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC
poolId           = 0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a
base             = 0x53E82ABbb12638F09d9e624578ccB666217a765e  (vbUSDC)
quote            = 0x0000000000000000000000000000000000000348  (USD)
sUsdeToken       = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
sUsdePriceOracle = <EulerRouter address — deploy router first>
hPool            = 1000000000000000000
governor         = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448
```

Note: `sUsdePriceOracle` = EulerRouter address. Deploy router first (main script Phase 1), then deploy this.

- [ ] Deploy → capture `CORK_ORACLE_IMPL=0x...`

**1b. Deploy `CSTZeroOracle`**
```
_base  = 0x1B42544F897B7Ab236C111A4f800A54D94840688
_quote = 0x0000000000000000000000000000000000000348
```
- [ ] Deploy → capture `CST_ZERO_ORACLE=0x...`

---

### Step 2 — Deploy Collateral Vaults

**2a. Deploy sUSDe borrow vault** via `GenericFactory.createProxy`:
```bash
cast send 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e \
  "createProxy(address,bool,bytes)" \
  0x0000000000000000000000000000000000000000 \
  true \
  $(cast abi-encode "f(address,address,address)" \
    0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 \
    <EULER_ROUTER_ADDRESS> \
    0x0000000000000000000000000000000000000348) \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
- [ ] Capture `SUSDE_BORROW_VAULT=0x...`

**2b. Deploy vbUSDC collateral vault** (`ERC4626EVCCollateralCork`):
```
evc        = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383
permit2    = 0x000000000022D473030F116dDEE9F6B43aC78BA3
admin      = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448
borrowVault = <SUSDE_BORROW_VAULT from 2a>
asset       = 0x53E82ABbb12638F09d9e624578ccB666217a765e
name        = "Euler Collateral: vbUSDC"
symbol      = "ecvbUSDC"
isRefVault  = true
```
- [ ] Deploy → capture `VBUSDC_VAULT=0x...`

**2c. Deploy cST collateral vault** (`ERC4626EVCCollateralCork`):
```
evc        = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383
permit2    = 0x000000000022D473030F116dDEE9F6B43aC78BA3
admin      = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448
borrowVault = <SUSDE_BORROW_VAULT from 2a>
asset       = 0x1B42544F897B7Ab236C111A4f800A54D94840688
name        = "Euler Collateral: vbUSDC4cST"
symbol      = "eccST"
isRefVault  = false
```
- [ ] Deploy → capture `CST_VAULT=0x...`

---

### Step 3 — Deploy Hook and Liquidator

**3a. Deploy `ProtectedLoopHook`:**
```
eVaultFactory = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e
evc           = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383
refVault      = <VBUSDC_VAULT>
cstVault      = <CST_VAULT>
borrowVault   = <SUSDE_BORROW_VAULT>
cstToken      = 0x1B42544F897B7Ab236C111A4f800A54D94840688
cstExpiry     = 1776686400
```
- [ ] Deploy → capture `PROTECTED_LOOP_HOOK=0x...`

**3b. Deploy `CorkProtectedLoopLiquidator`:**
```
evc             = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383
owner           = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448
corkPoolManager = 0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC
poolId          = 0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a
refVault        = <VBUSDC_VAULT>
cstVault        = <CST_VAULT>
vbUSDC          = 0x53E82ABbb12638F09d9e624578ccB666217a765e
cstToken        = 0x1B42544F897B7Ab236C111A4f800A54D94840688
sUsdeToken      = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
```
- [ ] Deploy → capture `CORK_LIQUIDATOR=0x...`
- [ ] **Send liquidator address to Cork team** for whitelist

---

### Step 4 — Run Main Deployment Script

```bash
cd cork-contracts

# Fill in deployed addresses in .env, then:
source .env && forge script script/CorkProtectedLoop.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

Handles: EulerRouter, all oracle wiring (`govSetResolvedVault` + `govSetConfig`), LTVs, IRM, caps, hook attachment on borrow vault, both `setPairedVault` calls.

- [ ] Script runs successfully
- [ ] All transactions confirmed on-chain

---

### Step 5 — Post-deployment

- [ ] **Verify contracts on Etherscan** — confirm all 7 contracts verified
- [ ] **Acquire test assets:**
  - vbUSDC: approve USDC → deposit into Cork's vbUSDC vault (1:1)
  - sUSDe: buy via Ethena or DEX
  - cST: `CorkPoolManager.mint()` — **requires Cork whitelist first**
- [ ] **Update cork-euler-labels** — `1/products.json`, `1/vaults.json`, `1/entities.json` with deployed addresses, push to `alphagrowth/cork-euler-labels`
- [ ] **Verify on cork.alphagrowth.fun** — cluster appears, vaults load, deposit/borrow UI works
- [ ] **Test borrow** — deposit vbUSDC + cST, borrow sUSDe, confirm hook enforces pairing
- [ ] **Test liquidation** — create unhealthy position, confirm liquidator end-to-end

---

## Spec Gaps — Blocked on Cork Team

Require `CorkSeriesRegistry` which Cork has not deployed.

- [ ] **H_pool auto-reduction near expiry** (cork-euler.md §2.3): Oracle should reduce `hPool → 0` if no valid successor cST exists within `liqWindow`. **Mitigation:** governor manually calls `CorkOracleImpl.setHPool(0)` before expiry.
- [ ] **Borrow restriction within `liqWindow`** (cork-euler.md §3.1): Hook should block new borrows near expiry without successor cST. Same dependency.
- [ ] **Rollover exception in hook** (cork-euler.md §3.3): `RolloverOperator` temporarily moves cST within EVC batch. Not needed until April 19, 2026.

---

## Post-deployment Monitoring

- [ ] **Rollover operator**: Keeper for cST_old → cST_new before expiry. Must be operational before April 19, 2026.
- [ ] **hPool governance**: If Cork pool impaired, call `CorkOracleImpl.setHPool(value)` to reduce collateral value.
- [ ] **Governor transfer**: After demo stable, transfer from deployer EOA to multisig via `setGovernorAdmin` (borrow vault) and `transferGovernance` (router).