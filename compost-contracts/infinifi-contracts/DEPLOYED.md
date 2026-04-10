# InfiniFi — Deployed Contracts (Mainnet, Dec 2025)

Canonical addresses in `script/clusters/AddressesMainnet.sol`. This is a summary.

**Naming:** Scripts use "Warren" throughout — InfiniFi's internal codename. Baked on-chain, can't change.

**Deployer:** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` (AG dev wallet)

---

## Vaults

| Vault | Address | Asset |
|---|---|---|
| liUSD-1w | `0xE232C49e0B43E5f50Ca6797d6AE761e0976fd644` | INF_1W |
| liUSD-4w | `0xb04ad3337dc567a68a6f4D571944229320Ad1740` | INF_4W |
| liUSD-8w | `0x5a2d1F5Fe6Eb8514570CA0aB3d0C6b244a511B15` | INF_8W |
| USDC Loop | `0x4cBcfD04Ad466aa4999Fe607fc1864B1b8A400E4` | USDC |
| USDC Credit Pool | `0xDc6D457b6cf5dfaD338a7982608e3306FD9474c7` | USDC |
| Euler Earn (infUSDC) | `0x2f3558213c050731b3ae632811eFc1562d3F91CC` | USDC (legacy, unused) |

## EulerSwap

| Pool | Address |
|---|---|
| USDC Credit Pool <> liUSD-4w | `0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8` |

## Oracles (all 13 deployed)

| Bucket | Oracle Address |
|---|---|
| 1w | `0xEA8c4CfbEd89B7A44158999659f7dc7394488d45` |
| 2w | `0xfAbd0849d16A3ff43Dc74B2618AdFA57ffDfFdF1` |
| 3w | `0xAcd87207E5cbbbD2064225490875690239235Ec1` |
| 4w | `0xd23c153d7bece6012471c294DF5a85AFbe52b6C2` |
| 5w | `0xA68CF9125C33b7e8238ff7481211D8f443dD1f5F` |
| 6w | `0x405543ea3Fc23e842422989136e9354A000cDeFf` |
| 7w | `0x1eDDfd9c71Dd3D595461f3cc72a35D087EBA730A` |
| 8w | `0xedcd4bdb70d8F4920EE640918158dac8939ece04` |
| 9w | `0x7ABA5e95B81491783fF1FAe41aAfB6a51BDB30Fc` |
| 10w | `0xf06BFA3e6eB6ab7B1E9BbE4ECFF03B68AE10300e` |
| 11w | `0xF370ECF269F113B1bAD1323c1CA907646eaf2b65` |
| 12w | `0x7fc112DABa300E2f28d1Ce529A3D2282C1FDEc0c` |
| 13w | `0x6d4684B5e4A6F7e9611D2a03A3BD56ab100b37eD` |
| USDC | `0x3F777e2bc2212A3FE659514d09DaC7aD751C02A5` |

## Infrastructure

| Contract | Address | Status |
|---|---|---|
| Liquidator (v4, atomic debt) | `0x2b4be42ffE67aF9FeFb020Ff0891332C1DB1440e` | Idle — no keeper |
| HookTargetAccessControl | `0x1D34a4f69b7CB81ee77CD3b1D3944513352941d5` | Idle |
| MinimalRouter (Uni V4) | `0x6F54D2d2e1f86c2cad653eCE2C4A7De87809bb4D` | Idle |
| Kinky IRM (loop-optimized) | `0xB71DA37621076D6D6b5281824e7Af8ac183d6838` | Live |
| Euler Swapper (Euler's) | `0x2Bba09866b6F1025258542478C39720A09B728bF` | Live |

## InfiniFi Core (oracle reads)

| Contract | Address |
|---|---|
| LockingController | `0x1d95cC100D6Cd9C7BbDbD7Cb328d99b3D6037fF7` |
| Accounting | `0x7A5C5dbA4fbD0e1e1A2eCDBe752fAe55f6E842B3` |
| iUSD | `0x48f9e38f3070AD8945DFEae3FA70987722E3D89c` |

## Cluster Config

- **Loop pool:** 80% LTV all pairs, 10% interest fee, 15% max liquidation discount
- **Credit pool:** 100% LTV for liUSD vs Credit Pool (enables borrow-to-fill), punitive IRM 20%→30%@80%→50%
- **Hook:** OP_LIQUIDATE gated on all vaults. Credit Pool also hooks OP_BORROW (manual `setHookConfig(hook, 0x840)` post-deploy).
- **Supply caps:** 10M liUSD-1w, 2M each 4w/8w, 20M USDC

## What Works / What Doesn't

- Vaults, oracles, EulerSwap pool: **functional**
- Keeper, liquidator, frontend: **dead** — need a droplet running a keeper bot to reanimate liquidations
