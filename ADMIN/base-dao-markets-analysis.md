# AlphaGrowth Base Market — Position Analysis

**Cluster:** `alphagrowth-base-market` (AlphaGrowth Base) — 8 cross-margin vaults on Base.
**Snapshot:** 2026-05-04
**Method:** scanned `Borrow` events on all 8 vaults (8,973 unique sub-accounts ever borrowed) → filtered via `EVC.getControllers()` → 1,874 with active controller → 1,065 with non-zero current debt. Per-account collateral resolved via `EVC.getCollaterals()` and `convertToAssets`.

## Vaults

| Vault | Symbol | Asset | Borrows |
|---|---|---|---|
| `0x8591…b410` | eWETH-1 | WETH | 211.45 WETH |
| `0x7b18…2609` | ewstETH-1 | wstETH | 1.48 wstETH |
| `0x358f…ea49` | ecbETH-1 | cbETH | 0.0053 cbETH |
| `0xd4A8…0d14` | eweETH-1 | weETH | 0.087 weETH |
| `0x0A1a…eE16` | eUSDC-1 | USDC | 261,828 USDC |
| `0x8820…7f8B` | ecbBTC-1 | cbBTC | 0.556 cbBTC |
| `0x3f0d…8a7A` | eLBTC-1 | LBTC | 0.139 LBTC |
| `0x5Fe2…ac25` | eAERO-1 | AERO | 99,884 AERO |

Aggregate borrow demand: **~$1M USD** (rough, WETH~$3k / BTC~$95k / AERO~$0.50). Concentrated in WETH (~$635k) + USDC (~$262k).

## Strategy Breakdown (1,065 active positions)

Each row: primary collateral → primary borrow. USD via the same back-of-envelope prices.

| Strategy | Accts | Borrowed | Collateral | Type |
|---|---|---|---|---|
| weETH → WETH | 38 | $389k | $418k | LST yield loop |
| cbETH → WETH | 8 | $127k | $124k | LST yield loop |
| AERO → USDC | 33 | $118k | $248k | Leveraged AERO long |
| wstETH → WETH | 6 | $96k | $101k | LST yield loop |
| LBTC → USDC | 6 | $46k | $116k | Leveraged BTC long |
| USDC → AERO | 43 | $46k | $85k | AERO short / hedge |
| cbBTC → USDC | 26 | $45k | $127k | Leveraged BTC long |
| WETH → cbBTC | 20 | $27k | $59k | ETH coll, borrow BTC |
| (~30 more smaller buckets) | — | ~$30k | — | mixed pair trades |

### Rolled up by meta-strategy

| Bucket | Accts | Borrowed | Share |
|---|---|---|---|
| **LST yield loops** (weETH/cbETH/wstETH → WETH) | 52 | **~$612k** | ~67% |
| **Leveraged longs** (AERO/LBTC/cbBTC → USDC) | 65 | ~$209k | ~23% |
| **AERO shorts/hedges** (anything → AERO) | ~50 | ~$50k | ~5% |
| **Other pair trades** (WETH→cbBTC etc.) | ~30 | ~$30k | ~3% |

## Takeaways

- **2/3 of the demand is LST yield-loopers** — depositing weETH/cbETH/wstETH and borrowing WETH to recycle. WETH IRM is the dominant fee generator.
- USDC borrow demand is roughly evenly split between BTC longs (LBTC + cbBTC) and AERO longs.
- AERO has both sides — long via AERO collateral, short via AERO borrow. Net long is bigger.
- LBTC and cbBTC together represent meaningful BTC long exposure (~$91k borrowed against ~$243k of BTC collateral).

## Fee implications

All 8 vaults have `feeReceiver = 0x0`, so 100% of the 10% interest fee currently routes to Euler DAO. Setting AG Safe as fee receiver (queued in `base-batch.md`) will redirect AG's protocol-config share — same 50/50 split observed on `eUSDC-49` in the `alphagrowth-base` cluster — back to AG. With ~$612k of LST loops paying WETH borrow rate continuously, this is the cluster generating the largest absolute fees.

## Reproducing this analysis

Script: `/tmp/scan_v2.py` (one-shot, JSON-RPC batched, 55s runtime). Should be moved to `ADMIN/cluster-scan/` and parameterized if we want to run it for other clusters.
