# Euler Lite — Balancer Frontend Context

AI context file for the **Balancer-specific** Euler Lite frontend. This is a fork of the shared `euler-lite` frontend, customized for Balancer V3 BPT vault markets on Monad (chain 143).

**Repo:** `rootdraws/ag-euler-lite-balancer`
**Deployed at:** `balancer.alphagrowth.fun` (Vercel project `ag-euler-balancer`)
**Contract context:** See `../balancer-contracts/balancer-claude.md` for vault + adapter deployment details.
**Shared frontend context:** See `../CLAUDE.md` for the base euler-lite architecture (pages, composables, theming, labels, etc.). Everything in CLAUDE.md applies here unless overridden below.

---

## What's different from the shared euler-lite

This frontend adds features for Balancer V3 BPT collateral vaults:

1. **Zap BPT** — convert raw user tokens (AUSD/WMON) into Balancer Pool Tokens from a dedicated page. Uses Enso Finance routing (Pools 1-3) or a custom BalancerBptAdapter (Pool 4).
2. **Multiply/leverage (standard borrow page)** — borrow against BPT collateral to loop into more BPT, using Enso Finance routing or adapter within EVC batches. Uses the standard `useMultiplyForm.ts` with custom quote fetchers.
3. **Enso Finance integration** — server-side proxy for Enso's routing API, used for zap, multiply, and repay operations.

### New files

| File | Purpose |
|---|---|
| `composables/useEnsoRoute.ts` | Fetches Enso `/route` quotes, transforms into `SwapApiQuote` objects. Also builds adapter-based quotes using `GenericHandler` encoding. Exports `previewAdapterZapIn` and `encodeAdapterZapIn` for adapter pools. |
| `composables/useLoopZap.ts` | Zap BPT composable (`useZapBpt`): converts AUSD/WMON → BPT via Enso or adapter. Single-transaction, no leverage. |
| `pages/loop-zap/index.vue` | Zap BPT page — pool selector, amount input, zap button. |
| `server/api/enso/route.get.ts` | Server-side proxy for Enso API calls (keeps API key server-side, rate-limited at 30/min). |
| `server/utils/enso.ts` | Enso API URL + key config helper. |

### Modified files

| File | Change |
|---|---|
| `composables/borrow/useMultiplyForm.ts` | Detects adapter config → uses `buildAdapterSwapQuote` + `previewAdapterZapIn` for Pools 1,4; Enso for Pools 2,3. |
| `composables/repay/useCollateralSwapRepay.ts` | Uses Enso for all BPT→borrow repay quotes (adapter zapOut blocked by pool hooks). |
| `composables/repay/useRepaySwapCore.ts` | Extended `customQuoteFetcher` to support reactive ref/computed for adapter detection. |
| `composables/useDeployConfig.ts` | Added `bptAdapterConfig` — parsed from `NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG` env var. |
| `composables/useEnvConfig.ts` | Added `ensoApiUrl` for the Enso proxy endpoint. |
| `composables/useSwapQuotesParallel.ts` | `requestCustomQuote` allows injecting pre-built `SwapApiQuote` objects. |
| `composables/useEulerOperations/vault.ts` | Contains `buildMultiplyPlan()` used by the standard multiply form. |
| `entities/menu.ts` | Added "Zap BPT" menu item, gated by `enableLoopZapPage` flag. |
| `nuxt.config.ts` | Added `configBptAdapterConfig` and `configEnableLoopZapPage` to runtime config. |
| `server/plugins/app-config.ts` | Injects `configBptAdapterConfig` and `configEnableLoopZapPage` into window config. |
| `pages/position/[number]/multiply.vue` | Same adapter detection logic as `useMultiplyForm.ts` for existing position multiply. |
| `abis/vault.ts` | Added `vaultPreviewDepositAbi` for ERC4626 `previewDeposit` calls. |
| `.env.example` | Documents new env vars for Enso, adapter config, and Zap BPT. |

---

## Multiply Architecture (standard borrow page)

### How multiply works (EVC batch)

