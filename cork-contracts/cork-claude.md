## Cork Smart Contracts — Protected Loop on Euler

### The Spec

Read `implementation.md` in the repo root FIRST. It is the complete implementation spec with all addresses, formulas, corrected code, and deployment sequence. Read `cork-docs/cork-euler.md` for the original Cork/Euler design spec. Read `TODO.md` for deployment runbook and remaining work. Read `firstprinciples.md` for the FP-1 investigation (balanceOf encoding trick — confirmed broken, resolved).

### Current Status: All Contracts Deployed to Mainnet ✓

Do NOT rewrite these. Read the existing files before touching anything.

All contracts live in `cork-contracts/` -- a standalone Foundry project with only the deps Cork needs.

| Contract | File | Mainnet Address |
|---|---|---|
| CorkOracleImpl | `cork-contracts/src/oracle/CorkOracleImpl.sol` | `0xF9d813db87F528bb5b5Ae28567702488f8Bd34FC` |
| CSTZeroOracle | `cork-contracts/src/oracle/CSTZeroOracle.sol` | `0x81FfF8C68e6ea10d782d738a3C71110F876C3C06` |
| ERC4626EVCCollateralCork (vbUSDC) | `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` | `0xadF7aFDAdaA4cBb0aDAf47C7fD7a9789C0128C6b` |
| ERC4626EVCCollateralCork (cST) | `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` | `0xd0f8aC1782d5B80f722bd6aCA4dEf8571A9ddA4c` |
| ProtectedLoopHook | `cork-contracts/src/hook/ProtectedLoopHook.sol` | `0x677c2b56E21dDD0851242e62024D8905907db72c` |
| CorkProtectedLoopLiquidator | `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol` | `0x1e95cC20ad3917ee523c677faa7AB3467f885CFe` |
| EulerRouter | (lib dep, deployed) | `0x693B992a576F1260fbD9392389262c2d6D357C3c` |
| IRMLinearKink | (lib dep, deployed) | `0x09f8E395c9845A3B5007DB154920bB28727246a3` |
| sUSDe Borrow Vault | (EVK factory, deployed) | `0x53FDab35Fd3aA26577bAc29f098084fCBAbE502f` |

### Critical Architectural Facts — Read Before Touching Anything

**1. ERC4626EVCCollateralCork has three overrides.**
- `_withdraw`: enforces pairing invariant in ALL cases (debt AND no-debt, both vault types). REF vault blocks withdrawal if post-withdrawal REF would be uncovered. cST vault blocks all withdrawal when debt > 0, and also blocks no-debt withdrawals that break pairing.
- `_deposit`: blocks REF vault deposits when debt > 0 and deposit would push REF above cST coverage.
- `_updateCache() {}`: empty override required by abstract parent.

Constructor takes **8 params**: `(evc, permit2, admin, borrowVault, asset, name, symbol, isRefVault)`. The `borrowVault` is the sUSDe borrow vault address (used for `debtOf` checks). The `bool isRefVault` flag determines which vault type's invariants apply.

Two instances deployed: `isRefVault=true` for vbUSDC vault, `isRefVault=false` for cST vault.

There is NO `balanceOf` override. `balanceOf` returns real shares to all callers. The original Euler POC had an account-encoding trick in `balanceOf` that was incompatible with the liquidation module's yield calculation (see `firstprinciples.md` FP-1). It was removed.

**2. Both vaults need `setPairedVault` called post-deploy -- in BOTH directions.**
```
vbUSDCVault.setPairedVault(cSTVault)   // REF vault needs cST vault for coverage checks
cSTVault.setPairedVault(vbUSDCVault)   // cST vault needs REF vault for no-debt pairing check
```
The deployment script Phase 5 handles this automatically. If either call fails, run manually. Governor-only call.

**3. The oracle return formula in old specs is wrong. The correct formula is `/1e6` not `/1e18`.**
vbUSDC is 6 decimals. `effectiveUsdPerToken` is USD per 1 full token (1e6 units) in 18-decimal WAD. Dividing by `1e18` gives USD in 6-decimal precision -- wrong. The correct return is `inAmount * effectiveUsdPerToken / 1e6`.

