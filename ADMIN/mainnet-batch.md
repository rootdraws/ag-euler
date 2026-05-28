# Mainnet — AG Safe Batch Queue

Pending and historical Safe batches on **Ethereum Mainnet (chainId 1)** signed by AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`.

---

## Pending

### Batch: mAPOLLO cluster — set vault feeReceiver
**Status:** pending
**Why:** All 4 AG-governed vaults in `alphagrowth-mapollo` have `feeReceiver = 0x0`, routing 100% of the 10% interest fee to Euler DAO. Setting AG Safe redirects AG's `protocolFeeShare` split back to AG.

The 2 cross-listed Prime collaterals (`eUSDC-2` `0x797D…48a9` and `eUSDT-2` `0x3136…2162`) are governed by Prime curator `0xcAD0…1DCe` — outside AG's authority, not in this batch.

**Function:** `setFeeReceiver(address)` — selector `0xefdcd974`
**Argument:** `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (AG Safe)
**Calldata (same for all 4):** `0xefdcd9740000000000000000000000004f894bfc9481110278c356ade1473ebe2127fd3c`

| # | Target vault | Symbol | Cluster | Value |
|---|---|---|---|---|
| 1 | `0x2a356443FeE07703266066c6Bb1B11b82d8246AD` | eUSDC-69 | alphagrowth-mapollo | 0 |
| 2 | `0xC11d6b78D8c609A6cbf66E89DBfea06b011B0AEf` | eUSDT-33 | alphagrowth-mapollo | 0 |
| 3 | `0x49d9fd20f1d61648Fa9434a8c0C33174F5614eB8` | emAPOLLO-1 | alphagrowth-mapollo | 0 |
| 4 | `0xF75D18F76859764aBe4D13cA2eBaCeFF0b90b262` | ePT-mAPOLLO-20NOV2025-1 | alphagrowth-mapollo (deprecated, ramping) | 0 |
| 5 | `0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd` | eARM-WETH-stETH-1 | origin-arm-weth | 0 |
| 6 | `0x6Fe7Fa90756434645F0b0428fDff78E99Dda0FBc` | eUSDC-63 | alphagrowth-cap | 0 |
| 7 | `0x35d4f830543700B7280084280ae3236f178E88e3` | eUSDT-30 | alphagrowth-cap | 0 |
| 8 | `0x55F9bACE2C864aC0D3392Ea9fa654b605F21A3d3` | ecUSD-1 | alphagrowth-cap | 0 |
| 9 | `0xb7522C867B8AFae5e89638b59fb38f31B0821795` | estcUSD-1 | alphagrowth-cap | 0 |
| 10 | `0x69a2fAD6AC96DDa502f7d240fB4EC88f85217705` | ePT-cUSD-29JAN2026-1 | alphagrowth-cap (expired PT) | 0 |
| 11 | `0x97C72647be549C6079dC95235271A9a0Fe7ECc21` | ePT-stcUSD-29JAN2026-1 | alphagrowth-cap (expired PT) | 0 |

**Removed: alphagrowth-falcon cluster (7 vaults).** Pending fee-receiver fix held back until the cluster's collateral migration plan is finalized — see chat about excising USDf/sUSDf from USDC/USDT borrow vaults and redirecting supply to a new collateral.

JSON for Safe Tx Builder import: `mainnet-batch-setFeeReceiver.json`

---

## Other AG mainnet clusters (not yet queued)

User has indicated more mainnet clusters need fee-receiver fix — to be appended to this batch as identified.

Known AG mainnet clusters from labels:
- `cork-protected-loop` (3 vaults) — may be on Tenderly fork (chain 9991), check before adding
- `origin-arm-weth` (2 vaults, chain 1)
- `ag-eth-triad` (3 vaults, chain 1) — overlaps with origin-arm-weth on `0x2ff5F1…443B`

State of these to be checked.

---

## Executed

_(none yet)_
