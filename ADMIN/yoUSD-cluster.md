# AlphaGrowth YO yoUSD Market — Status

**Chain:** Base (8453)
**Cluster slug:** `alphagrowth-yo-yousd`
**Governor:** AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`

## Vaults

| Vault | Symbol | Asset | Role |
|---|---|---|---|
| `0x085178078796Da17B191f9081b5E2fCCc79A7eE7` | eUSDC-29 | USDC | Borrow |
| `0x990d616ca6E7192625d1B7C41Fb67b5758DF7CF2` | eyoUSD-1 | yoUSD | Collateral |
| `0x24D633664Aea3F551B2Fa34fA66Dd1BA52a33933` | ePT-yoUSD-26MAR2026-1 | PT-yoUSD-26MAR2026 | Collateral (**deprecated**) |

## PT-Mar2026 — deprecated, ramping down

PT expired 2026-03-26 and is being wound down. The liquidation LTV is on a 30-day ramp from 91% → 0%, completing **2026-05-24**. Supply cap and borrow LTV already at 0 (no new deposits, no new positions backed by PT). Liquidators will clean up any remaining PT-backed debt as the ramp progresses; AG action not required.

After 2026-05-24: queue `clearLTV(PT_vault)` on the USDC borrow vault to drop PT from `LTVList` entirely.

## Active state — yoUSD → USDC

After PT is cleared, the cluster simplifies to: deposit yoUSD → borrow USDC.

- yoUSD liquidation LTV: 91% (borrow LTV 90%) — unchanged
- USDC borrow APR: ~5%
- Total USDC TVL in market: ~$39k

## Fees

All three vaults currently have `feeReceiver = 0x0`, which routes 100% of the 10% interest fee to the Euler protocol receiver. Fix queued in `ADMIN/base-batch.md`: AG Safe will call `setFeeReceiver(<AG Safe>)` on all three vaults so AG's share of interest fees accrues back to AG.