```
1. EVC.borrow(borrowVault, amount)        → AUSD/WMON to Swapper
2. Swapper.multicall([
     swap(GenericHandler, adapter/enso)    → borrow asset becomes BPT
     sweep(BPT, 0, collateralVault)        → transfer BPT to collateral vault
   ])
3. SwapVerifier.verifyAmountMinAndSkim     → slippage check + deposit into vault
```

**Why `sweep` not `deposit`:** The SwapVerifier's `verifyAmountMinAndSkim` calls `skim()` on the collateral vault, which claims any tokens sitting at the vault address. `Swapper.deposit()` would consume the tokens internally (leaving nothing to skim), causing the verifier to revert with `SwapVerifier_skimMin`. `Swapper.sweep()` transfers BPT directly to the vault address, where `skim()` can claim them.

### Routing decision (per pool)

| Pool | Collateral Vault | Borrow Asset | Multiply Route | Repay Route |
|---|---|---|---|---|
| Pool 1 (wnAUSD/wnUSDC/wnUSDT0) | `0x5795...0436` | AUSD (6 dec) | **Adapter** `0xC904...Bf98` | Enso |
| Pool 2 (sMON/wnWMON) | `0x578c...0Ea5` | WMON (18 dec) | Enso | Enso |
| Pool 3 (shMON/wnWMON) | `0x6660...Ed7` | WMON (18 dec) | Enso | Enso |
| Pool 4 (wnLOAZND/AZND/wnAUSD) | `0x1758...9F92` | AUSD (6 dec) | **Adapter** `0x8753...c832` | Enso |

