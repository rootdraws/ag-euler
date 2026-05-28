# Unichain — AG Safe Batch Queue

Pending and historical Safe batches on **Unichain (chainId 130)** signed by AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`.

Same Safe address as Base/Mainnet/BSC. v1.4.1, threshold 3, nonce 13 at time of file creation.

---

## Pending

### Batch: Unichain — set vault feeReceiver
**Status:** pending
**Why:** 7 of 9 AG-governed vaults on Unichain have `feeReceiver = 0x0`. Per EVK `Governance.sol:125`, this routes 100% of the 10% interest fee to Euler DAO's protocol receiver. Setting AG Safe as `feeReceiver` redirects AG's split (per `ProtocolConfig`, ~50/50 in practice) back to AG.

The other 2 vaults (`alphagrowth-unichain` cluster: erETH-2, eWETH-4) are already configured correctly — no action needed there.

**Function:** `setFeeReceiver(address)` — selector `0xefdcd974`
**Argument:** `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (AG Safe)
**Calldata (same for all 7):** `0xefdcd9740000000000000000000000004f894bfc9481110278c356ade1473ebe2127fd3c`

| # | Target vault | Symbol | Cluster | Value |
|---|---|---|---|---|
| 1 | `0x1f3134C3f3f8AdD904B9635acBeFC0eA0D0E1ffC` | eWETH-1 | alphagrowth-unichain-market | 0 |
| 2 | `0x54ff502df96CD9B9585094EaCd86AAfCe902d06A` | ewstETH-1 | alphagrowth-unichain-market | 0 |
| 3 | `0xe36DA4Ea4D07E54B1029eF26A896A656A3729f86` | eweETH-1 | alphagrowth-unichain-market | 0 |
| 4 | `0x6eAe95ee783e4D862867C4e0E4c3f4B95AA682Ba` | eUSDC-1 | alphagrowth-unichain-market | 0 |
| 5 | `0xD49181c522eCDB265f0D9C175Cf26FFACE64eAD3` | eUSD₮0-1 | alphagrowth-unichain-market | 0 |
| 6 | `0x7650D7ae1981f2189d352b0EC743b9099D24086F` | esUSDC-1 | alphagrowth-unichain-market | 0 |
| 7 | `0x5d2511C1EBc795F4394f7f659f693f8C15796485` | eWBTC-2 | alphagrowth-unichain-market | 0 |

JSON for Safe Tx Builder import: `unichain-batch-setFeeReceiver.json`

---

## Executed

_(none yet)_
