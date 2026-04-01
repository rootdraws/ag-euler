# Transaction Building & Composite Operations

This document describes how euler-lite constructs, simulates, and executes multi-step DeFi transactions through the Euler protocol.

## Overview

All Euler protocol interactions go through the **Ethereum Vault Connector (EVC)** `batch()` function, which executes multiple calls atomically. The transaction building system separates **planning** (what to do) from **execution** (how to do it) using a `TxPlan` abstraction.

## Core Concepts

### TxPlan

A transaction plan describes a complete operation as an ordered list of steps:

```typescript
interface TxPlan {
  kind: 'supply' | 'withdraw' | 'borrow' | 'repay' | 'full-repay'
      | 'savings-repay' | 'savings-full-repay' | 'swap-collateral-full-repay'
      | 'swap-savings-full-repay' | 'disable-collateral' | 'reward'
      | 'brevis-reward' | 'reul-unlock' | string
  steps: TxStep[]
}
```

### TxStep

Each step is a single contract call with metadata about its purpose:

```typescript
type TxStepType = 'approve' | 'permit2-approve' | 'evc-batch' | 'other'

interface TxStep {
  type: TxStepType
  label?: string
  to: Address
  abi: Abi
  functionName: string
  args: readonly unknown[]
  value?: bigint
}
```

Step types:
- **`approve`**: ERC-20 token approval (separate tx before the batch)
- **`permit2-approve`**: Permit2 signature-based approval (gasless)
- **`evc-batch`**: The main EVC `batch()` call containing all atomic operations
- **`other`**: Any other standalone transaction

### SaHooks

The Smart Account hooks system (`SaHooksBuilder`) structures operations as:

```
pre-hooks → main call → post-hooks
```

Each hook specifies:
- **Contract address** and **function call**
- **`isFromSAPerspective`**: Whether the call executes from the smart account's context or the user's context

```typescript
interface SaHooks {
  preHooks: PreHook[]
  postHooks: PostHook[]
  mainCallHook: MainCallHook
}
```

The builder provides semantic methods:
- `addPreHookCallFromSA()` / `addPreHookCallFromSelf()` — pre-operation setup
- `setMainCallHookCallFromSA()` / `setMainCallHookCallFromSelf()` — primary operation
- `addPostHookCallFromSA()` / `addPostHookCallFromSelf()` — post-operation cleanup

### EVCCall

The final format for EVC batch items:

```typescript
interface EVCCall {
  targetContract: Address
  onBehalfOfAccount: Address
  value: bigint
  data: Hash
}
```

## EVC Batching

All operations are submitted as an EVC `batch()` call for atomicity. The `convertSaHooksToEVCCalls()` utility in `utils/evc-converter.ts` transforms the hooks structure into an array of `EVCCall` objects:

1. Pre-hooks are converted to EVCCalls (preserving `onBehalfOfAccount` based on perspective)
2. Main call is converted
3. Post-hooks are converted
4. Additional calls (Pyth updates, TOS signing, Permit2) are prepended

The final batch is submitted via:

```typescript
writeContractAsync({
  address: evcAddress,
  abi: EVC_ABI,
  functionName: 'batch',
  args: [evcCalls],
  value: totalValue,  // Sum of all call values (e.g. Pyth update fees)
})
```

## Composite Operations

### Supply

Deposits assets into a vault.

**Steps**: `[permit2-approve?]` → `evc-batch(deposit)`

EVC batch calls:
1. *(Optional)* Permit2 signature call
2. *(Optional)* Terms of Use signing
3. `vault.deposit(amount, receiver)`

### Withdraw

Withdraws assets from a vault by specifying an asset amount.

**Steps**: `[permit2-approve?]` → `evc-batch(withdraw)`

EVC batch calls:
1. *(Optional)* Pyth price updates (if vault uses Pyth oracles)
2. *(Optional)* Permit2 / Terms of Use
3. `vault.withdraw(amount, receiver, owner)`

### Redeem

Withdraws by specifying a share amount (used for "max withdraw").

**Steps**: `evc-batch(redeem)`

