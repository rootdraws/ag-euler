# Cork Protected Loop on Euler -- Implementation

## 1. Overview

### What We're Building

A lending market on Euler where:

- **Borrowers** deposit vbUSDC (REF) + cST as collateral, borrow sUSDe (CA)
- **Lenders** deposit sUSDe and earn yield from borrowers
- **Liquidation**: seize vbUSDC + cST → exercise in Cork → receive sUSDe → repay debt → lenders whole

### Why This Works

Cork's exercise mechanism: **vbUSDC + cST → sUSDe**. Even if the Agglayer bridge collapses and vbUSDC becomes worthless, the cST converts it to real sUSDe through the Cork pool. Lenders are always repaid in sUSDe.

### Why This Market Is Economically Backwards

Nobody would rationally borrow sUSDe (yield-bearing, ~10-20% APY) against vbUSDC (≈ USDC, 0% yield). You'd be paying to short yield. But this is the only Cork pool that exists today. The infrastructure we build here ports directly to economically sensible pools (sUSDe as REF / USDC as CA, or hgETH / wETH) once Cork creates them.

---

## 2. Known Addresses (Ethereum Mainnet)

| Asset | Address | Decimals |
|-------|---------|----------|
| vbUSDC (REF) | `0x53E82ABbb12638F09d9e624578ccB666217a765e` | 6 |
| sUSDe (CA) | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` | 18 |
| cST (Pool 1, symbol: vbUSDC4cST) | `0x1b42544f897b7ab236c111a4f800a54d94840688` | 18 |
| USDe | `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` | 18 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 |
| USD (unit of account) | `0x0000000000000000000000000000000000000348` | 18 |

| Cork Infra | Address |
|------------|---------|
| CorkPoolManager | `0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC` |
| Pool ID | `0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a` |
| SharesFactory | `0xcCCCccCCCcCc1782617fe14A386AC910a20D4324` |
| Morpho Oracle (sUSDe/vbUSDC) | `0x5D3159ba95dCdE02451a31fE68B08fB650b00458` |
| WrapperRateConsumer | `0x78FB656D01141E3AC2073c9372C8b3e636f49d01` |

| Euler Infra | Address |
|-------------|---------|
| EVC | `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` |
| eVaultFactory (GenericFactory) | `0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e` |
| eVaultImplementation | `0x8Ff1C814719096b61aBf00Bb46EAd0c9A529Dd7D` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| protocolConfig | `0x4cD6BF1D183264c02Be7748Cb5cd3A47d013351b` |
| sequenceRegistry | `0xEADDD21618ad5Deb412D3fD23580FD461c106B54` |
| USDe/USD Oracle (ChainlinkInfrequentOracle) | `0x93840A424aBc32549809Dd0Bc07cEb56E137221C` |

| Cork Pool Parameters | Value |
|----------------------|-------|
| rateMin | 0.7607 (1 vbUSDC = 0.76 sUSDe minimum) |
| rateMax | 0.8224 (1 vbUSDC = 0.82 sUSDe maximum) |
| Current swap rate | 0.8187 (1 vbUSDC = 0.8187 sUSDe) |
| Expiry | April 19, 2026 (unix: 1776686400) |
| Pool depth | ~4.1M sUSDe collateral, ~4.1M cST outstanding |

---

## 3. Oracle Design

### 3.1 cST Oracle: Always Returns Zero (per spec)

cST has real market value (inverse of REF depeg risk) but is priced at zero in Euler. The hook enforces 1:1 cST/REF pairing on borrow, and the vault overrides enforce it on all collateral movements, so cST coverage is guaranteed for every account with debt. Pricing cST at zero avoids double-counting.

**Contract: CSTZeroOracle** ✅ BUILT — `cork-contracts/src/oracle/CSTZeroOracle.sol` (compiles)

Source: Extends `BaseAdapter` from `euler-price-oracle` (lib dependency).
Cannot use `FixedRateOracle` because its constructor reverts on `rate == 0`.

**EulerRouter wiring:** `govSetResolvedVault(cSTVault, true)` + `govSetConfig(cST, USD, cstZeroOracle)`.
The router resolves `cSTVault → cST` via `convertToAssets`, then hits the zero oracle for `cST/USD`.

```solidity
contract CSTZeroOracle is BaseAdapter {
    string public constant name = "CSTZeroOracle";
    address public immutable base;
    address public immutable quote;

    constructor(address _base, address _quote) {
        base = _base;
        quote = _quote;
    }

    function _getQuote(uint256, address _base, address _quote) internal view override returns (uint256) {
        require(
            (_base == base && _quote == quote) || (_base == quote && _quote == base),
            "CSTZeroOracle: unsupported pair"
        );
        return 0;
    }
}
```

Deploy: `base = 0x1b42544f897b7ab236c111a4f800a54d94840688` (cST), `quote = 0x0000000000000000000000000000000000000348` (USD).

### 3.2 vbUSDC Oracle: Standard BaseAdapter

**Contract: CorkOracleImpl** — `cork-contracts/src/oracle/CorkOracleImpl.sol` (compiles)

A standard `BaseAdapter` that prices vbUSDC in USD. The EulerRouter resolves `vbUSDCVault → vbUSDC` via `convertToAssets` (1:1), then calls `CorkOracleImpl._getQuote(inAmount, vbUSDC, USD)` with real share amounts.

There is no per-account logic, no `CorkCustomRiskManagerOracle`, and no `balanceOf` encoding trick. The original Euler POC used a two-layer architecture with account-encoding in `balanceOf` that was incompatible with Euler's liquidation module (see `firstprinciples.md` FP-1). That architecture was removed entirely.

**Pricing formula** (unit of account = USD):
```
CA_backed_USD = swapRate * P_sUSDe_USD * (1 - fee) * H_pool
P_RA_effective_USD = min(P_vbUSDC_nav_USD, CA_backed_USD)
```

**Inputs:**

- **`P_RA_Nav`**: vbUSDC wraps USDC 1:1. NAV in USD ≈ 1.0. Hardcoded as `1e18`.
- **`P_sUSDe_USD`**: sUSDe price in USD. Read from `IPriceOracle(sUsdePriceOracle).getQuote(1e18, sUsdeToken, quote)` where `sUsdePriceOracle` = the EulerRouter address. The router resolves sUSDe via `resolvedVault` (ERC4626 → USDe) + USDe/USD Chainlink adapter. No circularity: vbUSDC/USD and sUSDe/USD are independent resolution paths.
- **`swapRate`**: Cork's `swapRate(poolId)` gives vbUSDC→sUSDe exercise rate (currently `0.8187e18`).
- **`fee`**: Read from `CorkPoolManager.swapFee(poolId)` on-chain. Current value: `5e16` = 0.05% = 5 bps. Format: `1e18 = 1% = 100 bps`.
- **`H_pool`**: Governance-settable impairment factor. `1e18` = no impairment. `0` = fully impaired → all positions liquidatable.

**Constructor** (8 params):
```
CorkOracleImpl(corkPoolManager, poolId, base=vbUSDC, quote=USD, sUsdeToken, sUsdePriceOracle=routerAddress, hPool=1e18, governor)
```

**Implementation** (see actual file at `cork-contracts/src/oracle/CorkOracleImpl.sol`):

```solidity
contract CorkOracleImpl is BaseAdapter {
    string public constant name = "CorkOracleImpl";
    // ... (immutables: base, quote, CORK_POOL_MANAGER, POOL_ID, sUsdeToken, sUsdePriceOracle)
    // ... (state: hPool, governor)

    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        if (!(_base == base && _quote == quote)) revert Errors.PriceOracle_NotSupported(_base, _quote);
        if (inAmount == 0) return 0;

        uint256 swapRateWad = ICorkPoolManager(CORK_POOL_MANAGER).swapRate(POOL_ID);
        if (swapRateWad == 0) return 0;

        uint256 feeBps = ICorkPoolManager(CORK_POOL_MANAGER).swapFee(POOL_ID);
        uint256 sUsdeUsd = IPriceOracle(sUsdePriceOracle).getQuote(1e18, sUsdeToken, quote);

        uint256 caBackedUsd = swapRateWad * sUsdeUsd / 1e18;
        uint256 feeFractionWad = feeBps * 1e16 / 1e18;
        caBackedUsd = caBackedUsd * (1e18 - feeFractionWad) / 1e18;
        caBackedUsd = caBackedUsd * hPool / 1e18;

        uint256 navUsd = 1e18;
        uint256 effectiveUsdPerToken = navUsd < caBackedUsd ? navUsd : caBackedUsd;

        return inAmount * effectiveUsdPerToken / 1e6;
    }
}
```

**Decimal note:** `inAmount` is in native vbUSDC decimals (6). `effectiveUsdPerToken` is USD per 1 full token (1e6 units) in 18-decimal WAD. Return is `inAmount * effectiveUsdPerToken / 1e6` → 18-decimal USD. The original spec had `/ 1e18` which was wrong.

**Fee math verified on-chain:**
- `swapFee(poolId)` = `5e16` (5 bps, 0.05%). Cork scale: `1e18 = 1% = 100 bps`. Confirmed via `MathHelper.calculatePercentageFee` which divides by `100e18`.
- `swapRate(poolId)` = `0.8187e18`
- sUSDe/USD ≈ `1.15e18` (sUSDe accrues yield above $1)
- CA-backed value ≈ `0.8187 * 1.15 * 0.9995 * 1.0` ≈ `$0.94` per vbUSDC token
- NAV ≈ `$1.00` per vbUSDC token
- `min(1.00, 0.94)` = `$0.94` → CA-backed value dominates
- 100 vbUSDC (= 100e6 raw) → oracle returns `100e6 * 0.94e18 / 1e6 = 94e18` (= $94 in 18-dec USD) ✓

**sUSDe oracle for EulerRouter:** Use the same pattern as the Yield cluster. sUSDe is an ERC4626 vault holding USDe. The Yield cluster prices it via `"ExternalVault|0x93840A424aBc32549809Dd0Bc07cEb56E137221C"` (sUSDe exchange rate × USDe/USD Chainlink). We configure the same in our router.

### 3.3 EulerRouter Configuration

Unit of account = USD (`0x0000000000000000000000000000000000000348`). All oracle pairs quote against USD.

The EulerRouter resolves asset pair → oracle. Configure:

```solidity
address USD    = address(0x0000000000000000000000000000000000000348);
address sUSDe  = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
address USDe   = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
address vbUSDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
address cST    = 0x1B42544F897B7Ab236C111A4f800A54D94840688; // EIP-55 checksummed

