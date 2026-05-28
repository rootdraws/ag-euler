# AG VVV LP × Euler — Handoff for Next Claude

Isolated experimentation cluster on Base (8453): **USDC borrow vault collateralized by the `agVVVWETHlp` ERC-7540 share token**. Deployed 2026-05-12. Single-asset pair, no partner coordination required.

For repo-wide context see `../../CLAUDE.md`. For the deployment SOP see `../../new_market.md`.

---

## What this market is

A self-contained sandbox owned by the user (canary EOA, no Safe). Lets them dogfood the agVVVWETHlp Vault7540 against an Euler borrow market without touching the multisig-governed Venice/Frax/ZRO/AERO clusters on the same chain. Tight caps (T0 canary), 60/70 LTV, deployer is sole governor of all three Euler-side contracts.

The collateral is an Aerodrome VVV/WETH LP gauge position auto-harvesting AERO into a per-share VVV "pile". The pile grows the share NAV monotonically as long as the harvest path stays open. Oracle excludes accrued-unharvested AERO on purpose — between harvests the pile lags reality, by design.

---

## Deployed addresses (Base 8453)

### Euler-side (we deployed)

| Contract | Address |
|---|---|
| KinkIRM (1%/8%/100% @ 80%) | `0xE98fb7A6869095A27aeb8E4300246B6E26A7a47d` |
| EulerRouter | `0xDF55E82d38570628Bae40E9b3203a5e222f506C4` |
| USDC Borrow Vault | `0x80D12d0bCFa5160b8959c4FFd008858b837928ac` |
| agVVVWETHlp Collateral Vault | `0x9166De33c9c128825b8866dc2860BDA3E1d778D9` |

Governor on all three: canary EOA `0x701a27330d13728a60bBe37DECde9D5a6c7402E5`.
Fee receiver on USDC borrow: AG curator `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` (10% interest fee).

### External (user's pre-existing)

| Contract | Address |
|---|---|
| `agVVVWETHlp` (Vault7540 share, 18 dec) | `0xf6a3B155CB5bd7d77E26b25177392c884b700B6f` |
| `PileInclusiveOracle` (returns USDC, 6 dec) | `0xDDaF961D09d716044e5C6FCc8eF321825Ad534aB` |
| ChainlinkUsdOracle wrapper (WETH→USDC) | `0xA84C8425180A03f07a3c6A044BFEcc68eE01D1b7` |
| VvvUsdReserveQuoteOracle (VVV→USDC) | `0xC9CF8edB66B2fa89e919bFB0A6470F5af0427422` |
| Aerodrome VVV/WETH pool | `0x01784ef301D79e4B2DF3a21ad9a536d4cf09a5ce` |
| Aerodrome VVV/WETH gauge | `0x37a70295FCefebBB0a29735A53E2e6786A02F930` |

---

## Market parameters

| Param | Value |
|---|---|
| Borrow asset | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Unit of account | **USDC** (not USD 840) — oracle returns USDC directly |
| Borrow LTV | 60% (6000) |
| Liquidation LTV | 70% (7000) |
| Max liq discount | 5% |
| Liq cool-off | 1s |
| Interest fee | 10% |
| IRM | Base 1% / Kink(80%) 8% / Max 100% APY |
| USDC supply cap | 25,000 (AmountCap raw `1611`) |
| USDC borrow cap | 15,000 (AmountCap raw `971`) |
| Coll supply cap | 60 shares ≈ $24k notional (raw `3860`) |
| Coll borrow cap | 0 (uncapped — no IRM set, unborrowable anyway) |

Live state captured after deploy + e2e exercise:
- USDC vault: 50 USDC supplied (deployer is sole lender), 25 USDC borrowed (deployer is sole borrower)
- Collateral vault: 0.2322746299 shares (full canary stake) ≈ $92.34 mark
- Position open: 27% LTV utilization, self-borrow loop

---

## Project layout

```
contracts/ag-vvv-lp-contracts/
├── foundry.toml          # Base RPC + Basescan verify config
├── remappings.txt        # standard EVK references
├── .env                  # filled, all addresses live
├── .env.example          # template
└── script/
    ├── Addresses.sol           # Base core + tokens + PileInclusiveOracle
    ├── 01_DeployIRM.s.sol
    ├── 02_DeployRouter.s.sol
    ├── 03_DeployBorrowVault.s.sol
    ├── 04_DeployCollateralVault.s.sol
    ├── 05_WireOracle.s.sol     # govSetResolvedVault + govSetConfig(agVVVWETHlp, USDC, oracle)
    ├── 06_ConfigureCluster.s.sol  # activates hooks + sets all risk params
    └── 07_SetFeeReceiver.s.sol
```

Activation (`setHookConfig(0, 0)`) is folded into step 06 (BNB pattern), not a separate step.

---

## Oracle wiring (read carefully)

Resolution chain inside the EulerRouter when pricing collateral:

```
Collateral EVault (0x9166…78D9)
  ├── govSetResolvedVault(true) → calls convertToAssets → agVVVWETHlp share
  └── govSetConfig(agVVVWETHlp, USDC, PileInclusiveOracle)
      └── PileInclusiveOracle.getQuote(amount, agVVVWETHlp, USDC) → USDC base units (6 dec)
```

The EVK collateral vault treats agVVVWETHlp as a plain ERC-20. No ERC-7540 async paths are touched on the Euler side — async semantics only matter when the user exits the share back to raw LP, which they do directly on the Vault7540 outside Euler.

