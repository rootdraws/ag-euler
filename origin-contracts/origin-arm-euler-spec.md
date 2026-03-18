# Origin ARM x Euler Integration Spec

**Alpha Growth — Technical Specification for Origin stETH ARM Integration with Euler V2**

Status: DEPLOYED
Date: 2026-03-12
Chain: Ethereum Mainnet (chainId 1)

---

## Table of Contents

1. [Strategy Overview](#1-strategy-overview)
2. [Key Addresses](#2-key-addresses)
3. [ARM Contract Interface](#3-arm-contract-interface)
4. [Euler Market Architecture](#4-euler-market-architecture)
5. [EulerSwap Pool — Borrow-to-Fill](#5-eulerswap-pool--borrow-to-fill)
6. [Multiply (Leveraged Looping)](#6-multiply-leveraged-looping)
7. [Liquidation Architecture](#7-liquidation-architecture)
8. [Frontend — euler-lite-origin](#8-frontend--euler-lite-origin)
9. [Economics](#9-economics)
10. [Risks and Open Questions](#10-risks-and-open-questions)
11. [Reference Material](#11-reference-material)

---

## 1. Strategy Overview

### The Opportunity

Origin's stETH ARM earns ~4.79% APY from arbitraging stETH/ETH pricing. ARM-WETH-stETH LP tokens represent shares of this vault. Today, ARM LP tokens can be used on Pendle (yield trading) but there is **no lending market and no multiply/looping product anywhere**.

### What We're Building

A lending market on Euler V2 (Ethereum mainnet) that enables:

1. **Borrow ETH against ARM collateral** — ARM-WETH-stETH as collateral, WETH as the borrow asset.
2. **EulerSwap pool with borrow-to-fill** — A single-LP pool controlled by Origin that provides deep ARM-WETH-stETH/WETH liquidity using JIT borrowing from Euler's lending reserves.
3. **Multiply (leveraged looping)** — Users deposit ARM, borrow ETH, convert ETH to more ARM, repeat. All atomic in one EVC batch. First-of-its-kind for ARM tokens.
4. **Attract ETH supply** — Origin can offer ETH lenders ~1% above market rate (funded by the ARM yield spread), pulling supply into the structure.

### The Flywheel

```
                    ┌─────────────────────────────┐
                    │  ETH Lenders (Euler Vault)   │
                    │  Earn elevated ETH yield     │
                    └──────────┬──────────────────┘
                               │ supply ETH
                               ▼
┌──────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│  ARM Vault   │────▶│  Euler Lending Pool   │◀────│  Multiply Users      │
│  ~4.79% APY  │     │  (WETH)               │     │  Loop ARM/ETH        │
│              │     │                       │     │  at leverage          │
└──────┬───────┘     └──────────┬────────────┘     └──────────────────────┘
       │                        │ borrow-to-fill
       │ collateral             ▼
       │              ┌──────────────────────┐
       └─────────────▶│  EulerSwap Pool       │
                      │  ARM-WETH-stETH/WETH  │
                      │  Origin = single LP   │
                      │  JIT liquidity         │
                      └──────────┬────────────┘
                                 │ aggregator routing
                                 ▼
                      ┌──────────────────────┐
                      │  DEX Aggregators      │
                      │  1inch, CoWSwap, etc. │
                      └──────────────────────┘
```

### Comparison to Existing ARM Integrations

| Integration | What It Does | What's Missing |
|---|---|---|
| **Morpho** | wOETH/WETH lending (not ARM LP) | No ARM-specific market, no multiply |
| **Pendle** | Yield trading on ARM tokens | No borrowing, no leverage |
| **This (Euler)** | Borrow ETH against ARM + multiply + EulerSwap JIT | Everything above, composed together |

---

## 2. Key Addresses

### Origin Contracts (Ethereum Mainnet)

| Contract | Address |
|---|---|
| ARM-WETH-stETH (LP token) | `0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6` |
| LidoARM (vault contract) | Same as above (ERC20Upgradeable, the token IS the vault) |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| OETH | `0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3` |
| Curve Pool (OETH/ARM-WETH-stETH) | `0x95753095f15870acc0cb0ed224478ea61aeb0b8e` |

### Euler Contracts (Deployed 2026-03-12)

| Contract | Address |
|---|---|
| KinkIRM | `0xa3AC336b108E698d5e96D96F9E1b56dAa9B28bcC` |
| EulerRouter (oracle) | `0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3` |
| WETH Borrow Vault | `0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B` |
| ARM-WETH-stETH Collateral Vault | `0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd` |
| EulerSwap Pool | TBD — Origin deploys via Maglev |
| Curator Fee Receiver | `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` |

### Reference Repos

| Repo | Local Path |
|---|---|
| EVC | `reference/ethereum-vault-connector/` |
| EVK | `reference/euler-vault-kit/` |
| evk-periphery | `reference/evk-periphery/` |
| Orderflow Router | `reference/euler-orderflow-router/` |
| Origin ARM | `reference/arm-oeth/` |

---

## 3. ARM Contract Interface

The ARM-WETH-stETH token (`LidoARM.sol` extending `AbstractARM.sol`) implements an ERC-4626-inspired but non-standard interface. This matters for the multiply flow and oracle design.

### Deposit (Instant) — WETH → ARM shares

```solidity
// Deposit WETH, receive ARM-WETH-stETH shares. Instant.
function deposit(uint256 assets) external returns (uint256 shares);
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function previewDeposit(uint256 assets) external view returns (uint256 shares);
```

Internally: `shares = assets * totalSupply() / totalAssets()`. Transfers WETH from caller via `transferFrom`.

### Redeem (Queued, Two-Step) — ARM shares → WETH

```solidity
// Step 1: Burn shares, queue withdrawal. Returns request ID.
function requestRedeem(uint256 shares) external returns (uint256 requestId, uint256 assets);

// Step 2: Claim after claimDelay (default 600s = 10 minutes).
function claimRedeem(uint256 requestId) external returns (uint256 assets);
```

There is **no instant `redeem()` or `withdraw()`**. This is critical for liquidation design.

### Exchange Rate

```solidity
function convertToShares(uint256 assets) public view returns (uint256 shares);
// shares = assets * totalSupply() / totalAssets()

function convertToAssets(uint256 shares) public view returns (uint256 assets);
// assets = shares * totalAssets() / totalSupply()

function totalAssets() public view returns (uint256);
```

The exchange rate is monotonically increasing (ARM profits accrue to `totalAssets`). This makes it suitable as an oracle source — similar to how wstETH/stETH uses an exchange rate oracle.

### Token Roles

| Role | Token | Notes |
|---|---|---|
| Liquidity asset (deposit/withdraw) | WETH | What LPs deposit |
| Base asset (traded) | stETH | What the ARM buys and redeems via Lido |
| Share token | ARM-WETH-stETH | The contract itself (ERC20Upgradeable) |

### Deposit Caps

Managed by a separate `CapManager` contract. Includes a global `totalAssetsCap` and optional per-LP `liquidityProviderCaps`. Can be disabled by setting capManager to `address(0)`.

**Source:** `reference/arm-oeth/src/contracts/AbstractARM.sol` (lines 530-572), `reference/arm-oeth/src/contracts/LidoARM.sol`

---

## 4. Euler Market Architecture

### Vault Cluster

Two EVK vaults in a cluster:

**Vault A — ARM-WETH-stETH (Collateral)**
- Asset: ARM-WETH-stETH (`0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6`)
- Role: Collateral-only vault (users deposit ARM shares here)
- Supply cap: TBD (start conservative, scale with Curve pool + ARM TVL)

**Vault B — WETH (Borrow)**
- Asset: WETH (`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`)
- Role: Lending vault where ETH lenders deposit and borrowers draw
- Interest rate model: KinkIRM tuned so utilization-target rate stays below ~3.5%

### Oracle Configuration (Deployed)

The EulerRouter uses `govSetResolvedVault` to resolve pricing via `convertToAssets`. Two resolved vaults create a recursive resolution chain:

```
ARM Collateral Vault → convertToAssets → ARM-WETH-stETH token
                     → convertToAssets → WETH (identity, done)
```

Both the collateral vault and the ARM token are registered as resolved vaults on the router (`0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3`). No Chainlink feed or custom oracle adapter needed — the unit of account is WETH, and ARM's `asset()` returns WETH, so the chain terminates at identity.

ARM's `convertToAssets` is monotonically increasing (profits accrue to `totalAssets`). Manipulation requires real WETH flows. Safe for oracle use.

### LTV / Liquidation Parameters

ARM-WETH-stETH is denominated in WETH (1 ARM share ≈ 1.0x WETH and growing). This is a correlated pair with low volatility — similar risk profile to wstETH/ETH.

| Parameter | Recommended Value | Rationale |
|---|---|---|
| Borrow LTV | 90% (9000 bps) | ARM/WETH is tightly correlated, exchange rate only goes up |
| Liquidation LTV | 93% (9300 bps) | 3% buffer before liquidation |
| Max Multiplier | ~9.5x (at 90% LTV) | `1/(1-0.90) - 0.005 = 9.995`, floored to 9.99 |
| Supply Cap (ARM) | Start at $2M, scale | Limit exposure while Curve pool liquidity grows |
| Borrow Cap (WETH) | Match ARM supply cap × LTV | Auto-scales with supply |

---

## 5. EulerSwap Pool — Borrow-to-Fill

### Pool Configuration

Origin deploys a single-LP EulerSwap pool for the ARM-WETH-stETH/WETH pair:

| Parameter | Recommended | Notes |
|---|---|---|
| Token 0 | WETH | |
| Token 1 | ARM-WETH-stETH | |
| LP | Origin's address | Single-LP, full control |
| Swap Fee | 0.01-0.05% | Tight spread — this is a correlated pair |
| Concentration | 95-99% | Extremely tight range — ARM/WETH barely moves |
| Equilibrium Price | ARM `convertToAssets(1e18)` / 1e18 | Current exchange rate |
| Borrow-to-Fill | Enabled | The whole point — JIT borrows WETH from Euler lending |

### How Borrow-to-Fill Works Here

When a trader wants to swap WETH → ARM-WETH-stETH via the EulerSwap pool:

1. Trader sends WETH to the pool
2. Pool needs ARM-WETH-stETH to give the trader
3. If the pool doesn't hold enough ARM-WETH-stETH, it **JIT-borrows** from Euler's lending reserves (if an ARM lending vault exists with available liquidity)
4. The incoming WETH serves as collateral for the borrow
5. Pool delivers ARM-WETH-stETH to trader

When a trader swaps ARM-WETH-stETH → WETH:

1. Trader sends ARM-WETH-stETH to the pool
2. Pool needs WETH to pay the trader
3. Pool **JIT-borrows WETH** from Euler lending
4. Incoming ARM-WETH-stETH serves as collateral
5. Pool delivers WETH to trader

The net effect: the pool can provide up to **50x its static liquidity** in effective depth. This makes Origin's pool competitive with much larger pools on Curve/Uniswap for ARM-WETH-stETH routing.

### DEX Aggregator Integration

EulerSwap pools are Uniswap V4 hook-compatible. The pool registers as a liquidity source and aggregators (1inch, CoWSwap, Paraswap) route through it when it offers the best price. The `euler-orderflow-router` API handles quote discovery.

---

## 6. Multiply (Leveraged Looping)

### Overview

Users can create leveraged long positions on ARM yield. This is not available anywhere else. The full loop happens atomically in a single EVC `batch()` call.

Example at 5x leverage with 10 ETH:
- Deposit 10 ETH worth of ARM-WETH-stETH
- Borrow 40 ETH
- Convert 40 ETH → ARM-WETH-stETH (via ARM `deposit()`)
- Total position: 50 ETH worth of ARM-WETH-stETH, 40 ETH debt
- Net yield: 5 × 4.79% - 4 × 3.5% = 23.95% - 14% = **~9.95% net APY** (vs 4.79% unleveraged)

### EVC Batch Sequence

The multiply transaction is a single `EVC.batch()` call containing these operations in order:

```
EVC.batch([
  // 1. Permit2 approval (if needed)
  Permit2.permit(ARM-WETH-stETH, amount, ...)

  // 2. Deposit user's ARM-WETH-stETH into collateral vault
  armCollateralVault.deposit(userArmAmount, subAccount)

  // 3. Enable borrow vault as controller for subAccount
  EVC.enableController(subAccount, wethBorrowVault)

  // 4. Enable ARM collateral vault as collateral for subAccount
  EVC.enableCollateral(subAccount, armCollateralVault)

  // 5. Borrow WETH, send to Swapper contract
  wethBorrowVault.borrow(debtAmount, swapperAddress)

  // 6. Swapper converts WETH → ARM-WETH-stETH
  Swapper.multicall([
    // 6a. GenericHandler calls ARM.deposit(wethAmount)
    swap(HANDLER_GENERIC, encode(armVaultAddress, ARM.deposit.selector(wethAmount)))
    // 6b. Sweep ARM tokens to collateral vault address
    sweep(armTokenAddress, 0, armCollateralVaultAddress)
  ])

  // 7. Verify output and skim into vault
  SwapVerifier.verifyAmountMinAndSkim(
    armCollateralVault, subAccount, minArmOut, deadline
  )

  // 8. Oracle price updates (if needed)
  pythUpdateCalls...
])
```

### How the Swap Step Differs from Standard Multiply

Standard euler-lite multiply uses DEX routes (Uniswap, 1inch, etc.) for the borrow-asset → collateral-asset conversion. For ARM, we use the same pattern as the **Balancer BPT multiply** (see `euler-lite-balancer`):

1. The "swap" is actually an **ERC-4626 deposit** — call `ARM.deposit(wethAmount)` to mint ARM shares
2. Routed through the Swapper's `GenericHandler` (not a DEX)
3. Uses `sweep()` (not `deposit()`) in the Swapper multicall — this is critical because `deposit()` consumes tokens internally, breaking `verifyAmountMinAndSkim`
4. Preview via `ARM.previewDeposit(amount)` for the quote

**Adapter contract is NOT strictly necessary** because ARM's `deposit()` takes WETH directly (no wrapping step). The GenericHandler can call ARM.deposit directly. However, an adapter may be useful for:
- Encapsulating approval + deposit in one call
- Adding slippage protection at the contract level
- Future flexibility if the deposit interface changes

### Quote Building

For the multiply quote, we build a `SwapApiQuote` object locally (no external API call needed):

```typescript
async function buildArmDepositQuote(
  wethAmount: bigint,
  slippagePercent: number,
  swapperAddress: Address,
  armAddress: Address,
  collateralVaultAddress: Address,
): Promise<SwapApiQuote> {
  // Preview the deposit on-chain
  const expectedArmOut = await readContract({
    address: armAddress,
    abi: armAbi,
    functionName: 'previewDeposit',
    args: [wethAmount],
  })

  const slippageBps = Math.round(slippagePercent * 100)
  const minArmOut = expectedArmOut * BigInt(10000 - slippageBps) / 10000n

  // Encode GenericHandler payload
  const armDepositCalldata = encodeFunctionData({
    abi: armAbi,
    functionName: 'deposit',
    args: [wethAmount],
  })

  const genericHandlerData = encodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes' }],
    [armAddress, armDepositCalldata],
  )

  // Build Swapper multicall items: swap + sweep
  const multicallItems = [
    {
      // swap via GenericHandler
      data: encodeFunctionData({
        abi: swapperAbi,
        functionName: 'swap',
        args: [HANDLER_GENERIC, wethAmount, genericHandlerData],
      }),
    },
    {
      // sweep ARM tokens to collateral vault
      data: encodeFunctionData({
        abi: swapperAbi,
        functionName: 'sweep',
        args: [armAddress, 0n, collateralVaultAddress],
      }),
    },
  ]

  return {
    amountIn: wethAmount.toString(),
    amountOut: expectedArmOut.toString(),
    amountOutMin: minArmOut.toString(),
    swap: {
      swapperAddress,
      multicallItems,
    },
    // ... other fields
  }
}
```

### Repay (De-leverage / Withdraw)

To unwind a multiply position, the user needs to convert ARM-WETH-stETH → WETH. Two options:

**Option A — Via EulerSwap Pool**
Route through the EulerSwap ARM/WETH pool. Fast and atomic. The pool's borrow-to-fill provides deep liquidity for the reverse direction too.

**Option B — Via Curve Pool + Aggregator**
Route ARM-WETH-stETH → OETH via the Curve pool (`0x95753095...`), then OETH → WETH via another route. Aggregators (Enso, 1inch) handle multi-hop.

**Option C — ARM requestRedeem (slow)**
Call `requestRedeem()` on the ARM contract, wait 10 minutes, then `claimRedeem()`. Not suitable for atomic repay within an EVC batch.

Recommendation: **Option A** (EulerSwap) for atomic repay within the multiply unwind batch. Fall back to aggregator routing (Option B) if the EulerSwap pool doesn't have sufficient liquidity for the repay size.

### Debt Safety Margin

Following the Balancer pattern, apply a safety reduction to the borrow amount to prevent `EVC_ControllerViolation` from price impact:

```typescript
const slippageBps = Math.round(slippage * 100)
const safetyBps = Math.max(slippageBps * 3, 100) // 3× slippage or 1% minimum
const adjustedDebt = rawDebt * BigInt(10000 - safetyBps) / 10000n
```

---

## 7. Liquidation Architecture

### The Challenge

ARM-WETH-stETH has no instant `redeem()`. The two-step withdrawal (`requestRedeem` → 10 min wait → `claimRedeem`) means liquidators cannot atomically convert ARM → WETH in a single transaction via the ARM contract.

### Solution: Dual Liquidation Path

**Primary — ERC-4626 Redemption (Delayed)**
- Liquidator seizes ARM-WETH-stETH collateral
- Calls `requestRedeem()` on the ARM contract
- Waits 10 minutes (claimDelay)
- Calls `claimRedeem()` to receive WETH
- Net cost: 10 minutes of time value, but 1:1 redemption at exchange rate

**Secondary — Curve Pool (Instant)**
- Liquidator seizes ARM-WETH-stETH
- Swaps ARM-WETH-stETH → OETH via Curve pool (`0x95753095...`)
- Swaps OETH → WETH via another DEX route
- Instant, but: Curve pool TVL is ~$105K currently — only handles small liquidations
- Slippage on large liquidations could be significant

**Tertiary — EulerSwap Pool (Instant, JIT)**
- Liquidator routes ARM-WETH-stETH → WETH through the EulerSwap pool
- Borrow-to-fill provides deep liquidity
- Best option once the EulerSwap pool is live and has sufficient LP capital

### Liquidation Bot Configuration

The Euler liquidation bot (`euler-xyz/euler-liquidation-bot`) needs to be configured with:
- ARM-WETH-stETH as a recognized collateral token
- Routing preference: EulerSwap pool > Curve pool > ARM requestRedeem
- Minimum profit threshold accounting for 10-min delay (if using requestRedeem path)

### Risk Mitigation

- **Conservative LTV** (90%) with 3% buffer to liquidation gives ample time
- **Supply caps** limit maximum exposure
- **Growing Curve pool liquidity** — as this integration launches, the Curve pool incentives and volume should grow, deepening the instant liquidation path
- **EulerSwap pool** provides the primary instant liquidation route once live

---

## 8. Frontend — euler-lite-origin

### Repository

Cloned to: `/Users/root1/AG-Euler/euler-lite-origin/`
Source: `https://github.com/rootdraws/ag-euler-lite` (development branch)

This follows the same pattern as `euler-lite-cork` and `euler-lite-balancer` — a dedicated fork for Origin with custom multiply logic.

### Labels Repo

GitHub: `rootdraws/ag-euler-origin-labels` (created, live). Structure:

```
1/
  products.json       # ARM vault products
  vaults.json         # Per-vault display config
  entities.json       # Origin entity branding
  points.json         # [] (no points programs initially)
  opportunities.json  # {} (no Cozy safety modules)
logo/
  origin.svg          # Origin Protocol logo
```

#### products.json (Chain 1 — Ethereum)

```json
{
  "origin-arm-weth": {
    "name": "Origin ARM / WETH",
    "description": "Borrow WETH against Origin's stETH ARM LP tokens. Multiply available.",
    "vaults": [
      "0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd",
      "0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B"
    ]
  }
}
```

#### entities.json

```json
{
  "origin": {
    "name": "Origin Protocol",
    "logo": "origin.svg",
    "website": "https://www.originprotocol.com",
    "addresses": []
  }
}
```

### Environment Variables

```bash
# Chain
RPC_URL_HTTP_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
NUXT_PUBLIC_SUBGRAPH_URI_1=https://api.goldsky.com/.../euler-simple-mainnet/latest/gn

# APIs
EULER_API_URL=https://indexer.euler.finance
SWAP_API_URL=https://swap.euler.finance
PRICE_API_URL=https://indexer.euler.finance

# Branding
NUXT_PUBLIC_CONFIG_APP_TITLE=Origin ARM × Euler
NUXT_PUBLIC_CONFIG_APP_DESCRIPTION=Leveraged yield on Origin's stETH ARM via Euler V2
NUXT_PUBLIC_CONFIG_LABELS_REPO=rootdraws/ag-euler-origin-labels
NUXT_PUBLIC_CONFIG_LABELS_REPO_BRANCH=main

# Pages
NUXT_PUBLIC_CONFIG_ENABLE_EARN_PAGE=false
NUXT_PUBLIC_CONFIG_ENABLE_LEND_PAGE=true
NUXT_PUBLIC_CONFIG_ENABLE_EXPLORE_PAGE=false

# Social
NUXT_PUBLIC_CONFIG_X_URL=https://x.com/OriginProtocol
NUXT_PUBLIC_CONFIG_DOCS_URL=https://docs.originprotocol.com

# Wallet
APPKIT_PROJECT_ID=YOUR_REOWN_PROJECT_ID
NUXT_PUBLIC_APP_URL=https://origin.alphagrowth.io
```

### Frontend Modifications Required

1. **ARM Deposit Adapter** — New composable (`composables/useArmDeposit.ts`) that builds the `SwapApiQuote` via `ARM.previewDeposit()` + GenericHandler encoding (see Section 6).

2. **Multiply Form Override** — Modify `useMultiplyForm.ts` to detect ARM collateral vaults and route through the ARM deposit adapter instead of the standard swap API. Same pattern as `euler-lite-balancer`'s `bptAdapterConfig`.

3. **ARM Adapter Config** — Add config map in `useDeployConfig.ts`:
   ```typescript
   armAdapterConfig: {
     '0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd': {
       armContract: '0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6',
       asset: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', // WETH
     }
   }
   ```

4. **Repay Routing** — For de-leverage (repay), route ARM-WETH-stETH → WETH via:
   - EulerSwap pool (preferred)
   - Aggregator fallback (Enso `/route` API, 1inch, etc.)

5. **Origin Branding** — Entity logo, theme colors, meta tags.

### Key Files to Modify (from euler-lite base)

| File | Change |
|---|---|
| `composables/borrow/useMultiplyForm.ts` | Add ARM adapter path (like Balancer's `bptAdapterConfig` check) |
| `composables/useDeployConfig.ts` | Add `armAdapterConfig` from env var |
| `composables/useEulerOperations/vault.ts` | No changes needed — `buildMultiplyPlan` is generic, consumes `SwapApiQuote` |
| `composables/useEnsoRoute.ts` or new `composables/useArmRoute.ts` | ARM deposit quote builder + repay routing |
| `entities/custom.ts` | Theme hue, intrinsic APY sources for ARM |
| `assets/styles/variables.scss` | Origin brand colors |
| `.env` | All env vars above |

---

## 9. Economics

### Yield Breakdown

| Source | Rate | Notes |
|---|---|---|
| ARM base yield | ~4.79% APY | stETH arbitrage + Morpho lending |
| Max borrow cost (breakeven) | ~3.5% | Above this, the spread goes negative |
| Target ETH lender rate | ~2.5-3.0% | ~1% above market ETH lending rates |
| Multiply net yield (5x) | ~9.95% | `5 × 4.79% - 4 × 3.5%` |
| Multiply net yield (3x) | ~8.37% | `3 × 4.79% - 2 × 3.5%` |
| EulerSwap fee income | 0.01-0.05% per swap | Accrues to Origin as LP |

### Interest Rate Model

Target: KinkIRM that keeps borrow rate at ~2.5% at normal utilization, rising steeply above 80% utilization to prevent full utilization.

```
Base rate:    0.5%
Kink rate:    2.5%  (at kink utilization)
Kink:         80%   (utilization)
Max rate:     50%   (at 100% utilization)
Slope 1:     (2.5% - 0.5%) / 80% = 2.5% per 100% util
Slope 2:     (50% - 2.5%) / 20% = 237.5% per 100% util
```

This ensures:
- Normal operation: ~2.5% borrow rate → 2.29% spread for ARM holders
- High utilization: rate spikes, discouraging over-borrowing
- ETH lenders earn: `2.5% × utilization × (1 - reserve_factor)`

### Origin's Revenue Streams

1. **EulerSwap LP fees** — 0.01-0.05% on every swap through their pool
2. **ARM yield spread** — The difference between ARM yield and borrow cost on their own looped positions
3. **Protocol growth** — More TVL in ARM → more fees → more OGN value

---

## 10. Risks and Open Questions

### Known Risks

| Risk | Severity | Mitigation |
|---|---|---|
| ARM withdrawal delay (10 min) | Medium | EulerSwap + Curve pool provide instant liquidation paths |
| Curve pool TVL ($105K) | Medium | Will grow with integration; EulerSwap pool is primary path |
| ARM exchange rate oracle manipulation | Low | Rate is monotonically increasing; manipulation requires real WETH flows |
| Lido slashing event | Low (systemic) | ARM's `claimRedeem` returns min(request-time, claim-time) value |
| ETH borrow rate exceeding ARM yield | Medium | KinkIRM design + Origin can manage pool params |

### Resolved Questions

1. **Oracle adapter**: No custom adapter needed. EulerRouter's `govSetResolvedVault` creates a recursive `convertToAssets` chain: Collateral Vault → ARM token → WETH. Deployed and working.

2. **EulerSwap deployment**: Origin deploys the EulerSwap pool via Maglev. Pending Origin action.

3. **Governance/multisig**: Deployer EOA currently holds governor role on the EulerRouter and vault parameters. Transfer to multisig TBD.

### Open Questions

4. **ARM deposit caps**: Will Origin whitelist the Euler Swapper contract for deposits? Or is CapManager disabled on the current deployment?

5. **Equilibrium price updates**: ARM exchange rate drifts up over time. Does the EulerSwap pool need periodic equilibrium price updates?

6. **Initial liquidity**: How much WETH does Origin want to seed the EulerSwap pool with? And how much ARM-WETH-stETH?

7. **ARM CapManager status**: Is the CapManager active on the deployed ARM contract? If per-LP caps are enabled, the Swapper contract needs an allowance.

8. **Supply/borrow caps**: Currently set to 0 (uncapped). Tighten via `setCaps()` once production-ready.

---

## 11. Reference Material

### Local Reference Repos

```
/Users/root1/AG-Euler/reference/
├── arm-oeth/                          # Origin ARM contracts (LidoARM, AbstractARM)
│   └── src/contracts/
│       ├── LidoARM.sol                # Lido-specific ARM (stETH withdrawals)
│       ├── AbstractARM.sol            # Core LP + swap + ERC-4626-like logic
│       ├── CapManager.sol             # Deposit cap management
│       └── Interfaces.sol             # IERC20, IStETHWithdrawal, etc.
├── ethereum-vault-connector/          # EVC — batch execution, controller/collateral mgmt
├── euler-vault-kit/                   # EVK — vault creation, oracle, LTV, IRM
├── evk-periphery/                     # Swapper, SwapVerifier, GenericHandler
└── euler-orderflow-router/            # Swap quote API for aggregator routing
```

### Frontend Fork

```
/Users/root1/AG-Euler/euler-lite-origin/     # Dedicated Origin euler-lite fork
```

### Key Euler Lite Files (in euler-lite-origin)

| Purpose | File |
|---|---|
| Multiply form logic | `composables/borrow/useMultiplyForm.ts` |
| EVC batch builder | `composables/useEulerOperations/vault.ts` → `buildMultiplyPlan()` |
| Leverage math | `utils/leverage.ts` → `getMaxMultiplier()` |
| Swap verification | `composables/useEulerOperations/swaps/verify.ts` |
| Deploy config | `composables/useDeployConfig.ts` |
| Labels fetcher | `composables/useEulerLabels.ts` |

### Analogous Implementation

The Balancer BPT multiply in `euler-lite-balancer` is the closest existing pattern:
- Uses `GenericHandler` for non-DEX swaps (Balancer `addLiquidityUnbalanced` instead of DEX trade)
- Preview via `ERC4626.previewDeposit()` + decimal scaling
- `sweep()` not `deposit()` in Swapper multicall
- Debt safety margin: `max(3× slippage, 1%)`
- Repay via Enso routing (not adapter in reverse)

See: `euler-lite-balancer/euler-lite-balancer-claude.md`, `balancer-contracts/balancer-claude.md`

### External Docs

- [How EulerSwap Works](https://docs.euler.finance/developers/euler-swap/how-it-works)
- [stETH ARM Docs](https://docs.originprotocol.com/automated-redemption-manager-arm/steth-arm)
- [ARM Tokens in DeFi](https://www.originprotocol.com/blog/arm-tokens-in-defi)
- [Origin ARM Vaults](https://www.originprotocol.com/arm)
- [Euler Vault Kit Docs](https://docs.euler.finance/developers/euler-vault-kit/)
- [EVC Docs](https://docs.euler.finance/developers/ethereum-vault-connector/)
- [Maglev (EulerSwap Pool Creator)](https://docs.euler.finance/creator-tools/maglev/)