// vbUSDCVault and cSTVault MUST be set as resolvedVaults.
// The EVK risk manager calls oracle.getQuote(balanceOf(account), collateralVault, USD).
// The router resolves collateralVault → collateralToken via convertToAssets, then calls
// the token-level oracle. Without this, the oracle is never reached.

// 1. vbUSDCVault → vbUSDC (1:1 since non-yield-bearing)
router.govSetResolvedVault(vbUSDCVault, true);
// 2. vbUSDC/USD → CorkOracleImpl (standard BaseAdapter)
router.govSetConfig(vbUSDC, USD, address(corkOracleImpl));

// 3. cSTVault → cST
router.govSetResolvedVault(cSTVault, true);
// 4. cST/USD → CSTZeroOracle (always returns 0)
router.govSetConfig(cST, USD, address(cstZeroOracle));

// 5. sUSDe/USD → resolved via ERC4626 convertToAssets (sUSDe→USDe) then USDe/USD oracle
router.govSetResolvedVault(sUSDe, true);                // sUSDe is ERC4626 wrapping USDe
router.govSetConfig(USDe, USD, address(usdeUsdOracle)); // USDe/USD Chainlink adapter
```

**sUSDe pricing chain:** When Euler asks "what is X sUSDe worth in USD?", the router:
1. Sees sUSDe is a `resolvedVault` → calls `sUSDe.convertToAssets(X)` → gets Y USDe
2. Recurses with (Y, USDe, USD) → finds the USDe/USD oracle → returns USD value

This is the same pattern the Yield cluster uses. The USDe/USD oracle at `0x93840A424aBc32549809Dd0Bc07cEb56E137221C` is a standalone `ChainlinkInfrequentOracle` (base=USDe, quote=USD). Verified on-chain: returns ~$0.999/USDe. Directly reusable -- no deployment needed.

**USDe address:** `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` (Ethena USDe, 18 decimals).

---

## 4. Custom Vaults: ERC4626EVCCollateralCork

Source: `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` (compiles).

**Inheritance chain:**
```
ERC4626EVCCollateralCork
  → ERC4626EVCCollateralCapped(admin)         // supply caps, governor, reentrancy, snapshots
    → ERC4626EVCCollateral                     // collateral-only ERC4626
      → ERC4626EVC(evc, permit2, asset, name, symbol)  // EVC-aware ERC4626 base
