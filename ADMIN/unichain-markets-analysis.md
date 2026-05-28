# AlphaGrowth Unichain Market — Position Analysis

**Cluster:** `alphagrowth-unichain-market` — 7 cross-margin vaults on Unichain (chainId 130).
**Snapshot:** 2026-05-04
**Method:** Borrow events scanned in 10k-block chunks (Alchemy Unichain caps `eth_getLogs` at 10k blocks; ~4,719 chunks via address-array filter, batched 200 per request) → 4,871 unique sub-accounts ever borrowed → filtered via `EVC.getControllers()` on the canonical Unichain EVC `0x2A1176964F5D7caE5406B627Bf6166664FE83c60` → 473 accounts with active controller → 342 with non-zero current debt. Per-account collateral via `EVC.getCollaterals()` and `convertToAssets`.

## Vaults (governor = AG Safe `0x4f89…Fd3C` on all 7)

| Vault | Symbol | Asset | Decimals |
|---|---|---|---|
| `0x1f31…1ffC` | eWETH-1 | WETH | 18 |
| `0x54ff…d06A` | ewstETH-1 | wstETH | 18 |
| `0xe36D…9f86` | eweETH-1 | weETH | 18 |
| `0x6eAe…82Ba` | eUSDC-1 | USDC | 6 |
| `0xD491…eAD3` | eUSDT0-1 | USD₮0 | 6 |
| `0x7650…086F` | esUSDC-1 | sUSDC | **18** (not 6 — bit me on the first run) |
| `0x5d25…6485` | eWBTC-2 | WBTC | 8 |

All 7 currently have `feeReceiver = 0x0` — fix queued in `unichain-batch-setFeeReceiver.json`.

## Strategy Breakdown (342 active positions)

Each row: primary collateral → primary borrow. USD via WETH~$3k / wstETH~$3.5k / weETH~$3k / WBTC~$95k / stables~$1.

| Strategy | Accts | Borrowed | Collateral | Type |
|---|---|---|---|---|
| weETH → WETH | 26 | **$2,074k** | $2,100k | LST yield loop |
| WETH → USDC | 10 | $168k | $2,478k | Long ETH (very low LTV) |
| wstETH → WETH | 5 | $90k | $94k | LST yield loop |
| weETH → USDT0 | 44 | $81k | $192k | weETH coll, USDT0 borrow (long ETH carry) |
| USDC → sUSDC | 14 | $16k | $19k | sUSDC borrow vs USDC |
| WETH → weETH | 35 | $12k | $14k | reverse LST loop |
| USDT0 → USDC | 64 | $10k | $13k | stable arb |
| (remaining ~140 positions) | — | <$10k | — | dust pair trades |

### Rolled up

| Bucket | Borrowed | Share |
|---|---|---|
| **LST yield loops** (weETH ↔ WETH, wstETH → WETH) | **~$2.18M** | ~88% |
| **Long-ETH carry** (weETH/WETH → USDC/USDT0) | ~$249k | ~10% |
| Stable arbs (USDC ↔ USDT0 ↔ sUSDC) | ~$31k | ~1% |
| Dust / pair trades | <$10k | ~1% |

## Takeaways

- **88% of borrow demand is one trade**: deposit weETH → borrow WETH → recycle. Even more concentrated than Base (where LSTs were ~67%).
- The single line `WETH → USDC` (10 accts, $168k borrowed against $2.48M collateral) is striking — that's ~6.8% LTV. Likely big WETH depositors parking with token borrowing of stables for spending money or hedge sizing. Underutilized capital from a fee-revenue standpoint.
- Almost zero BTC activity (WBTC → only dust borrows). The market is effectively a weETH/WETH LST loop venue with light stable arbitrage on the side.
- USD₮0 (Tether's Unichain native USD) plays both sides modestly. sUSDC (yield-bearing USDC wrapper) sees small borrow demand against USDC.

## Fee implications

7 vaults × `feeReceiver = 0x0` = all interest fees flowing to Euler DAO right now. With $2.18M of LST loops paying WETH borrow rate continuously, this is the cluster generating the most absolute fee leakage on Unichain. After the queued batch executes, AG starts capturing its `protocolFeeShare` split (likely 50/50 like Base's `eUSDC-49` reference).

## Caveat

The `alphagrowth-unichain` cluster (rETH/WETH, 2 vaults — `erETH-2`, `eWETH-4`) is **separate** and already has fee receivers set. That cluster's totalBorrows are tiny by comparison (~17 WETH borrowed, ~$50k). Not part of this scan.

## Reproducing

Script: `/tmp/scan_unichain.py` (10k-block-chunked log scan + JSON-RPC batched lens calls). 86s runtime end-to-end. Move to `ADMIN/cluster-scan/` when we generalize.
