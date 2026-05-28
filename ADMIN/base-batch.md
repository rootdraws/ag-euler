# Base — AG Safe Batch Queue

Pending and historical Safe batches on **Base (chainId 8453)** signed by AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (3-of-7).

Append new batches at the top. Move executed batches to the `## Executed` section with the tx hash.

---

## Pending

### Batch: AlphaGrowth YO yoUSD — set vault feeReceiver
**Status:** pending
**Why:** All 3 cluster vaults have `feeReceiver = 0x0`, which makes `protocolFeeShare()` return 100% (EVK `Governance.sol:125`). 100% of the 10% interest fee currently routes to Euler DAO's protocol receiver `0x1e13B0847808045854Ddd908F2d770Dc902Dcfb8`. Setting `feeReceiver` to AG Safe redirects AG's share back to us. ~$12.86 already accrued on `eUSDC-29` and will go to Euler on the next `convertFees()` if we don't fix first.

**Cluster:** AlphaGrowth YO yoUSD Market (`alphagrowth-yo-yousd`)

**Function:** `setFeeReceiver(address)` — selector `0xefdcd974`
**Argument:** `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (AG Safe)
**Calldata (same for all three):** `0xefdcd9740000000000000000000000004f894bfc9481110278c356ade1473ebe2127fd3c`

| # | Target vault | Symbol | Value |
|---|---|---|---|
| 1 | `0x085178078796Da17B191f9081b5E2fCCc79A7eE7` | eUSDC-29 (USDC borrow, yoUSD cluster) | 0 |
| 2 | `0x990d616ca6E7192625d1B7C41Fb67b5758DF7CF2` | eyoUSD-1 (yoUSD collateral) | 0 |
| 3 | `0x24D633664Aea3F551B2Fa34fA66Dd1BA52a33933` | ePT-yoUSD-26MAR2026-1 (PT collateral) | 0 |
| 4 | `0xe72eA97aAF905c5f10040f78887cc8dE8eAec7E4` | ecbBTC-7 (cbBTC borrow, yoBTC cluster) | 0 |
| 5 | `0xFab9aF50F7A1Cfe201CAE1c15fCFdDaE7705ccD3` | eyoBTC-1 (yoBTC collateral) | 0 |
| 6 | `0x859160DB5841E5cfB8D3f144C6b3381A85A4b410` | eWETH-1 (alphagrowth-base-market) | 0 |
| 7 | `0x7b181d6509DEabfbd1A23aF1E65fD46E89572609` | ewstETH-1 (alphagrowth-base-market) | 0 |
| 8 | `0x358f25F82644eaBb441d0df4AF8746614fb9ea49` | ecbETH-1 (alphagrowth-base-market) | 0 |
| 9 | `0xd4A805261B28f375fc9c3d89EcD2C952Cd130d14` | eweETH-1 (alphagrowth-base-market) | 0 |
| 10 | `0x0A1a3b5f2041F33522C4efc754a7D096f880eE16` | eUSDC-1 (alphagrowth-base-market) | 0 |
| 11 | `0x882018411Bc4A020A879CEE183441fC9fa5D7f8B` | ecbBTC-1 (alphagrowth-base-market) | 0 |
| 12 | `0x3f0d3Fd87A42BDaa3dfCC13ADA42eA922e638a7A` | eLBTC-1 (alphagrowth-base-market) | 0 |
| 13 | `0x5Fe2DE3E565a6a501a4Ec44AAB8664b1D674ac25` | eAERO-1 (alphagrowth-base-market) | 0 |

---

## Executed

_(none yet)_

---

## Conventions

- One batch = one Safe transaction with N inner calls via the MultiSend / Transaction Builder.
- Calldata always shown verbatim so it can be pasted into Safe UI → Custom Contract Interaction (or imported from a Tx Builder JSON).
- Selectors derived with `cast sig "<sig>"`; verify against EVK source before adding new function patterns (see `feedback_verify_encoding_against_source` rule).
- For each batch: state the **why** in one paragraph (drives reviewers' approval), then the table.