```

**Purpose:** Collateral-only vault with pairing invariants enforced on every withdraw, redeem, and deposit. `balanceOf` returns real shares to all callers (no encoding trick -- see `firstprinciples.md` FP-1 for why the original POC's encoding was removed).

**Constructor** (8 params):
```solidity
constructor(
    address evc,
    address permit2,
    address admin,
    address _borrowVault,    // sUSDe borrow vault (for debtOf checks)
    address asset,           // vbUSDC or cST
    string memory _name,
    string memory _symbol,
    bool _isRefVault         // true for vbUSDC, false for cST
) ERC4626EVC(evc, permit2, asset, _name, _symbol) ERC4626EVCCollateralCapped(admin)
```

**Overrides:**
1. **`_withdraw`** — enforces the pairing invariant from cork-euler.md Section 3.2 for both vault types and both debt states:
   - cST vault (`isRefVault=false`): `HasDebt()` if any debt. Without debt: `WithdrawalBreaksPairing()` if `post_withdrawal_cST < REF * 1e12`.
   - vbUSDC vault (`isRefVault=true`): `NoPairedCoverage()` if `post_withdrawal_REF > 0` AND `cST < post_withdrawal_REF * 1e12`. Allows full exit (REF → 0). Works for both debt and no-debt.
2. **`_deposit`** — blocks REF vault deposits that would push REF above cST coverage when debt > 0. Reverts `DepositWouldBreakPairing()`. cST deposits are never restricted.
3. **`_updateCache() {}`** — empty override required by abstract parent. Cork vault has no per-address-prefix cache.

**`pairedVault` + `setPairedVault(address)`** — governor call. BOTH vaults need this set post-deploy:
- vbUSDC vault: `setPairedVault(cSTVault)` — used by `_withdraw` and `_deposit` to check cST coverage
- cST vault: `setPairedVault(vbUSDCVault)` — used by `_withdraw` no-debt case to check remaining REF
Deployment script Phase 5 handles both.

**`_balanceOf` helper** — reads the paired vault's real share balance via staticcall. Used by `_withdraw` and `_deposit` to query the counterpart vault.

**Deploy two instances:**

1. vbUSDC vault: `asset = 0x53E82ABbb12638F09d9e624578ccB666217a765e`, `borrowVault = sUSDe borrow vault address`, `isRefVault = true`
2. cST vault: `asset = 0x1b42544f897b7ab236c111a4f800a54d94840688`, `borrowVault = sUSDe borrow vault address`, `isRefVault = false`

Both need: `evc = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383`, `permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3`, `admin = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448` (deployer/governor).

**Deployment order:** Deploy the sUSDe borrow vault (standard EVK) FIRST to get its address. Then deploy both `ERC4626EVCCollateralCork` instances with `borrowVault = sUSDe vault address`. This resolves the chicken-and-egg.

---

## 5. ProtectedLoopHook

Source: `cork-contracts/src/hook/ProtectedLoopHook.sol` (compiles).

### 5.1 Purpose

Enforces: **you cannot borrow sUSDe unless you hold matched vbUSDC + cST.** This hook is attached ONLY to the sUSDe borrow vault (`OP_BORROW = 64`). Collateral vault protections (withdraw/deposit pairing) are handled by `_withdraw`/`_deposit` overrides in `ERC4626EVCCollateralCork` (Section 4).

### 5.2 How Euler Hooks Work

From `euler-vault-kit/src/EVault/shared/Base.sol`:

```solidity
function invokeHookTarget(address caller) private {
    address hookTarget = vaultStorage.hookTarget;
    if (hookTarget == address(0)) revert E_OperationDisabled();
    (bool success, bytes memory data) = hookTarget.call(
        abi.encodePacked(msg.data, caller)
    );
    if (!success) RevertBytes.revertBytes(data);
}
```

The vault forwards original calldata + 20 bytes of caller address. Hook's `fallback()` receives this. Revert = block the operation.

Hook fires **before** the operation executes (`initOperation` in Base.sol). `balanceOf` reflects pre-operation state.

### 5.3 Base Contract: `BaseHookTarget`

Source: `cork-contracts/lib/evk-periphery/src/HookTarget/BaseHookTarget.sol` (42 lines).

Provides:
- `constructor(address _eVaultFactory)` -- stores the EVault factory
- `isHookTarget()` -- returns magic `0x87439e04` only if caller is a vault deployed by the factory
- `_msgSender()` -- extracts the original caller from the last 20 bytes of calldata

### 5.4 Hook Attachment

| Vault | Hooked Operations | hookedOps value |
|-------|-------------------|-----------------|
| sUSDe borrow vault | `OP_BORROW` | `64` |

Collateral vaults do not use the hook. Their protections are in the vault contract overrides (Section 4).

### 5.5 Borrow Invariant

On borrow (`msg.sender == borrowVault`):
- Account must have vbUSDC vault shares > 0
- Account must have cST vault shares > 0
- `cstShares >= refShares * 1e12` (1:1 token parity after decimal normalization)
- cST must not be expired (`block.timestamp >= cstExpiry` → revert)

```solidity
fallback() external {
    if (msg.sender == borrowVault) {
        _checkBorrow(_msgSender());
    }
}