EVC batch calls:
1. *(Optional)* Pyth price updates
2. *(Optional)* Permit2 / Terms of Use
3. `vault.redeem(shares, receiver, owner)`

### Borrow

Creates a new borrow position: deposits collateral, enables controller/collateral, and borrows.

**Steps**: `[permit2-approve?]` → `evc-batch(deposit + enableController + enableCollateral + borrow)`

EVC batch calls:
1. *(Optional)* Pyth price updates for both collateral and borrow vaults
2. *(Optional)* Permit2 / Terms of Use
3. `collateralVault.deposit(amount, subAccount)`
4. `evc.enableController(subAccount, borrowVault)`
5. `evc.enableCollateral(subAccount, collateralVault)`
6. `borrowVault.borrow(borrowAmount, receiver)`

### BorrowBySaving

Uses existing vault shares as collateral for a new borrow (no fresh deposit needed).

**Steps**: `evc-batch(transfer + enableController + enableCollateral + borrow)`

EVC batch calls:
1. *(Optional)* Pyth price updates
2. *(Optional)* Terms of Use
3. Pre-hook: `vaultShares.transfer(subAccount, amount)` — moves shares to sub-account
4. `evc.enableController(subAccount, borrowVault)`
5. `evc.enableCollateral(subAccount, collateralVault)`
6. `borrowVault.borrow(borrowAmount, receiver)`

### Repay

Repays a portion of borrowed debt.

**Steps**: `[permit2-approve?]` → `evc-batch(repay)`

EVC batch calls:
1. *(Optional)* Permit2 / Terms of Use
2. `borrowVault.repay(amount, subAccount)`

### FullRepay

Repays all debt and unwinds the position: repay → disable controller → disable all collaterals → transfer shares back to main account. Handles **all** collaterals enabled on the sub-account, not just the primary one.

**Steps**: `[permit2-approve?]` → `evc-batch(repay + disableController + [disableCollateral + transferFromMax] per collateral)`

EVC batch calls:
1. *(Optional)* Permit2 / Terms of Use
2. `borrowVault.repay(maxUint256, subAccount)` — repay all debt
3. `borrowVault.disableController()` — remove controller
4. For **each** collateral in the position:
   - `evc.disableCollateral(subAccount, collateralVault)` — remove collateral
   - `collateralVault.transferFromMax(subAccount, user)` — transfer all vault shares back to main account *(skipped if sub-account is the main account)*

### Multiply

Leveraged position: supply collateral, borrow, swap borrowed asset back to collateral, and supply the swapped amount. Uses a `SwapVerifier` for atomic swap execution.

**Steps**: `[permit2-approve?]` → `evc-batch(deposit + enableController + enableCollateral + borrow + swap with deposit)`

### CollateralSwap

Swaps one collateral asset for another within a borrow position. Withdraws from the source collateral vault, swaps the underlying asset via an external DEX, and the swapped tokens are deposited into the destination collateral vault by the `SwapVerifier`.

**Page**: `pages/position/[number]/collateral/swap.vue`

**Steps**: `evc-batch(withdraw + swapperMulticall + swapVerifier + enableCollateral)`

EVC batch calls:
1. *(Optional)* Pyth price updates from **borrow vault** oracle tree
2. *(Optional)* Terms of Use
3. `sourceVault.withdraw(amount, swapperAddress, subAccount)` — withdraw collateral to swapper
4. `swapper.multicall(swapData)` — execute DEX swap
5. `swapVerifier.verify(...)` — verify minimum output (SkimMin)
6. `evc.enableCollateral(subAccount, destinationVault)` — enable new collateral

Quote parameters: `vaultIn` = source collateral vault, `receiver` = destination collateral vault, `accountIn` = `accountOut` = sub-account, `isRepay` = false.

### DebtSwap

Swaps one borrow asset for another. Borrows from the new debt vault, swaps to the old debt asset, and repays the old debt via the `SwapVerifier`. Temporarily enables the new vault as controller, then disables the old one.

**Page**: `pages/position/[number]/borrow/swap.vue`

