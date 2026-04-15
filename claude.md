# Alpha Growth — Euler V2 Deployment Context

AI context file for the AG-Euler monorepo. For project overview see `README.md`. For task tracking see `TODO.md`. For the full deployment SOP see `new_market.md`.

**Per-partner contract context:**
- Cork: `contracts/cork-contracts/cork-claude.md`
- Balancer: `contracts/balancer-contracts/balancer-claude.md`
- Frax: `contracts/frax-contracts/frax-claude.md`
- Origin: `contracts/origin-contracts/origin-arm-euler-spec.md`
- Venice (VVV): `contracts/venice-contracts/` (3-market cluster: VVV/USDC/ETH on Base)
- ZRO: `contracts/zro-contracts/` (Chainlink adapter + scripts to add ZRO to the Venice Base cluster)
- BNB: `contracts/bnb-contracts/` (2-market cross-margin cluster: USDT/BNB on BSC)

**Frontend:** Consolidated at `frontends/alphagrowth/` — a single euler-lite fork serving all partners. All custom flows (Balancer BPT Zap, Cork dual-collateral borrow, Origin ARM multiply) are feature-flagged via env vars. Michael (AG webmaster) manages production deployment at `euler.alphagrowth.io`.

---

## Repo Structure

```
contracts/<partner>-contracts/       ← Foundry projects (deployment scripts, custom Solidity)
frontends/
  alphagrowth/                       ← Consolidated frontend (all partners, feature-flagged)
  labels/
    alphagrowth/                     ← Consolidated labels (chains 1, 56, 143, 8453)
    euler-submission/euler-labels/   ← Fork of euler-xyz/euler-labels (official listing PRs)
reference/                           ← Upstream Euler repos (EVC, EVK, price oracle, interfaces)
```

---

## Labels Architecture (Critical)

**Vault visibility is controlled by the labels layer, not the subgraph.** The subgraph returns all Euler vaults on a chain. The frontend filters to only vaults listed in the labels repo's `products.json`.

Flow:
1. Frontend fetches `products.json` from: `https://raw.githubusercontent.com/<LABELS_REPO>/refs/heads/<BRANCH>/<chainId>/products.json`
2. Every vault address in every product's `vaults` array becomes a verified vault
3. Only verified vaults are fetched and displayed

**If a vault address is NOT in `products.json`, it does not exist in the UI. Period.**

### Labels File Schema

Each chain directory has five files, plus a shared `logo/` directory at the repo root:

| File | Keyed by | Effect |
|---|---|---|
| `products.json` | product slug | Defines vault clusters. **If a vault isn't here, it's invisible.** |
| `vaults.json` | checksum address | Per-vault display name, description, and entity ID |
| `entities.json` | entity slug | Org name, logo filename, website, socials |
| `points.json` | array | Incentive/points programs. Use `[]` if none. |
| `opportunities.json` | checksum address | Cozy Finance safety modules. Use `{}` if not applicable. |

`logo/` — SVG or PNG files referenced by `entities.json`. Fetched from raw GitHub URL.

### Consolidated Labels

All partner labels live in `frontends/labels/alphagrowth/` with one chain directory per deployment:

| Chain | Partners |
|---|---|
| `1/` (Ethereum) | Cork (dual-collateral borrow) + Origin (ARM/WETH) |
| `56/` (BSC) | BNB (USDT/BNB cross-margin) |
| `143/` (Monad) | Balancer (BPT leverage) |
| `8453/` (Base) | Frax (FX markets) + Venice (VVV/USDC/ETH cluster) + ZRO (LayerZero) |

The frontend `.env` points to the GitHub repo hosting these labels via `NUXT_PUBLIC_CONFIG_LABELS_REPO`. Consolidated labels are published at `rootdraws/ag-labels` (branch `main`) — that's the repo the frontend mirrors from raw.githubusercontent.com.

---

## Multiply Positions (Leveraged Looping)

The multiply feature creates leveraged positions in a single atomic EVC batch: deposit collateral → enable controller → enable collateral → borrow → swap → verify → deposit swapped output as additional collateral.

### Standard Flow (Frax, most partners)

Borrow asset → Euler Swap API routes through DEX aggregators → output deposited as collateral. Standard token-to-token swaps. No custom routing needed.

### Custom Routing: Balancer BPT (Monad)

For Balancer BPT vaults, the "swap" step requires custom routing because BPT isn't a standard DEX-tradeable token:

| Path | When | How |
|---|---|---|
| **Adapter** | Pools 1 & 4 (ERC4626-wrapped tokens) | Custom `BalancerBptAdapter` via GenericHandler |
| **Enso Route API** | Pools 2 & 3 (native tokens) | Enso `/route` via server proxy |
| **Standard** | Fallback (`enableEnsoMultiply=false`) | Euler Swap API |

Gated by `NUXT_PUBLIC_CONFIG_ENABLE_ENSO_MULTIPLY` and `NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG` env vars.

Key decisions documented in `contracts/balancer-contracts/balancer-claude.md`:
- Swapper multicall uses `swap` + `sweep` (not `deposit` — it breaks `verifyAmountMinAndSkim`)
- Debt safety margin: `max(3x slippage, 1%)` to prevent `EVC_ControllerViolation`
- BPT preview via `ERC4626.previewDeposit` + decimal scaling (not `queryAddLiquidityUnbalanced`, reverts on Monad)