function _checkBorrow(address account) internal view {
    uint256 refShares = IERC4626(refVault).balanceOf(account);
    uint256 cstShares = IERC4626(cstVault).balanceOf(account);

    if (refShares == 0) revert NoREFCollateral();
    if (cstShares == 0) revert NoCSTCollateral();
    if (!_normalizedEqual(refShares, cstShares)) revert REFCSTMismatch();
    if (block.timestamp >= cstExpiry) revert CSTExpired();
}

function _normalizedEqual(uint256 refShares, uint256 cstShares) internal pure returns (bool) {
    return cstShares >= refShares * 1e12;
}
```

---

## 6. Liquidation: CorkProtectedLoopLiquidator

Source: `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol` (compiles).
Reference implementation: `SBuidlLiquidator` at `cork-contracts/lib/evk-periphery/src/Liquidator/SBLiquidator.sol`.

The `CustomLiquidatorBase` pattern:
- Owner registers which collateral vaults need custom liquidation logic
- `liquidate()` checks if the collateral vault is custom; if so, delegates to `_customLiquidation()`
- Liquidators enable the contract as an EVC operator

**Enforcement:** `_customLiquidation` reverts `LiquidateViaRefVaultOnly()` if called with `collateral != refVault`. The cST seizure is handled internally.

**Flow (inside EVC batch):**
1. Account falls below LLTV (85% for vbUSDC/sUSDe)
2. Bot calls `liquidator.liquidate(receiver, sUsdeVault, violator, vbUSDCVault, repay, minYield)`
3. Phase A: Seize vbUSDC shares via `IEVault(liability).liquidate(violator, refVault, repayAssets, minYieldBalance)`
4. Phase A: Seize cST shares via `IEVault(liability).liquidate(violator, cstVault, type(uint256).max, 0)`
5. Phase B: Pull debt to operator via `evc.call(liability, _msgSender(), 0, pullDebt(max, address(this)))`
6. Phase C: Redeem vault shares for underlying tokens (vbUSDC + cST)
7. Phase C: Approve tokens to CorkPoolManager, call `exercise(poolId, cstAmount, address(this))` → receive sUSDe
8. Phase C: Transfer leftover vbUSDC to receiver via `safeTransfer`
9. Transfer all sUSDe to receiver via `safeTransfer`
10. **Bot repays debt in the same EVC batch** using the sUSDe received

Debt repayment is the bot's responsibility, not the contract's. After `_customLiquidation` returns, `CustomLiquidatorBase.liquidate()` calls `liabilityVault.disableController()`. The bot must include a `repay` call in the same EVC batch. This matches the `SBLiquidator` pattern.

Uses `SafeERC20.safeTransfer` for all token transfers.

**Cork exercise functions** (from `phoenix/contracts/interfaces/IPoolManager.sol`):

```solidity
function exercise(MarketId poolId, uint256 cstSharesIn, address receiver)
    external returns (uint256 collateralAssetsOut, uint256 referenceAssetsIn, uint256 fee);