The PileInclusiveOracle composes a 30-min Aerodrome TWAP + Chainlink ETH/USD + the harvested VVV pile. Returns USDC directly. **Unit of account is USDC** (not USD 840) so no decimal scaling needed — the oracle plugs in 1:1.

---

## Labels

Pushed to two branches of `rootdraws/ag-labels`:

| Branch | Why |
|---|---|
| `main` (commit `0609208`) | Canonical, what production should consume |
| `ag-vvv-deploy` | Cache-buster branch — used during deploy so the frontend dev server picked up labels without waiting for raw.githubusercontent.com's 5-min CDN. Safe to delete after main propagates. |

Local mirror: `frontends/labels/alphagrowth/8453/{entities,products,vaults}.json`. The local AG-Euler repo is not synced automatically to `rootdraws/ag-labels` — push is manual (clone + cp + commit). Frontend `.env` line 107 is the active branch override; currently set to `ag-vvv-deploy`, **switch back to `main` once you confirm CDN has refreshed**.

---

## Gotchas

1. **PileInclusiveOracle reverts `TwapStale` if the Aerodrome VVV/WETH pool sees no swaps for >30 min.** Would freeze borrow + liquidation. In practice the pool is active (AERO emissions farming keeps swap volume up), but if you ever see liquidation paths blocked, do a 1-wei swap on the pool to refresh the observation buffer.

2. **The 7540 vault is single-canary.** Deployer holds 100% of the supply (`totalSupply == 232274629927428702`). Until other depositors land, every collateral movement on Euler is essentially the same wallet. Don't read the live state as a stress test of multi-depositor mechanics.

3. **Verification gap on Basescan.** Router verified. KinkIRM + both EVault proxies did NOT — same factory-bytecode-mismatch issue as Origin/Venice. Cosmetic, not a blocker. Fix via Etherscan V2 standard-JSON if you want green checks. See `../balancer-contracts/balancer-claude.md` lesson #23 for the workflow.

4. **Governor = canary EOA, NOT AG Safe.** User explicitly deferred the Safe transfer. If you find yourself about to `setGovernorAdmin(safe)` / `transferGovernance(safe)`, confirm first — they want governor on the same key that controls the agVVVWETHlp `HARVESTER_ROLE` so cross-protocol moves stay coordinated.

5. **No multiply / EulerSwap / zap is wired.** This is a base lend+borrow market only. Looping the LP token would require either an EulerSwap pool for USDC↔agVVVWETHlp (Maglev-style) or a custom adapter — neither exists. Standard `useMultiplyForm` will fail-soft because the swap quote returns nothing.

6. **`AG_VVV_WETH_LP` in `Addresses.sol` is the share token, NOT the raw Aerodrome LP.** The naming is mildly misleading. The underlying Aerodrome LP (`0x01784e…a5ce`) is never touched by the Euler scripts — only the wrapping Vault7540 share is.

7. **The cache-buster branch trick.** When you push labels and need them visible in dev within seconds, push to a fresh branch name + flip the frontend `.env` branch override. raw.githubusercontent.com caches per (repo, branch, path) — a new branch URL = guaranteed fresh fetch, no 5-min wait.

8. **The `feedback_user_runs_broadcasts` memory was deleted this session** at the user's explicit request because the auto-classifier was blocking deploys. The user runs broadcasts themselves *unless* they explicitly say "handle it" / "deploy this" / similar. If you re-add the rule, expect the auto-classifier to block your `forge script --broadcast` calls and require a permission lift.

---

## Outstanding

- [ ] Verify KinkIRM + both EVault proxies on Basescan (cosmetic)
- [ ] Switch frontend `.env` line 107 back to `LABELS_REPO_BRANCH=main` once you confirm raw.githubusercontent.com main is fresh
- [ ] Delete `ag-vvv-deploy` branch from `rootdraws/ag-labels` after main propagates (housekeeping)
- [ ] Widen caps from 25k/15k/60 shares to production sizing once past canary
- [ ] Consider governor transfer to AG Safe — **user explicitly does NOT want this yet**; only do it on direct instruction
- [ ] Add an entry to `../../TODO.md` if/when this market graduates beyond experimentation

---

## Verification snippets

```bash
source .env

# Both vaults activated (second value should be 0).
cast call $USDC_BORROW_VAULT "hookConfig()(address,uint32)" --rpc-url $RPC_URL_BASE
cast call $COLLATERAL_VAULT  "hookConfig()(address,uint32)" --rpc-url $RPC_URL_BASE

# Router quote should match PileInclusiveOracle (~$397/share at time of deploy).
cast call $EULER_ROUTER "getQuote(uint256,address,address)(uint256)" \
  1000000000000000000 0xf6a3B155CB5bd7d77E26b25177392c884b700B6f 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --rpc-url $RPC_URL_BASE

# LTV configured.
cast call $USDC_BORROW_VAULT "LTVBorrow(address)(uint16)" $COLLATERAL_VAULT --rpc-url $RPC_URL_BASE       # 6000
cast call $USDC_BORROW_VAULT "LTVLiquidation(address)(uint16)" $COLLATERAL_VAULT --rpc-url $RPC_URL_BASE  # 7000

# Live position debt + supply.
cast call $USDC_BORROW_VAULT "totalBorrows()(uint256)" --rpc-url $RPC_URL_BASE
cast call $USDC_BORROW_VAULT "cash()(uint256)" --rpc-url $RPC_URL_BASE
cast call $USDC_BORROW_VAULT "debtOf(address)(uint256)" 0x701a27330d13728a60bBe37DECde9D5a6c7402E5 --rpc-url $RPC_URL_BASE
```