### Custom Routing: Origin ARM (Ethereum)

For the Origin ARM market, WETH → ARM-WETH-stETH routing goes through the Swapper's GenericHandler calling `ARM.deposit()` directly. Zero-slippage since ARM is an ERC-4626 vault.

Gated by `NUXT_PUBLIC_CONFIG_ARM_ADAPTER_CONFIG` env var (JSON map of collateral vault → ARM contract address). The multiply form checks for an ARM adapter entry before falling through to Enso/standard quotes.

### Custom Flow: Cork Dual-Collateral Borrow (Ethereum)

Cork requires depositing **two** collateral assets (vbUSDC + cST) simultaneously in a single EVC batch. This has its own dedicated page (`/cork-borrow`) and composable (`useCorkBorrowForm`) rather than using the standard borrow flow.

Gated by `NUXT_PUBLIC_CONFIG_ENABLE_CORK_BORROW_PAGE` env var.

### Tenderly Fork Chain Support

Cork is currently deployed on a Tenderly fork (chain 9991). The frontend maps fork chain IDs to their parent chain via `entities/forkChainMap.ts`, so labels, subgraphs, and Euler config resolve to mainnet data while the wallet operates on the fork.

---

## Official Euler Labels (app.euler.finance Listing)

To list vaults on the **official** Euler dApp, submit a PR to [euler-xyz/euler-labels](https://github.com/euler-xyz/euler-labels). Our fork: `rootdraws/euler-labels` (local copy in `frontends/labels/euler-submission/euler-labels/`).

**AlphaGrowth is the curator entity.** All AG-deployed vaults use `"entity": "alphagrowth"`. The `alphagrowth.svg` logo exists in the upstream `logo/` directory.

**Process:**
1. Branch from `master` in the fork
2. Add partner logo to `logo/`
3. Add entity, vault, and product entries for the target chain
4. Run `npm i && node verify.js` — must print `OK`
5. `gh pr create --repo euler-xyz/euler-labels`

**Submitted PRs:**
- Origin stETH ARM / WETH (chain 1): [PR #521](https://github.com/euler-xyz/euler-labels/pull/521)

---

## Gotchas

1. **Labels repo must have correct structure.** Each chain needs `<chainId>/products.json`, `entities.json`, `vaults.json`, `points.json`, `opportunities.json` plus `logo/` directory.
2. **Empty labels repo = empty frontend.** `products.json` as `{}` = zero vaults shown.
3. **MonadScan verification uses Etherscan V2 API, not Sourcify.** Sourcify only shows on MonadVision. For MonadScan: `curl -X POST "https://api.etherscan.io/v2/api?chainid=143"` with Standard JSON Input from `forge verify-contract --show-standard-json-input`. `forge verify-contract --chain 143 --verifier etherscan` fails — forge doesn't know chain 143. See `contracts/balancer-contracts/balancer-claude.md` lesson #23.
4. **Custom frontend flows are in `frontends/alphagrowth/`.** Cork dual-collateral borrow, Balancer BPT adapter/Enso multiply, and Origin ARM multiply are all implemented and feature-flagged. For new custom flows, add to this codebase. Michael handles production deployment.
5. **Adding collateral to an existing cluster** (ZRO pattern). You don't always deploy your own borrow vault for every asset. If a USDC or ETH borrow vault already exists, you can add your token as collateral by: (a) deploying a Chainlink adapter for your token, (b) deploying your own borrow vault + router, (c) wiring `govSetConfig` + `govSetResolvedVault` into **both** your new router and the existing vault's router, and (d) calling `setLTV` on both vaults. Requires governor access to the existing vaults/routers. See `contracts/zro-contracts/` for the full pattern.
6. **Vaults must be activated after deployment.** Euler V2 factory proxies are created with `hookedOps = 32767` (all operations disabled) and `hookTarget = address(0)`. This means **all operations (deposit, withdraw, borrow, repay, liquidate) are blocked by default**. You must call `setHookConfig(address(0), 0)` on **every** vault (borrow AND collateral) after deployment. Without this, users get "Operation Disabled" errors. Verify with: `cast call <vault> "hookConfig()(address,uint32)"` — second value should be `0`. See `new_market.md` Step 8 for details.
7. **BSC RPC reliability is bad.** For chain 56 deploys: NodeReal's public tier rate-limits aggressively (429s during receipt polling), Dwellir is an archive-pruned node (can't simulate recent state). Use `https://bsc-dataseed.bnbchain.org` (official Binance public) for `forge script`. Also: BSC's USDT is **18 decimals**, not 6 — AmountCap mantissa/exp encoding must reflect this.
8. **Deploy-script receipts can silently drop under rate-limiting.** If forge reports "Transaction dropped from the mempool" or "Failed to send transaction", verify on-chain before re-running — the tx may have already mined. Check `cast nonce $DEPLOYER` and compare against expected tx count. For factory-created proxies, identify which of the `additionalContracts` is the user-facing proxy (734 bytes, `governorAdmin()` returns deployer) vs the internal dispatcher (~5266 bytes). Recover missing txs with direct `cast send` rather than re-running the whole script.