**Steps**: `evc-batch(enableController + borrow + swapperMulticall + swapVerifier + disableController)`

EVC batch calls:
1. *(Optional)* Pyth price updates from **current borrow vault** oracle tree
2. *(Optional)* Terms of Use
3. `evc.enableController(subAccount, newBorrowVault)` — enable new controller
4. `newBorrowVault.borrow(amount, swapperAddress)` — borrow new asset to swapper
5. `swapper.multicall(swapData)` — execute DEX swap
6. `swapVerifier.verify(...)` — verify debt repayment (DebtMax)
7. `oldBorrowVault.disableController()` — remove old controller *(if different from new)*

Quote parameters: `vaultIn` = new borrow vault, `receiver` = old borrow vault, `accountIn` = main account, `accountOut` = sub-account, `isRepay` = true.

### AssetSwap (Lend)

Swaps one lending position for another without a borrow position. Withdraws from the source vault, swaps via DEX, and deposits into the destination vault.

**Page**: `pages/lend/[vault]/swap.vue`

**Steps**: `evc-batch(withdraw + swapperMulticall + swapVerifier)`

EVC batch calls:
1. *(Optional)* Pyth price updates for source and destination vaults
2. *(Optional)* Terms of Use
3. `sourceVault.withdraw(amount, swapperAddress, user)` — withdraw to swapper
4. `swapper.multicall(swapData)` — execute DEX swap
5. `swapVerifier.verify(...)` — verify minimum output (SkimMin)

Quote parameters: `vaultIn` = source vault, `receiver` = destination vault, `accountIn` = `accountOut` = main account, `isRepay` = false.

### SavingsRepay

Repays a portion of borrow debt using assets from a savings (deposit) position on a different sub-account. Supports two paths depending on whether the savings vault and borrow vault share the same underlying asset.

**Page**: `pages/position/[number]/repay.vue` (savings tab)

**Steps**: `evc-batch(withdraw + skim + repayWithShares)` or `evc-batch(repayWithShares)` (same vault)

EVC batch calls (different underlying assets):
1. *(Optional)* Terms of Use signing
2. `savingsVault.withdraw(amount, borrowVaultAddress, savingsSubAccount)` — withdraw to borrow vault
3. `borrowVault.skim(amount, borrowSubAccount)` — credit skimmed tokens as shares
4. `borrowVault.repayWithShares(amount - 1, borrowSubAccount)` — burn shares to repay debt (1 wei less to handle rounding)

EVC batch calls (same underlying asset):
1. *(Optional)* Terms of Use signing
2. `savingsVault.repayWithShares(amount, borrowSubAccount)` — directly burns savings shares to repay borrow debt on the other sub-account (avoids vault cash liquidity requirements)

**No Pyth updates**: Savings deposits should not have an active borrow, so no health check is triggered on the savings sub-account.

### SavingsFullRepay

Fully repays all borrow debt from savings shares, unwinds the borrow position, and returns excess assets to the savings vault. Handles both same-vault and cross-vault paths.

**Page**: `pages/position/[number]/repay.vue` (savings tab, full repay)

**Steps**: `evc-batch(withdraw + skim + repayWithShares(max) + redeem(max) + skim-back + disableController + [disableCollateral + transferFromMax] per collateral + transferFromMax savings)`

EVC batch calls (different underlying assets):
1. *(Optional)* Terms of Use signing
2. `savingsVault.withdraw(adjustedAmount, borrowVaultAddress, savingsSubAccount)` — withdraw with 0.01% interest padding
3. `borrowVault.skim(adjustedAmount, borrowSubAccount)` — credit as shares
4. `borrowVault.repayWithShares(maxUint256, borrowSubAccount)` — repay all debt
5. `borrowVault.redeem(maxUint256, savingsVaultAddress, borrowSubAccount)` — return excess to savings vault
6. `savingsVault.skim(preExistingBorrowDeposit, savingsSubAccount)` — re-deposit returned tokens
7. `borrowVault.disableController()` — remove controller
8. For **each** collateral: `evc.disableCollateral()` + `collateralVault.transferFromMax()` — unwind collateral
9. `savingsVault.transferFromMax(savingsSubAccount, user)` — return remaining savings shares to main account

