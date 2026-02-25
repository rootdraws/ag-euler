# Cork Protected Loop — TODO

Resolved design decisions and spec corrections are documented in `cork-contracts/cork-implementation.md`. This file tracks only: what must still be done, and how to do it.

---

## Deployment — COMPLETE ✓

All contracts deployed to Ethereum mainnet and verified on Etherscan.

| Contract | Address |
|---|---|
| EulerRouter | `0x693B992a576F1260fbD9392389262c2d6D357C3c` |
| CorkOracleImpl | `0xF9d813db87F528bb5b5Ae28567702488f8Bd34FC` |
| CSTZeroOracle | `0x81FfF8C68e6ea10d782d738a3C71110F876C3C06` |
| sUSDe Borrow Vault | `0x53FDab35Fd3aA26577bAc29f098084fCBAbE502f` |
| vbUSDC Collateral Vault | `0xadF7aFDAdaA4cBb0aDAf47C7fD7a9789C0128C6b` |
| cST Collateral Vault | `0xd0f8aC1782d5B80f722bd6aCA4dEf8571A9ddA4c` |
| ProtectedLoopHook | `0x677c2b56E21dDD0851242e62024D8905907db72c` |
| IRMLinearKink | `0x09f8E395c9845A3B5007DB154920bB28727246a3` |
| CorkProtectedLoopLiquidator | `0x1e95cC20ad3917ee523c677faa7AB3467f885CFe` |

Labels pushed to `rootdraws/ag-euler-cork-labels` with real vault addresses.

---

## Post-deployment

- [x] Send liquidator `0x1e95cC20ad3917ee523c677faa7AB3467f885CFe` to Cork team for whitelist
- [ ] **Confirm Cork whitelist** — verify `WhitelistManager.addToMarketWhitelist(poolId, 0x1e95cC20ad3917ee523c677faa7AB3467f885CFe)` executed
- [ ] **Acquire test assets:**
  - vbUSDC: approve USDC → deposit into Cork's vbUSDC vault (1:1)
  - sUSDe: buy via Ethena or DEX
  - cST: `CorkPoolManager.mint()` — requires Cork whitelist on deployer EOA `0x5304ebB378186b081B99dbb8B6D17d9005eA0448`
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

## Ongoing Monitoring

- [ ] **Rollover operator**: Keeper for cST_old → cST_new before expiry. Must be operational before April 19, 2026.
- [ ] **hPool governance**: If Cork pool impaired, call `CorkOracleImpl.setHPool(value)` to reduce collateral value.
- [ ] **Governor transfer**: After demo stable, transfer from deployer EOA to multisig via `setGovernorAdmin` (borrow vault) and `transferGovernance` (router).