**4. CorkOracleImpl is a standard BaseAdapter. No per-account logic.**
The oracle prices vbUSDC in USD using `min(NAV, swapRate * sUsdeUsd * (1-fee) * hPool)`. It takes `inAmount` (real vbUSDC shares) and returns USD value. There is no account lookup, no cST coverage cap, no `CorkOracle` interface. The hook enforces 1:1 cST/REF pairing, making per-account coverage checks redundant.

`CorkCustomRiskManagerOracle` (Euler's POC Layer 1 oracle) is NOT used. It remains in the repo as a historical artifact but is not referenced by any deployed contract or script.

**5. EulerRouter Phase 4 needs `govSetResolvedVault` for BOTH collateral vaults.**
```solidity
router.govSetResolvedVault(vbUSDCVault, true);  // resolves vault shares to vbUSDC via convertToAssets
router.govSetResolvedVault(cSTVault, true);     // resolves vault shares to cST via convertToAssets
```
Without these, the router cannot route `vbUSDCVault/USD` or `cSTVault/USD` queries. The router calls `convertToAssets` on the vault, gets the underlying token amount, then hits the token-level oracle (CorkOracleImpl for vbUSDC, CSTZeroOracle for cST).

**6. Deployment used 7 sequential scripts, NOT a monolithic `ManageCluster.s.sol`.**
Scripts are at `cork-contracts/script/01_DeployRouter.s.sol` through `07_DeployLiquidator.s.sol`. Each reads prior addresses from `.env` and logs the next address to paste in. All have been executed. See `README.md` for the full sequence.

**7. `swapFee(poolId)` scale is NOT traditional bps. It uses `1e18 = 1% = 100 bps`.**
So `5e16 = 0.05% = 5 bps`. The formula `feeBps * 1e16 / 1e18 = feeBps / 100` converts to WAD fraction. This looks wrong but is correct. Confirmed against `MathHelper.calculatePercentageFee` which divides by `100e18`.

**8. ProtectedLoopHook is only attached to the borrow vault (sUSDe), not the collateral vaults.**
The collateral vaults (`ERC4626EVCCollateral`) do not expose `setHookConfig`. The withdraw/deposit protections for collateral vaults are handled via `_withdraw`/`_deposit` overrides directly in `ERC4626EVCCollateralCork`, not via external hook. The hook (`OP_BORROW=64` on sUSDe vault) only gates the borrow operation. It checks: REF > 0, cST > 0, cST >= REF * 1e12 (1:1 pairing), cST not expired.

**9. Liquidator debt repayment is the bot's responsibility, not the contract's.**
`CorkProtectedLoopLiquidator._customLiquidation` seizes collateral, pulls debt to the operator via `pullDebt`, exercises in Cork, and sends all proceeds to `receiver`. The calling bot must repay the debt in the same EVC batch. This matches the `SBLiquidator` pattern. The contract enforces `collateral == refVault` via a require.

**10. Three spec gaps remain — blocked on CorkSeriesRegistry (not yet built by Cork).**
- H_pool does NOT auto-reduce near expiry. Mitigation: governor manually calls `CorkOracleImpl.setHPool(0)` before April 19, 2026.
- Borrow restriction within `liqWindow` not implemented.
- Rollover exception not implemented.
These cannot be built until Cork delivers `CorkSeriesRegistry`.

### Cork Whitelist — Hard External Dependency

Every external function on CorkPoolManager is gated by `_onlyWhitelisted(poolId, _msgSender())`. Before any on-chain testing is possible:
1. Deployer EOA `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` must be whitelisted to mint test cST
2. `CorkProtectedLoopLiquidator` contract address must be whitelisted to call `exercise()`

Both require Cork governance to call `WhitelistManager.addToMarketWhitelist(poolId, address)`. Coordinate with Cork team FIRST -- without this, no pool interaction of any kind is possible.

### Foundry Build

All Cork contracts live in `cork-contracts/`, a standalone Foundry project. No submodule hacks needed.

```bash
cd cork-contracts
forge build              # compiles all contracts cleanly
```

Deployment used 7 sequential scripts (`01_DeployRouter.s.sol` → `07_DeployLiquidator.s.sol`). All have been executed on mainnet. See `README.md` for addresses and script sequence.

The project has two lib dependencies (`evk-periphery` and `euler-price-oracle`) with only the submodules Cork actually imports initialized. Unused upstream submodules (LayerZero, reward-streams, fee-flow, etc.) are empty and never compiled.

**If you get "file not found" errors after a fresh clone:**
```bash
cd cork-contracts/lib/evk-periphery
git submodule update --init lib/euler-vault-kit lib/ethereum-vault-connector lib/openzeppelin-contracts lib/euler-earn lib/euler-price-oracle lib/forge-std
cd lib/euler-vault-kit && git submodule update --init --recursive && cd ../..
cd lib/euler-earn && git submodule update --init --recursive && cd ../..

cd ../../lib/euler-price-oracle
git submodule update --init lib/forge-std lib/solady lib/openzeppelin-contracts lib/ethereum-vault-connector
```

### Key Source Contracts (read before modifying)

**Cork contracts** (`cork-contracts/src/`):
- `oracle/CorkOracleImpl.sol` -- Standard BaseAdapter pricing vbUSDC/USD via Cork pool parameters
- `oracle/CSTZeroOracle.sol` -- Standard BaseAdapter returning 0 for cST/USD
- `vault/ERC4626EVCCollateralCork.sol` -- Collateral vault with pairing overrides (8-param constructor)
- `hook/ProtectedLoopHook.sol` -- Borrow-only hook enforcing REF+cST pairing
- `liquidator/CorkProtectedLoopLiquidator.sol` -- Seize both collaterals, exercise in Cork, send proceeds

**Parent classes** (in `cork-contracts/lib/evk-periphery/src/`):
- `Vault/implementation/ERC4626EVCCollateralCapped.sol` -- Parent: governor, supply cap, reentrancy
- `Vault/implementation/ERC4626EVC.sol` -- Grandparent: EVC-aware ERC4626, permit2, VIRTUAL_AMOUNT
- `HookTarget/BaseHookTarget.sol` -- Base for ProtectedLoopHook; `_msgSender()` extracts caller from calldata tail
- `Liquidator/CustomLiquidatorBase.sol` -- Base for liquidator; `_customLiquidation` is the override point

**Oracle base** (in `cork-contracts/lib/euler-price-oracle/src/`):
- `adapter/BaseAdapter.sol` -- Base for both Cork oracles
- `EulerRouter.sol` -- Router; `govSetConfig`, `govSetResolvedVault`
- `interfaces/IPriceOracle.sol` -- `getQuote(inAmount, base, quote)` interface

**Core EVK** (in `cork-contracts/lib/evk-periphery/lib/euler-vault-kit/src/`):
- `EVault/shared/Base.sol` -- `invokeHookTarget` appends caller as 20 bytes; hook fires before operation
- `EVault/shared/Constants.sol` -- `OP_BORROW=64`, `OP_WITHDRAW=4`, `OP_REDEEM=8`
- `EVault/IEVault.sol` -- `debtOf()`, `liquidate()`, `setHookConfig()`, `setLTV()`, `setCaps()`
- `GenericFactory/GenericFactory.sol` -- `createProxy(impl, upgradeable, trailingData)`; `isProxy()` used by hook

**EVC** (in `cork-contracts/lib/evk-periphery/lib/ethereum-vault-connector/src/`):
- `interfaces/IEthereumVaultConnector.sol` -- `batch()` for liquidation

**Cork Protocol** (`phoenix/`):
- `contracts/interfaces/IPoolManager.sol` -- `exercise()`, `swapRate()`, `swapFee()`, `MarketId` type
- `contracts/interfaces/IPoolShare.sol` -- `expiry()`, `isExpired()` (cST token interface)
- `contracts/core/CorkPoolManager.sol` -- All functions whitelisted
- `contracts/libraries/MathHelper.sol` -- `calculateDepositAmountWithSwapRate`: `refIn = cstShares * 1e18 / swapRate`

### Interface Notes

- `MarketId` is `type MarketId is bytes32` from `IPoolManager.sol`
- `IPriceOracle` from `cork-contracts/lib/euler-price-oracle/src/interfaces/IPriceOracle.sol` -- standard `getQuote(inAmount, base, quote)` interface used by both Cork oracles
- cST `expiry()` / `isExpired()` come from `IPoolShare` (`phoenix/contracts/interfaces/IPoolShare.sol`)