The decision is driven by the `bptAdapterConfig` map. If a collateral vault address has an entry, the adapter path is used for multiply. Otherwise, Enso is called. Repay always uses Enso (pool hooks block the adapter's `removeLiquiditySingleTokenExactIn`).

### Quote flow

**Adapter multiply (Pools 1, 4):**
1. `useMultiplyForm` detects `bptAdapterConfig[collateralVaultAddr]`
2. Calls `previewAdapterZapIn()` — on-chain preview: `ERC4626.previewDeposit(amount)` → scale wrapper decimals to 18 (BPT decimals) → apply slippage. Returns `{ expectedBptOut, minBptOut }`.
3. Calls `encodeAdapterZapIn(tokenIndex, borrowAmount, minBptOut)` to build adapter calldata
4. Calls `buildAdapterSwapQuote()` which encodes: `GenericHandler` data → `Swapper.swap` → `Swapper.sweep`

**Enso multiply (Pools 2, 3):**
1. No adapter entry found
2. Calls `getEnsoRoute()` via server proxy → Enso `/route` API (`fromAddress=swapper`, `receiver=swapper`)
3. Calls `buildEnsoSwapQuote()` to wrap Enso route in `SwapApiQuote` format (uses `Swapper.swap` → `Swapper.sweep`)

**Enso repay (all pools):**
1. `useCollateralSwapRepay` → `ensoRepayFetcher`
2. Always calls `getEnsoRoute(BPT → borrowAsset)`
3. Calls `buildEnsoRepaySwapQuote()` with `SwapVerificationType.DebtMax` + interest adjustment buffer

---

## Zap BPT Page

### Purpose

Simple one-transaction page to convert AUSD or WMON into Balancer Pool Tokens. No leverage, no borrowing — just token conversion.

### Flow

1. User selects a pool (Pool 1-4)
2. User enters amount of AUSD or WMON
3. Preview shows expected BPT output
4. User clicks "Zap" — approval + swap in one transaction
5. BPT lands in user's wallet

### Routing

| Pool | Method | Approval target |
|---|---|---|
| Pool 1, 2, 3 | Enso `/route` (`fromAddress=user`, `receiver=user`) | Enso Router (from `ensoRoute.tx.to`) |
| Pool 4 | Direct call to `BalancerBptAdapter.zapIn()` | Adapter address |

### Pool configuration in `useLoopZap.ts`

The `POOLS` array is hardcoded with all four pools. Each entry has:
- `id`, `name` — display identifiers
- `collateralVault` — Euler vault address (used for adapter config lookup)
- `borrowAsset`, `borrowAssetSymbol`, `borrowAssetDecimals` — input token info (AUSD=6 dec, WMON=18 dec)
- `inputTokens` — tokens the user can deposit (one per pool, same as borrow asset)
- `routeType` — `'enso'` or `'adapter'` (controls zap path)
- `bptAddress` — Balancer Pool Token address

### UI phases

1. **`input`**: Pool selector, amount input, preview summary, "Zap" button
2. **`done`**: Success state with BPT received, "Zap Again" button

---

## Environment Variables (additions to base euler-lite)

```bash
# Enso Finance API (server-side only, proxied via /api/enso/route)
ENSO_API_KEY=<your-enso-api-key>
ENSO_API_URL=https://api.enso.build

# Enable multiply for BPT vaults
NUXT_PUBLIC_CONFIG_ENABLE_ENSO_MULTIPLY=true

# Enable Zap BPT page in navigation
NUXT_PUBLIC_CONFIG_ENABLE_LOOP_ZAP_PAGE=true

# Adapter config: collateral vault → {adapter, tokenIndex, pool, wrapper, numTokens}
# Only needed for pools where Enso can't route the forward direction
# pool = Balancer BPT address, wrapper = ERC4626 wrapper for borrow asset, numTokens = pool token count
NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG='{"0x5795...":{"adapter":"0xC904...","tokenIndex":1,"pool":"0x2DAA...","wrapper":"0x82c3...","numTokens":3},"0x1758...":{"adapter":"0x8753...","tokenIndex":1,"pool":"0xD328...","wrapper":"0x82c3...","numTokens":3}}'
```

---

## Key Composable: `useEnsoRoute.ts`

This is the bridge between Enso/adapter and Euler's swap system.

**Exports:**
- `getEnsoRoute(params)` — Fetches Enso `/route` via server proxy. Converts slippage from percentage to basis points. Returns raw Enso response with `tx.to`, `tx.data`, `amountOut`.
- `buildEnsoSwapQuote(route, ctx)` — Wraps Enso route data into `SwapApiQuote` for multiply. Uses `HANDLER_GENERIC` with Enso router as target.
- `buildEnsoRepaySwapQuote(route, ctx)` — Same for repay direction. Uses `SwapVerificationType.DebtMax` with interest adjustment buffer.
- `buildAdapterSwapQuote(ctx)` — Builds `SwapApiQuote` for adapter-based multiply. Encodes `GenericHandler` data targeting the adapter's `zapIn`.
- `encodeAdapterZapIn(tokenIndex, amount, minBptOut)` — Encodes adapter calldata.
- `previewAdapterZapIn(config, adapterEntry, amount, slippage)` — On-chain preview: ERC4626 `previewDeposit` → scale wrapper decimals to 18 (BPT standard) → apply slippage. Does NOT call `queryAddLiquidityUnbalanced` (reverts with `NotStaticCall()` on Monad). Returns `{ expectedBptOut, minBptOut }`.
- `zapInFunctionAbi` — ABI for `adapter.zapIn(uint256, uint256, uint256)`, exported for direct calls in Zap BPT.

The `HANDLER_GENERIC` bytes32 (`0x47656e65726963...`) identifies the Euler Swapper's GenericHandler. The handler decodes `(address target, bytes payload)` from `params.data`, approves `tokenIn` to the target, then calls `target.call(payload)`.

---

## Key Composable: `useLoopZap.ts` (exports `useZapBpt`)

Single-phase zap composable for the Zap BPT page.

**State:**
- `phase`: `'input'` → `'done'`
- `selectedPoolId`, `inputAmount`, `inputTokenAddress`
- `expectedBptFromZap` — preview estimate from Enso/adapter
- `bptReceivedFromZap` — actual BPT received after zap

**Functions:**
- `fetchZapPreview()` — debounced (600ms), auto-runs on input change
- `executeZapIn()` — approve + swap/adapter call
- `resetState()` — resets to phase `'input'`

---

## Multiply Debt Safety Margin

Both multiply pages (`useMultiplyForm.ts` for new positions, `multiply.vue` for existing positions) apply a safety reduction to the calculated borrow amount:

```
safetyBps = max(slippage × 3, 100)   // 3× slippage setting or 1% minimum
adjustedDebt = rawDebt × (10000 - safetyBps) / 10000
```

This prevents `EVC_ControllerViolation` at high multipliers where swap price impact pushes the actual LTV past the on-chain limit. Pools 1/4 (adapter, stableswap) have negligible slippage; Pools 2/3 (Enso) have ~1% price impact. Without the margin, a 19x multiply on Pool 2 would produce ~95.6% actual LTV against a 95% limit. The margin caps effective max leverage slightly below theoretical max.

---

## Gotchas

1. **Enso API key must be server-side.** The proxy at `/api/enso/route` keeps the key out of the browser. Never expose it in `NUXT_PUBLIC_*` vars.

2. **Enso slippage is in basis points.** `slippage=50` means 0.5%. The `getEnsoRoute` function converts from percentage automatically. Sending raw percentage returns HTTP 400.

3. **Enso has a ~1 RPS rate limit.** The server proxy enforces 30 req/min. Multiple rapid quote fetches will 429.

4. **`bptAdapterConfig` keys are vault addresses, not BPT addresses.** The config maps **Euler collateral vault** addresses, since that's what the multiply form works with. The adapter itself knows the BPT/pool address.

5. **Pool hooks block single-sided removal.** `AfterRemoveLiquidityHookFailed()` on `removeLiquiditySingleTokenExactIn` for all callers, not just the adapter. This is a Balancer pool-level restriction. Enso routes around it for repay.

6. **Interest adjustment on repay verification.** `buildEnsoRepaySwapQuote` adds `INTEREST_ADJUSTMENT_BPS` buffer to `verifyDebtMax` to account for Euler's internal interest accrual between tx submission and execution.

7. **Adapter addresses change on redeploy.** If the adapter contract is updated, new addresses must be set in both `NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG` and the adapter references. The adapter is stateless — old deploys can be abandoned.

8. **AUSD has 6 decimals.** The `POOLS` array in `useLoopZap.ts` must have `borrowAssetDecimals: 6` for AUSD pools (Pool 1, Pool 4). WMON pools use 18. Getting this wrong causes display values to be off by 10^12.

9. **SwapVerifier lacks `transferFromSender` on Monad.** Any single-batch flow that needs to pull tokens from the user's wallet into the Swapper will fail. The `buildMultiplyPlan` works because it operates vault-to-vault.

10. **`queryAddLiquidityUnbalanced` reverts on Monad.** Balancer V3 Router's query function requires a static call context, but `simulateContract` in viem sends a real call, causing `NotStaticCall()` revert (`0x67f84ab2`). The adapter preview uses `ERC4626.previewDeposit` + decimal scaling instead.

11. **Wrapper token decimals != BPT decimals.** ERC4626 wrappers (wnAUSD, etc.) may have different decimals than BPT (always 18). `previewAdapterZapIn` reads the wrapper's `decimals()` and scales accordingly. Omitting this causes the BPT estimate to be off by orders of magnitude, leading to `SwapVerifier_skimMin` failures.

12. **`Swapper.deposit()` vs `Swapper.sweep()` in multicall.** Always use `sweep(token, minAmount, to)` to move tokens to a vault within the Swapper multicall. `deposit()` consumes tokens internally, leaving nothing for `SwapVerifier.verifyAmountMinAndSkim()` to skim. This causes a silent revert.

13. **Repay multicall must include `sweep` for excess tokens.** The `repay(token, vault, type(uint256).max, account)` call in the Swapper sends only enough tokens to cover the debt. Any excess from the swap stays in the Swapper contract with no way for the user to recover it without a manual `sweep` call. Always add `sweep(tokenOut, 0, ownerAddress)` as the final multicall item after `repay` to return leftover tokens to the user's wallet. The multiply flow (`swap` + `sweep`) had this right; the repay flow (`swap` + `repay`) was missing it.