EVC batch calls (same underlying asset):
1. *(Optional)* Terms of Use signing
2. `savingsVault.repayWithShares(maxUint256, borrowSubAccount)` — burn shares to repay all debt
3–9. Same cleanup sequence as above

**No Pyth updates**: Batch ends with `disableController`, so no health check runs.

### SwapFullRepay

Fully repays all borrow debt using a cross-asset swap (from collateral or savings), then unwinds the entire borrow position. This is a unified builder (`buildSwapFullRepayPlan`) that accepts a `source: 'collateral' | 'savings'` parameter to determine which end of the swap is the sub-account for position cleanup.

**Page**: `pages/position/[number]/repay.vue` (collateral or savings tab, cross-asset full repay)

**Steps**: `evc-batch(swap calls + disableController + [disableCollateral + transferFromMax] per collateral)`

EVC batch calls:
1. Swap EVC calls from `buildSwapEvcCalls()` (withdraw/borrow → swapper multicall → swap verifier)
2. `borrowVault.disableController()` — remove controller
3. For **each** collateral: `evc.disableCollateral(subAccount, collateral)` — remove collateral
4. For **each** collateral (if sub-account ≠ main account): `collateral.transferFromMax(subAccount, user)` — return shares

The `source` parameter controls the sub-account address used for cleanup:
- `'collateral'`: uses `quote.accountIn` (the collateral sub-account)
- `'savings'`: uses `quote.accountOut` (the borrow sub-account)

**No Pyth updates**: Batch ends with `disableController`, so no health check runs.

### DisableCollateral

Removes a collateral vault from a borrow position by transferring all shares back to the main account and disabling it on the EVC.

**Steps**: `evc-batch(transferFromMax + disableCollateral)`

EVC batch calls:
1. *(Optional)* Pyth price updates (from `borrowVaultAddress` oracle tree when provided)
2. *(Optional)* Terms of Use
3. `vault.transferFromMax(subAccount, user)` — transfer all vault shares back to main account *(skipped if sub-account is the main account)*
4. `evc.disableCollateral(subAccount, vault)` — remove vault from enabled collaterals

## Permit2 Integration

Permit2 provides gasless token approvals via EIP-2612 signatures instead of on-chain `approve()` transactions.

**Flow**:
1. Check if chain supports Permit2 (`resolvePermit2Address()`)
2. Ensure the token has a max approval to the Permit2 contract (`ensurePermit2TokenApproval()`)
3. Build a Permit2 signature call (`buildPermit2Call()`) with:
   - Token address, spender (vault), amount
   - Expiration (`MAX_UINT48`) and deadline
   - User signs the permit off-chain
4. The signed permit call is prepended to the EVC batch

**Fallback**: If Permit2 fails (unsupported token, user rejects signature), the system falls back to a standard ERC-20 `approve()` transaction.

## Sub-accounts

The EVC supports 256 sub-accounts per user address. Sub-accounts enable **position isolation** — each borrow position uses a separate sub-account so that collateral and controller state don't interfere.

- `getNewSubAccount(address)` finds the next available sub-account index
- Sub-accounts share the same address prefix with different suffixes
- Collateral is deposited to the sub-account, not the main account
- The sub-account is set as `onBehalfOfAccount` for controller/collateral operations

## Execution & Simulation

### `executeTxPlan(plan)`

Executes each step of a `TxPlan` sequentially:
1. For each `TxStep`, calls `writeContractAsync()` with the step's parameters
2. Waits for transaction receipt before proceeding to the next step
3. Returns the final transaction hash

### `simulateTxPlan(plan)`

Simulates a plan without sending transactions, used for previewing outcomes:

1. Builds **state overrides** that simulate token approvals and Permit2 allowances
2. Calls `simulateContract()` with the overrides
3. Returns the simulated result (e.g. expected shares received)