function previewExercise(MarketId poolId, uint256 cstSharesIn)
    external view returns (uint256 collateralAssetsOut, uint256 referenceAssetsIn, uint256 fee);
```

CorkPoolManager: `0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC`
Pool ID: `0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a`

**Whitelist requirement:** The liquidator contract address must be whitelisted on the Cork pool before it can exercise seized collateral. Cork governance calls `WhitelistManager.addToMarketWhitelist(poolId, address)`. Coordinate with Cork team at deployment time.

**Flash liquidity:** Not needed. The oracle and Cork exercise share the same `swapRate` parameter, so at any liquidation trigger point the exercise returns enough sUSDe to cover the debt with margin.

---

## 7. Rollover

**Not needed for demo (cST expires April 19, 2026). Needed for production.**

When cST approaches expiry, a RolloverOperator must swap cST_old for cST_new within an EVC batch. The hook allows temporary collateral movements for the operator, and EVC's end-of-batch check enforces invariants.

**TBD:** Operator contract, keeper setup, RolloverVendingManager integration.

---

## 8. Cluster Configuration

All values confirmed for demo deployment:

| Parameter | Value | Notes |
|-----------|-------|-------|
| Unit of account | USD (`0x0000000000000000000000000000000000000348`) | Matches mainnet convention. 18 decimals (ISO 4217 code 840). |
| vbUSDC borrow LTV | 80% | Yield-bearing debt vs stable collateral = LTV degrades over time. Conservative. |
| vbUSDC liquidation LTV | 85% | 5% buffer above borrow LTV |
| cST borrow LTV | 0% | Zero-valued oracle |
| cST liquidation LTV | 0% | Zero-valued oracle |
| sUSDe supply cap | 1,000,000 | 1M sUSDe |
| vbUSDC supply cap | 1,000,000 | 1M vbUSDC |
| cST supply cap | 1,000,000 | 1M cST |
| sUSDe borrow cap | 800,000 | 800k sUSDe |
| IRM base rate | 0% | 0 at zero utilization |
| IRM kink | 80% | Target utilization |
| IRM slope1 | 5% | ~4% at kink (0 + 80% * 5% = 4%) |
| IRM slope2 | 200% | Steep above kink to discourage over-borrowing |
| Governor | `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` | Deployer EOA. Transfer to multisig post-demo via `setGovernorAdmin` / `transferGovernance`. |

---

## 9. Deployment Sequence

**Phase 1: Oracle Router (deploy first -- CorkOracleImpl needs its address)**
1. USDe/USD Chainlink adapter: **confirmed reusable** at `0x93840A424aBc32549809Dd0Bc07cEb56E137221C` (name: `ChainlinkInfrequentOracle`, base=USDe, quote=USD, returns ~$0.999/USDe)
2. Deploy `EulerRouter` (governor = deployer EOA) → get router address

**Phase 2: Oracles**
3. Deploy `CorkOracleImpl` (standard BaseAdapter, constructor: corkPoolManager, poolId, base=vbUSDC, quote=USD, sUsdeToken, sUsdePriceOracle=**router address from step 2**, hPool=1e18, governor)
4. Deploy `CSTZeroOracle` (base=cST `0x1b42...`, quote=USD `0x...0348`)

**Phase 3: Vaults (order matters)**
5. Deploy sUSDe borrow vault (standard EVK via factory) → get its address
6. Deploy `ERC4626EVCCollateralCork` for vbUSDC (borrowVault = step 5 address, isRefVault = true)
7. Deploy `ERC4626EVCCollateralCork` for cST (borrowVault = step 5 address, isRefVault = false)

**Phase 4: Wire Oracle Router**

Collateral vaults must be set as `resolvedVault` so the router can resolve vault shares to underlying tokens via `convertToAssets` before hitting the token-level oracle.

8a. `router.govSetResolvedVault(vbUSDCVault, true)` → vbUSDCVault resolves to vbUSDC (1:1)
8b. `router.govSetConfig(vbUSDC, USD, address(corkOracleImpl))` → CorkOracleImpl (standard BaseAdapter)
9a. `router.govSetResolvedVault(cSTVault, true)` → cSTVault resolves to cST
9b. `router.govSetConfig(cST, USD, address(cstZeroOracle))` → CSTZeroOracle
10. `router.govSetResolvedVault(sUSDe, true)` → sUSDe is ERC4626 wrapping USDe
11. `router.govSetConfig(USDe, USD, 0x93840A424aBc32549809Dd0Bc07cEb56E137221C)` → USDe/USD Chainlink adapter

**Phase 5: Hook + Pairing**
12. Deploy `ProtectedLoopHook` (eVaultFactory, evc, refVault=step 6, cstVault=step 7, borrowVault=step 5, cstToken, cstExpiry=1776686400)
13. `sUSDeBorrowVault.setHookConfig(hookAddress, 64)` → OP_BORROW only
14. `vbUSDCVault.setPairedVault(cSTVault)` → REF vault pairing wired
15. `cSTVault.setPairedVault(vbUSDCVault)` → cST vault pairing wired

Collateral vault withdraw/deposit protections are handled by `_withdraw`/`_deposit` overrides in the vault contract, not by the hook.

**Phase 6: Cluster Config**
16. Deploy IRM, set on borrow vault
17. Set LTVs for vbUSDC→sUSDe (80% borrow / 85% liquidation) and cST→sUSDe (0%)
18. Set supply caps, borrow caps, liquidation discount, cool-off time, interest fee

**Phase 7: Liquidator**
19. Deploy `CorkProtectedLoopLiquidator` (evc, owner, corkPoolManager, poolId, refVault, cstVault, vbUSDC, cstToken, sUsdeToken)

**Phase 8: Frontend**
20. Update cork-labels (`products.json`, `vaults.json`, `entities.json`)
21. Push to GitHub, verify on `cork.alphagrowth.fun`

---

## 10. Acquiring Test Assets

### vbUSDC
Deposit USDC into Cork's vbUSDC vault. Standard ERC4626, unlimited deposits, 1:1 conversion.

```bash
# Approve USDC
cast send 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  "approve(address,uint256)" \
  0x53E82ABbb12638F09d9e624578ccB666217a765e \
  <amount_6dec> \
  --rpc-url $RPC --private-key $PK

