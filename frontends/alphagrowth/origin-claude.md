# Origin ARM × Euler — Frontend Context

AI context file for the **euler-lite-origin** frontend fork. For the full integration spec see `../origin-contracts/origin-arm-euler-spec.md`.

---

## What This Is

A dedicated euler-lite fork for the Origin ARM × Euler integration on Ethereum mainnet. Users can:

1. **Deposit ARM-WETH-stETH as collateral** and borrow WETH
2. **Multiply (leverage loop)** ARM-WETH-stETH/WETH positions atomically
3. **Supply WETH** to earn elevated lending yield

---

## Key Addresses (Ethereum Mainnet)

| Contract | Address |
|---|---|
| ARM-WETH-stETH (LP token + vault) | `0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| OETH | `0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3` |
| Curve Pool (OETH/ARM-WETH-stETH) | `0x95753095f15870acc0cb0ed224478ea61aeb0b8e` |
| ARM Collateral Vault (Euler) | `0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd` |
| WETH Borrow Vault (Euler) | `0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B` |
| EulerRouter (oracle) | `0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3` |
| KinkIRM | `0xa3AC336b108E698d5e96D96F9E1b56dAa9B28bcC` |
| EulerSwap Pool (ARM/WETH) | TBD — Origin deploys via Maglev |

---

## Implementation Summary

### Files Created

| File | Purpose |
|---|---|
| `abis/arm.ts` | Origin ARM contract ABI (deposit, previewDeposit, convertToAssets, etc.) |
| `composables/useArmRoute.ts` | ARM deposit quote builder: `previewArmDeposit()` + `buildArmSwapQuote()` |

### Files Modified

| File | Change |
|---|---|
| `composables/useDeployConfig.ts` | Added `ArmAdapterEntry` interface, `parseArmAdapterConfig()`, `armAdapterConfig` field |
| `composables/useSwapQuotesParallel.ts` | Added `requestCustomQuote()` method for injecting custom quotes |
| `composables/borrow/useMultiplyForm.ts` | Added ARM adapter branch: checks `armAdapterConfig` before standard Euler Swap API |
| `nuxt.config.ts` | Registered `configArmAdapterConfig` in runtimeConfig.public |
| `entities/custom.ts` | Theme hue set to 210 (Origin blue) |
| `.env.example` | Origin branding, labels repo, ARM adapter config placeholder |

### How the ARM Adapter Branch Works

In `useMultiplyForm.ts`, the swap quote request checks `armAdapterConfig` (keyed by collateral vault address). If a match is found:

1. Calls `previewArmDeposit()` → `ARM.previewDeposit(wethAmount)` on-chain
2. Applies slippage → `minArmOut`
3. Calls `buildArmSwapQuote()` which encodes:
   - `Swapper.swap(HANDLER_GENERIC, ...)` with `ARM.deposit(wethAmount)` as the payload
   - `Swapper.sweep(armToken, 0, collateralVault)` to transfer ARM tokens
   - `SwapVerifier.verifyAmountMinAndSkim(...)` for slippage protection
4. Returns a `SwapApiQuote` consumed by `buildMultiplyPlan()` unchanged

The GenericHandler in the Swapper automatically approves WETH to the ARM contract via `setMaxAllowance`, so no adapter contract is needed.

### EVC Batch Flow (Multiply)

```
EVC.batch([
  Permit2 approval,
  armCollateralVault.deposit(userArmAmount, subAccount),
  EVC.enableController(subAccount, wethBorrowVault),
  EVC.enableCollateral(subAccount, armCollateralVault),
  wethBorrowVault.borrow(debtAmount, swapperAddress),
  Swapper.multicall([
    swap(HANDLER_GENERIC → ARM.deposit(wethAmount)),
    sweep(armToken, 0, armCollateralVaultAddress),
  ]),
  SwapVerifier.verifyAmountMinAndSkim(armCollateralVault, subAccount, minArmOut, deadline),
])
```

### Repay Direction

Standard Euler Swap API providers handle ARM-WETH-stETH → WETH routing via DEX aggregators (1inch, Paraswap). No custom repay logic needed — ARM has no instant redeem, but aggregators route through available on-chain liquidity (Curve pool, EulerSwap once live).

---

## ARM Contract Interface

ARM-WETH-stETH is **ERC-4626-inspired but not fully compliant**:

- `deposit(uint256 assets)` — instant, takes WETH, mints ARM shares to `msg.sender`
- `previewDeposit(uint256 assets)` — view, returns expected shares
- **No instant `redeem()` or `withdraw()`** — two-step async:
  - `requestRedeem(uint256 shares)` → burns shares, queues withdrawal
  - `claimRedeem(uint256 requestId)` → callable after 10 min delay
- `convertToAssets(uint256 shares)` — exchange rate (monotonically increasing)

**Source:** `../reference/arm-oeth/src/contracts/AbstractARM.sol`, `LidoARM.sol`

---

## Configuration

### Env Var: `NUXT_PUBLIC_CONFIG_ARM_ADAPTER_CONFIG`

JSON string mapping Euler collateral vault address to ARM contract details:

```json
{
  "0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd": {
    "armContract": "0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6"
  }
}
```

This is the deployed ARM collateral vault address. The `armContract` field points to the Origin ARM-WETH-stETH contract.

---

## Labels Repo

GitHub: `rootdraws/ag-euler-origin-labels` — contains `1/products.json`, `1/vaults.json`, `1/entities.json`, `1/points.json`, `1/opportunities.json`, and `logo/`.

Configured via `NUXT_PUBLIC_CONFIG_LABELS_REPO=rootdraws/ag-euler-origin-labels` in `.env`.

---

## Reference Repos

| Repo | Path |
|---|---|
| Origin ARM contracts | `../reference/arm-oeth/src/contracts/` |
| EVC | `../reference/ethereum-vault-connector/` |
| EVK | `../reference/euler-vault-kit/` |
| evk-periphery | `../reference/evk-periphery/` |
| Orderflow Router | `../reference/euler-orderflow-router/` |

---

## Gotchas

1. **ARM is NOT full ERC-4626.** No instant `redeem()`. Two-step async with 10-min delay.
2. **`sweep()` not `deposit()`** in Swapper multicall. `deposit()` consumes tokens, breaking `verifyAmountMinAndSkim`.
3. **ARM CapManager** may restrict deposits. The Euler Swapper contract may need whitelisting.
4. **Exchange rate is monotonically increasing.** Only a Lido slashing event could reduce it.
5. **Curve pool for liquidation is thin** (~$105K TVL). EulerSwap pool is the primary instant liquidation route once live.