State overrides are computed by:
- `buildErc20AllowanceOverrides()` — sets ERC-20 allowance storage slots to max
- `buildPermit2Overrides()` — sets Permit2 allowance storage slots
- `resolveAllowanceSlotIndex()` — determines the correct storage slot for the token's allowance mapping

## Pyth Updates in Transactions

Operations that trigger an EVC health check need Pyth price updates for all relevant feeds. The key insight is that the **liability (borrow) vault's oracle tree** contains all Pyth feeds needed for the health check — both collateral and liability pricing — because the EVC reads oracles for all enabled collaterals and the controller.

All position-aware operations pass the liability vault address to `preparePythUpdates()`:

```typescript
const pythTarget = liabilityVault ? [liabilityVault] : [vaultAddr]
const { calls: pythCalls } = await preparePythUpdates(pythTarget, userAddr)
if (pythCalls.length) {
  evcCalls.unshift(...pythCalls)
}
```

The `preparePythUpdates()` function:
1. Resolves vault addresses to vault objects from the registry
2. Calls `buildPythUpdateCalls()` to create `EVCCall[]` for Pyth `updatePriceFeeds()`
3. Returns both the calls and the total fee (sent as `msg.value`)

Operations that include Pyth updates: **borrow**, **borrowBySaving**, **withdraw** (with sub-account), **disableCollateral**, **collateralSwap**, **debtSwap**, **assetSwap**, **multiply**.

**Not included**: Supply, repay, savingsRepay, savingsFullRepay, and swapFullRepay don't need Pyth updates — supply/repay don't trigger health checks, and the full-repay variants end with `disableController` which bypasses the health check.

For operations with a borrow position, only the borrow vault address is passed (e.g. `preparePythUpdates([borrowVaultAddr])`). For **withdraw** and **disableCollateral**, the `borrowVaultAddress` parameter is passed from the call site. Swap operations also accept a `liabilityVault` parameter; when not provided, they default to updating feeds for `[vaultIn, receiver]`.

See [Pyth Oracle Handling](./pyth-oracle-handling.md) for the full Pyth architecture.

## Files

| File | Purpose |
|------|---------|
| `composables/useEulerOperations/` | Modular operation builder directory |
| `composables/useEulerOperations/index.ts` | Orchestrator composable, re-exports 24-function API |
| `composables/useEulerOperations/types.ts` | `OperationsContext` and helper interfaces |
| `composables/useEulerOperations/helpers.ts` | Shared helpers: token approval, TOS, Pyth injection, EVC batch step |
| `composables/useEulerOperations/permit2.ts` | Permit2 resolution, allowance query, call building |
| `composables/useEulerOperations/allowance.ts` | ERC20 allowance checks, slot computation, simulation overrides |
| `composables/useEulerOperations/execution.ts` | `executeTxPlan`, `simulateTxPlan` |
| `composables/useEulerOperations/vault.ts` | Supply, withdraw, redeem, borrow, borrowBySaving, multiply |
| `composables/useEulerOperations/repay.ts` | Repay, fullRepay, disableCollateral, savingsRepay, savingsFullRepay |
| `composables/useEulerOperations/swaps/` | Swap operation builders (4 files) |
| `composables/useEulerOperations/swaps/same-asset.ts` | Same-asset swap, repay, full repay, and debt swap plans |
| `composables/useEulerOperations/swaps/cross-asset.ts` | Cross-asset swap and swap full repay plans |
| `composables/useEulerOperations/swaps/supply-borrow.ts` | Swap-and-supply, swap-and-borrow, withdraw-and-swap, redeem-and-swap |
| `composables/useRepaySavingsOptions.ts` | Savings position selection for repay-from-savings flow |
| `entities/txPlan.ts` | `TxPlan` and `TxStep` type definitions |
| `entities/saHooksSDK.ts` | `SaHooksBuilder` for constructing hook sequences |
| `utils/evc-converter.ts` | `convertSaHooksToEVCCalls()` and `EVCCall` type |
| `entities/permit2.ts` | Permit2 ABI, types, and constants |
| `abis/evc.ts` | EVC contract ABI |
| `utils/pyth.ts` | Pyth update call building |
