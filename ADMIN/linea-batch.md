# Linea — AG Safe Batch Queue

Pending and historical Safe batches on **Linea (chainId 59144)** signed by AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`.

---

## Pending

### Batch: Linea — set vault feeReceiver
**Status:** pending
**Why:** All 4 AG-governed Linea vaults have `feeReceiver = 0x0`, routing 100% of the 10% interest fee to Euler DAO. Setting AG Safe redirects AG's `protocolFeeShare` split back to AG.

Two clusters, both LST/WETH yield-loop pairs:
- `alphagrowth-linea-wsteth`: wstETH ↔ WETH
- `alphagrowth-linea-weeth`: weETH ↔ WETH

**Function:** `setFeeReceiver(address)` — selector `0xefdcd974`
**Argument:** `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (AG Safe)
**Calldata (same for all 4):** `0xefdcd9740000000000000000000000004f894bfc9481110278c356ade1473ebe2127fd3c`

| # | Target vault | Symbol | Cluster | Value |
|---|---|---|---|---|
| 1 | `0xa8A02E6a894a490D04B6cd480857A19477854968` | eWETH-1 | alphagrowth-linea-wsteth | 0 |
| 2 | `0x359e363c11fC619BE76EEC8BaAa01e61D521aA18` | ewstETH-1 | alphagrowth-linea-wsteth | 0 |
| 3 | `0xF4712fC5E6483DE9e1Ff661D95DD686664327086` | eWETH-2 | alphagrowth-linea-weeth | 0 |
| 4 | `0x8955d7dCdE9bD9694B64732aD28fF2113eb217B4` | eweETH-1 | alphagrowth-linea-weeth | 0 |

JSON for Safe Tx Builder import: `linea-batch-setFeeReceiver.json`

---

## Executed

_(none yet)_