# Deposit USDC → vbUSDC (1:1)
cast send 0x53E82ABbb12638F09d9e624578ccB666217a765e \
  "deposit(uint256,address)" \
  <amount_6dec> <your_address> \
  --rpc-url $RPC --private-key $PK
```

### cST
Deposit sUSDe into Cork pool via CorkPoolManager.mint or CorkAdapter.safeMint. Returns cPT + cST.

**Confirmed: ALL CorkPoolManager functions are whitelisted.** `deposit`, `mint`, `exercise`, `exerciseOther`, `swap`, `withdraw`, `redeem` -- every external function goes through `_onlyWhitelisted(poolId, _msgSender())` via `WhitelistManager`. The deployer EOA and liquidator contract both need Cork team to call `WhitelistManager.whitelist(poolId, address)` before any pool interaction.

CorkAdapter (`phoenix/contracts/periphery/CorkAdapter.sol`) provides `safeMint` as a convenience wrapper but also routes through the pool manager.

### sUSDe
Acquire sUSDe via Ethena or DEX swap.

---

## 11. Source Files Reference

All Cork contracts live in `cork-contracts/` -- a standalone Foundry project. Upstream dependencies are in `cork-contracts/lib/`.

| Component | File | Status |
|-----------|------|--------|
| CorkOracleImpl (standard BaseAdapter) | `cork-contracts/src/oracle/CorkOracleImpl.sol` | ✅ Compiles |
| CSTZeroOracle | `cork-contracts/src/oracle/CSTZeroOracle.sol` | ✅ Compiles |
| ERC4626EVCCollateralCork | `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` | ✅ Pairing overrides, compiles |
| ProtectedLoopHook | `cork-contracts/src/hook/ProtectedLoopHook.sol` | ✅ Borrow-only, compiles |
| CorkProtectedLoopLiquidator | `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol` | ✅ SafeERC20, compiles |
| CorkProtectedLoop deployment script | `cork-contracts/script/CorkProtectedLoop.s.sol` | ✅ Compiles |
| BaseAdapter (oracle base) | `cork-contracts/lib/euler-price-oracle/src/adapter/BaseAdapter.sol` | Lib dep |
| EulerRouter | `cork-contracts/lib/euler-price-oracle/src/EulerRouter.sol` | Lib dep |
| IPriceOracle | `cork-contracts/lib/euler-price-oracle/src/interfaces/IPriceOracle.sol` | Lib dep |
| BaseHookTarget | `cork-contracts/lib/evk-periphery/src/HookTarget/BaseHookTarget.sol` | Lib dep |
| CustomLiquidatorBase (liquidator template) | `cork-contracts/lib/evk-periphery/src/Liquidator/CustomLiquidatorBase.sol` | Lib dep |
| SBuidlLiquidator (reference impl) | `cork-contracts/lib/evk-periphery/src/Liquidator/SBLiquidator.sol` | Lib dep (reference) |
| ERC4626EVCCollateralCapped (vault parent) | `cork-contracts/lib/evk-periphery/src/Vault/implementation/ERC4626EVCCollateralCapped.sol` | Lib dep |
| EVault hook invocation | `cork-contracts/lib/evk-periphery/lib/euler-vault-kit/src/EVault/shared/Base.sol` | Lib dep |
| OP constants | `cork-contracts/lib/evk-periphery/lib/euler-vault-kit/src/EVault/shared/Constants.sol` | Lib dep |
| IEthereumVaultConnector (EVC interface) | `cork-contracts/lib/evk-periphery/lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol` | Lib dep |
| IRMLinearKink (interest rate model) | `cork-contracts/lib/evk-periphery/lib/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol` | Lib dep |
| CorkPoolManager | `phoenix/contracts/core/CorkPoolManager.sol` | Exists (Cork repo) |
| MathHelper (swap math) | `phoenix/contracts/libraries/MathHelper.sol` | Exists (Cork repo) |
| IPoolShare (cST interface) | `phoenix/contracts/interfaces/IPoolShare.sol` | Exists |
| IPoolManager (exercise, swapRate, swapFee) | `phoenix/contracts/interfaces/IPoolManager.sol` | Exists |
| WhitelistManager | `phoenix/contracts/core/WhitelistManager.sol` | Exists |
| Cork spec | `cork-docs/cork-euler.md` | Exists |
