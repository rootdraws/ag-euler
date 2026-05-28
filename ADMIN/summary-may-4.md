# Summary — 2026-05-04

## What we found

Most AG-governed Euler V2 vaults had `feeReceiver = 0x0`. Per EVK `Governance.sol:125`, that routes 100% of the 10% interest fee to Euler DAO's protocol receiver. Audit + fix campaign across all chains.

## Batches built

| Chain | File | Txs | Status |
|---|---|---|---|
| Base (8453) | `base-batch-setFeeReceiver.json` | 13 | pending — yoUSD + yoBTC + base-market clusters |
| Unichain (130) | `unichain-batch-setFeeReceiver.json` | 7 | pending — alphagrowth-unichain-market (alphagrowth-unichain rETH/WETH already configured) |
| Linea (59144) | `linea-batch-setFeeReceiver.json` | 4 | pending — wstETH + weETH clusters |
| Mainnet (1) | `mainnet-batch-setFeeReceiver.json` | 11 | pending — mAPOLLO + Origin ARM + Cap clusters |
| Arbitrum (42161) | `arbitrum-batch-kill-cluster.json` | 6 | pending — kill empty `alphagrowth-arbitrum` cluster (zero LTV + zero caps) |

All JSONs verified against `cast calldata` regen ✓.

## On-chain executed

- Transferred governance of `eUSDC-127` (`0xb639d1…0F2b`) and `eWBTC-16` (`0x9151…782C2`) on mainnet from dev wallet `0x501107…0253` → AG Safe `0x4f89…Fd3C`. Verified ✓.

## Fee tracker

`ADMIN/fee-tracker/track-fees.sh` + `vaults.tsv` snapshots accumulated fees across all 41 tracked AG vaults (4 chains). One snapshot per UTC date in `snapshots/`, diffs vs prior automatically. Run monthly.

## Cluster analyses saved

- `ADMIN/base-dao-markets-analysis.md` — `alphagrowth-base-market`: 1,065 active positions, ~$1M borrowed. **2/3 LST yield loops** (weETH/cbETH/wstETH → WETH).
- `ADMIN/unichain-markets-analysis.md` — `alphagrowth-unichain-market`: 342 active positions, ~$2.5M borrowed. **88% LST yield loops** (weETH ↔ WETH).
- `ADMIN/yoUSD-cluster.md` — Base PT-Mar2026 wind-down already running, ends 2026-05-24. ~$39k market.

## PT wind-downs in progress (already in motion, no action)

| Chain | Cluster | PT | Ramp end |
|---|---|---|---|
| Base | yoUSD | PT-yoUSD-26MAR2026 | 2026-05-24 |
| Mainnet | mAPOLLO | PT-mAPOLLO-20NOV2025 | 2026-05-31 |
| Mainnet | cap | PT-cUSD-29JAN2026, PT-stcUSD-29JAN2026 | 2026-05-31 |
| Mainnet | falcon | PT-USDf-29JAN2026, PT-sUSDf-29JAN2026 | 2026-05-31 |
| Mainnet | falcon | PT-sUSDf-25SEP2025 (orphan) | already at 0% (since 2025-12-05) |

## Open decisions

- **Falcon cluster** (`alphagrowth-falcon`): pulled from mainnet batch pending strategy on excising USDf/sUSDf collateral from USDC/USDT borrow vaults and redirecting USDC supply to a new collateral. Sequence: deploy new collateral first, let borrowers migrate, then ramp Falcon out.
- **Arbitrum kill batch**: cluster is empty (TVL=0, borrows=0). Kill-with-instant-zero is safe.
- **Optional Euler labels PR**: rebrand `alphagrowth-falcon` if collateral focus changes.
- **mAPOLLO cluster fact**: only 0.1% of debt is Prime-collateral-backed. The eUSDC-2/eUSDT-2 LTV link is wired but barely used — leave or remove later.

## Lessons saved to memory

- `feedback_euler_labels_source.md` — query live raw upstream master, not the local euler-submission fork (which sits on feature branches).
- `feedback_answer_dont_scan.md` — aggregate question → aggregate answer; don't silently escalate to per-borrower scans.
- `feedback_evk_no_clearltv.md` — `cast sig` doesn't prove a function exists. Grep EVK source first. EVK has no `clearLTV`; `LTVList` entries persist by design.

## Next session

- Sign + execute the 5 batch JSONs (sign order: Base, Unichain, Linea, Mainnet, Arbitrum).
- Run `track-fees.sh` post-execution to confirm AG starts accruing.
- Decide Falcon collateral replacement.
- Snapshot post-execution `feeReceiver` state across all clusters.
