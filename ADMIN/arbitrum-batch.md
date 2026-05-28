# Arbitrum — AG Safe Batch Queue

Pending and historical Safe batches on **Arbitrum (chainId 42161)** signed by AG Safe `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`.

---

## Pending

### Batch: Kill `alphagrowth-arbitrum` cluster
**Status:** pending
**Why:** The cluster is empty — TVL=0 and totalBorrows=0 on all 4 vaults. No active users to protect, so we can zero LTVs instantly (no 30-day ramp needed) and zero caps to prevent any future deposits/borrows.

**Cluster vaults (all governed by AG Safe, fee receiver already set):**

| Vault | Symbol | Asset | Role | Current LTV (borrow/liq) |
|---|---|---|---|---|
| `0x124BeC4d119bc4B5d250f0b0114f2087f8EeDB57` | eyUSND-1 | yUSND | Collateral | n/a |
| `0x4aD21eBbB639c21ccd9F1eaF388Cd91D015E02ee` | eUSND-1 | USND | Borrow (accepts eyUSND-1) | 9700 / 9800 |
| `0x8Ca487811a5e7599A5c68F49Ac1fE348371e4c46` | ereUSD-1 | reUSD | Collateral | n/a |
| `0x06b763aA769ad01F6859a56c5a856E47896e6a7F` | eUSDC-7 | USDC | Borrow (accepts ereUSD-1) | 9700 / 9800 |

**6 transactions:**

| # | Target | Function | Args | Calldata |
|---|---|---|---|---|
| 1 | `0x4aD21eBbB639c21ccd9F1eaF388Cd91D015E02ee` (eUSND-1) | `setLTV` | (eyUSND-1, 0, 0, 0) | `0x4bca3d5b000000000000000000000000124bec4d119bc4b5d250f0b0114f2087f8eedb57000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000` |
| 2 | `0x06b763aA769ad01F6859a56c5a856E47896e6a7F` (eUSDC-7) | `setLTV` | (ereUSD-1, 0, 0, 0) | `0x4bca3d5b0000000000000000000000008ca487811a5e7599a5c68f49ac1fe348371e4c46000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000` |
| 3 | `0x124BeC4d119bc4B5d250f0b0114f2087f8EeDB57` (eyUSND-1) | `setCaps` | (0, 0) | `0xd87f780f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000` |
| 4 | `0x4aD21eBbB639c21ccd9F1eaF388Cd91D015E02ee` (eUSND-1) | `setCaps` | (0, 0) | (same as #3) |
| 5 | `0x8Ca487811a5e7599A5c68F49Ac1fE348371e4c46` (ereUSD-1) | `setCaps` | (0, 0) | (same as #3) |
| 6 | `0x06b763aA769ad01F6859a56c5a856E47896e6a7F` (eUSDC-7) | `setCaps` | (0, 0) | (same as #3) |

**Note on `LTVList`:** Once these 6 txs execute, the cluster is dead — no new positions can open and existing values are 0. The collateral entries in `LTVList()` (`eyUSND-1` and `ereUSD-1`) will remain visible permanently because EVK's `setLTV` only appends to `ltvList`; there's no `clearLTV` / removal function in the contract. This is cosmetic — the underlying values are 0, so functionally the kill is complete.

JSON for Safe Tx Builder import: `arbitrum-batch-kill-cluster.json`

---

## Executed

_(none yet)_
