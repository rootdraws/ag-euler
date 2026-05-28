# Rollover Settlers — Complete Test Specification

> Covers the three settler contracts in `rollover-phoenix-private` per RFC 003 (`003-underwriter-rollover-intent.md`) and the dual-settler extension (`003-partial-fill-dual-settler.md`): `BaseSettler` (abstract), `ExactFillSettler`, `PartialFillSettler`.
>
> Tests are structured using the **Branching Tree Technique (BTT)**: one `.tree` file per function defines the control-flow tree; each leaf (`it should ...`) becomes a test case. Trees are the source of truth.
>
> **Test organization:** Co-located — each `.tree` file lives next to its `.t.sol` in the same domain folder.
>
> **Mocking policy:** Use the **real** `CorkCellar` + `CorkCellarFactory` from a `lib/cellar` submodule pointing at [Cork-Technology/cellar-private](https://github.com/Cork-Technology/cellar-private). Reuse Phoenix's `CorkPoolManagerMock`, `SharesFactory`, `DummyERC20`, `DummyWETH` via the cellar's `BaseTestCorkCellar`. Deploy a real rhinestone `Registry` per cellar-private's ceremony. Only the **premium-payments ERC-6909 contract** is new to this repo and gets a real implementation (not a mock). No new mocks unless unavoidable.

---

## Table of Contents

1. [Test Methodology](#1-test-methodology)
2. [Test Infrastructure](#2-test-infrastructure)
3. [Contract Surface Summary](#3-contract-surface-summary)
4. [BaseSettler](#4-basesettler)
5. [ExactFillSettler](#5-exactfillsettler)
6. [PartialFillSettler](#6-partialfillsettler)
7. [ERC6909Premium](#7-erc6909premium)
8. [Supporting Libraries](#8-supporting-libraries)
9. [Integration Tests](#9-integration-tests)
10. [Invariant Tests](#10-invariant-tests)
11. [Summary](#11-summary)
12. [Invariant Coverage Matrix](#12-invariant-coverage-matrix)
13. [File Layout](#13-file-layout)
14. [PR Chunking](#14-pr-chunking)

---

## 1. Test Methodology

### Branching Tree Technique (BTT)

Every external/public function gets a `.tree` file that mirrors its code's validation order top-to-bottom. Each `when` node is a decision point; each `it should` leaf is a test case. The `.tree` file lives in the **same directory** as its `.t.sol` test file.

**Tree → Solidity mapping:**
- Root node → test contract name (e.g., `ExactFillSettler_fill`)
- `when` nodes → `modifier when<Condition>() { _; }` in the test contract
- `it should` leaves → `function test_<What>() external when<A> when<B> { ... }`
- `test_RevertWhen_<Condition>` for revert branches
- `test_<functionName>_<whatItDoes>` for success branches

**Scaffolding:** Use [`bulloak`](https://github.com/alexfertel/bulloak) to generate Solidity test stubs from `.tree` files, and `bulloak check` in CI to keep trees and tests in sync. Matches the cellar-private convention.

**One test contract per function.** Each inherits `BaseTestSettler` and tests exactly one entry point.

### Fuzz & Invariant Fuzzing

- Handler contracts expose bounded actions and maintain ghost state. Invariant contracts target the handler and assert one RFC property per `invariant_` function.
- Per-function fuzz tests cover value ranges on `orderSize`, `fillAmount`, `minPremiumPerShare`, and timing windows.

### Shared behavior lives in `BaseSettler` tests

`BaseSettler` is abstract. Its behavior — signature recovery, EIP-712 domain construction, factory-forwarding helper, premium-debit helper — is exercised through both concrete settlers' trees (duplication is deliberate: each concrete has its own EIP-712 domain, so the same shared guard can have distinct revert surfaces under each). A thin `test/base/MockBaseSettler.sol` test harness is provided for properties that are implementation-agnostic (e.g., `domainSeparator()` correctness, ECDSA + ERC-1271 dispatch).

---

## 2. Test Infrastructure

### 2.1 Version alignment

Bump `rollover-phoenix-private` from Solc **0.8.26** → **0.8.30** and EVM `cancun` → `prague` to match cellar-private. Transient storage (EIP-1153) is available from `0.8.24+` on `cancun+`, so neither setting blocks the settler implementation, but matching cellar-private delivers deterministic builds across the shared dependency boundary, keeps CI and audit toolchains coherent (one pragma to lock, one optimizer profile to reproduce), and avoids version-skew noise in PR reviews. Pure-external-call interop doesn't require pragma parity, so this is a build-hygiene bump rather than a correctness requirement.

### 2.2 Remappings (addition to `remappings.txt`)

```text
cellar/=lib/cellar/src/
cellar-test/=lib/cellar/test/
phoenix/=lib/cellar/lib/phoenix/
registry/=lib/cellar/lib/registry/src/
registry-test/=lib/cellar/lib/registry/test/
solady/=lib/cellar/lib/solady/src/
openzeppelin-contracts/=lib/cellar/lib/openzeppelin-contracts/
@openzeppelin/contracts/=lib/cellar/lib/openzeppelin-contracts/contracts/
forge-std/=lib/cellar/lib/phoenix/lib/forge-std/src/
```

All cellar-reachable libraries route through the single `lib/cellar` submodule — keeps the transitive dependency set versioned by one SHA. `lib/phoenix` stays vendored at the rollover repo root **only if** cellar's Phoenix pin drifts; otherwise remove it in favor of `lib/cellar/lib/phoenix`.

**Submodule pinning policy.** `lib/cellar` is pinned to a reviewed SHA on `cellar-private/main`. Bumps follow the same PR-review cadence as source changes: open a PR titled `chore(deps): bump lib/cellar to <short-SHA>` that lists downstream breakage risks (ABI drift in `CorkCellar`, `CorkCellarFactory`, `ICorkCellar`, `CellarIntent` type hash, module set) and links the cellar-side release notes. CI caches `.git/modules/lib/cellar` keyed on the pinned SHA so unrelated commits don't invalidate the build cache. Never bump the submodule on a feature PR — always as a standalone PR. Cellar-side breaking changes get a coordinated release: cellar PR merges, submodule bump PR merges here, feature PRs rebase on top.

### 2.3 Test Harness (`BaseTestSettler`)

Inherits cellar-private's **`BaseTestCorkCellar`** (`lib/cellar/test/BaseTestCorkCellar.sol`), which already provides:

- Real rhinestone `Registry` with `MockResolver`, schema, module attestations
- Real `CorkCellarFactory` with default attesters threshold
- Real `CorkCellar` clone deployed per user via factory
- All six cellar modules deployed and attested
- Phoenix's `CorkPoolManagerMock`, `SharesFactory`, `DummyERC20`, `DummyWETH`
- `_signCellarIntent` / `_signCellarIntentWithSmartWallet` helpers
- Named actors (`alice`, `bob`, `bravo`, ...)

`BaseTestSettler` adds settler-specific infrastructure:

- Deploys **both concrete settlers** (`ExactFillSettler`, `PartialFillSettler`) pointing at the same `factory`. Settlers are deployment-time-bound to the factory.
- Deploys a fresh **`ERC6909Premium`** contract (the real implementation).
- Convenience allocators:
  - `_createRolloverOrder(uw, orderSize, allowPartialFills, allowUnderfill, settler)` → `GaslessCrossChainOrder` + `OrderData` + `CellarIntent` bundle
  - `_signOrder(order, uw, settler)` → `bytes` UW signature over settler domain
  - `_signCellarIntentFor(intent, uw, cellar)` → reuses cellar-private helper
  - `_buildFillerData(outputIndex, destination, debitFrom, targetFiller, intent, cellarSig)` → ABI-encoded `fillerData` per §5.4 (partial) or §5.5 (exact)
  - `_depositPremium(filler, token, amount)` → ERC-6909 deposit helper
  - `_advanceTo(fillDeadline + delta)` → `vm.warp` helper
- State-snapshot struct `SettlerSnapshot` with before/after helpers (escrow per order, per-filler rollovers, phase bits, ERC-6909 balances).

### 2.4 Signing helpers

- `_signOrder(GaslessCrossChainOrder order, Vm.Wallet uw, address settler)` — EOA EIP-712 signing over the **settler** domain (`name="CorkRolloverSettler"`, `version="1"`, `verifyingContract=settler`) per RFC 003 §A.1.
- `_signOrderWithSmartWallet(order, SmartWallet sw, address settler)` — ERC-1271 path; reuses the smart-wallet pattern from cellar-private.
- `_signCancel(order, uw, settler)` — maker-side cancel signature for the cancel path (§8.3 refund authorization parity).

### 2.5 Type-hash constants (verified in tests)

```text
GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH =
  keccak256("GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint256 openDeadline,uint256 fillDeadline,bytes32 orderDataType,bytes orderData)")

ORDER_DATA_TYPE_HASH =
  keccak256("OrderData(address receiver,MarketId srcPoolId,MarketId dstPoolId,address srcCstToken,address dstCstToken,address premiumToken,address repaymentToken,uint256 repaymentAmount,uint256 orderSize,bool allowPartialFills,bool allowUnderfill,uint256 minPremiumPerShare,bytes32 cellarIntentHash,Output[] outputs,Call[] rolloverHooks,Call[] premiumHooks)")

// NOTE: minFillRatio is NOT in the type hash — the extension at §5.2 line 127 removes it from OrderData.
// Any library test that hashes a pre-extension OrderData shape MUST fail the equality check against ORDER_DATA_TYPE_HASH.

CORK_ROLLOVER_ORDER_TYPE =
  keccak256("CorkRolloverOrder_v1")   // per RFC §A.2
```

The shared `CellarIntent` / `Call` type hashes are verified inside cellar-private. Settler tests use cellar-private's exported constants — no local redefinition.

### 2.6 Foundry profile

Same config as cellar-private: `via_ir = true`, `optimizer_runs = 1_000_000`, `evm_version = "prague"`, `solc = "0.8.30"`. No separate profiles for test runs.

---

## 3. Contract Surface Summary

Three concrete contracts + one library namespace. Per-contract function count governs tree coverage.

| Contract | External/Public Functions | Tree Files | Role |
|---|:---:|:---:|---|
| `BaseSettler` (abstract) | 2 view (`domainSeparator`, `orderStatus`) + internals | 4 | Shared signature, forwarding, premium-debit primitives (see §4) |
| `ExactFillSettler` | 8 | 8 | One-fill-per-order (RFC 003 parity) |
| `PartialFillSettler` | 10 | 10 | Cumulative multi-filler with per-filler state |
| `ERC6909Premium` | 6 | 6 | Filler prepaid balance + `settle()` |

Full function list and leaf counts are in §4–§7. **Total external/public functions: 26** across settlers + ERC-6909.

---

## 4. BaseSettler

**Abstract.** Not deployed standalone. Tested through a thin `MockBaseSettler` harness for behavior that's identical across both concrete settlers. Settler-domain-specific tests (fill flow, finalise) live in the concrete settler sections.

**4 tree files, ~26 leaves covering abstract surface.**

| Function | Tree File | Leaves | Covers |
|---|---|:---:|---|
| `domainSeparator()` | `base/BaseSettler_domainSeparator.tree` | 3 | EIP-712 domain correctness (`name`, `version`, `chainId`, `verifyingContract`); re-compute invariance; rejects replay under a different `verifyingContract` |
| `_recover(order, signature)` | `base/BaseSettler_recover.tree` | 11 | ECDSA recover, ERC-1271 fallback, malleable sig rejection, length checks, domain mismatch, bad smart-wallet magic, chain-id binding, empty sig |
| `_forwardToFactory(cellar, phase, intent, sig, fillAmount, filler)` | `base/BaseSettler_forwardToFactory.tree` | 6 | Factory-forwarding primitive: happy path returns `actualRolled`; bubbles `OverfillCeiling`, `UnderfillNotAllowed`, `ZeroRollover`, `SettlerMismatch`, `PremiumAlreadyFiredForFiller` without masking |
| `_settlePremium(tokenId, amount, debitFrom, premiumFiller, cellar)` | `base/BaseSettler_settlePremium.tree` | 6 | Premium-debit primitive: happy path debits via `ERC6909.settle`; `amount == 0` short-circuits (INV-S10); bubbles `InsufficientBalance`, `UnauthorizedSettler`, `UnauthorizedPremiumFiller`; atomic revert leaves no partial state |

### 4.1 `domainSeparator` (3 NEW)

```
BaseSettler_domainSeparator
├── it should compute EIP-712 domain over the settler's own address
├── it should bind chainId at deploy time (rejected under a chainId mismatch via caller-side signature check)
└── it should differ between two settler instances deployed on the same chain
```

### 4.2 `_recover` (11 NEW)

```
BaseSettler_recover
├── when signature is a raw ECDSA 65-byte
│   ├── when recovered signer equals order.user → it should return true
│   ├── when recovered signer differs → it should revert InvalidSignature
│   ├── when signature is 64 bytes (EIP-2098 compact) and recovers to user → it should return true
│   ├── when s is in the upper half (malleable) → it should revert InvalidSignature
│   └── when signature length is not 64 nor 65 → it should revert InvalidSignature
├── when order.user has code (smart wallet path)
│   ├── when isValidSignature returns MAGIC (0x1626ba7e) → it should return true
│   ├── when isValidSignature returns any other value → it should revert InvalidSignature
│   ├── when isValidSignature reverts → it should revert InvalidSignature
│   └── when wallet selfdestructs mid-verification → it should revert InvalidSignature
└── when verifying a signature produced for a DIFFERENT settler's domain
    └── it should revert InvalidSignature (cross-settler replay guard)
```

### 4.3 `_forwardToFactory` (6 NEW)

```
BaseSettler_forwardToFactory
├── when factory call succeeds → it should return actualRolled (uint256) to the caller
├── when cellar reverts OverfillCeiling → it should bubble the selector unmodified
├── when cellar reverts UnderfillNotAllowed → it should bubble
├── when cellar reverts ZeroRollover → it should bubble
├── when cellar reverts SettlerMismatch → it should bubble (closes §10.11 griefing vector — factory's transient slot correctly identifies the forwarding settler)
└── when cellar reverts PremiumAlreadyFiredForFiller on phase 1 → it should bubble (per-filler replay guard, INV-P17)
```

### 4.4 `_settlePremium` (6 NEW)

```
BaseSettler_settlePremium
├── when amount == 0 → it should no-op via ERC-6909 short-circuit (INV-S10) and still return true
├── when debitFrom has sufficient ERC-6909 balance AND dual-auth passes → it should debit and IERC20.safeTransfer to cellar, emit Settled
├── when debitFrom balance < amount → it should revert InsufficientBalance (bubbled from ERC-6909)
├── when msg.sender not authorized by debitFrom → it should revert UnauthorizedSettler
├── when premiumFiller not authorized by debitFrom → it should revert UnauthorizedPremiumFiller (dual-auth, INV-E2)
└── when ERC-6909's internal IERC20.safeTransfer reverts → whole call reverts; ERC-6909 balance stays unchanged (EINV-3, no phantom debit)
```

---

## 5. ExactFillSettler

**8 functions, 8 tree files, ~71 NET NEW leaves.** All tests are new — no prior suite to inherit from.

> **Lifecycle reminder (RFC 003 lines 269, 664, 2055, 2320, 2932, 3028).** `open/openFor` are **idempotent** on `Opened` — duplicate calls are no-ops and do not revert. They revert only on terminal states (`Settled`, `Refunded`, `Cancelled`) and on validation failures. `fill()` does **not** transition order status: it records fillRecords (and runs `_settle()` on the premium leg, flipping `paymentSettled=true`) but status stays wherever it was (`None` if fill-before-open, `Opened` after a prior open). `finaliseAsSettled(orderId)` is the sole entry point that transitions `Opened → Settled` and transfers dstCST to the filler's destination — it must be called separately after both legs have filled. Fill-before-open is permitted; the flow is `fill(rollover) → fill(premium) → openFor → finaliseAsSettled` (or any re-ordering that ends with `finaliseAsSettled` having `status == Opened` and both legs filled).

| Function | Tree File | Leaves |
|---|---|:---:|
| `open(OnchainCrossChainOrder)` | `exact/ExactFillSettler_open.tree` | 6 |
| `openFor(GaslessCrossChainOrder,sig,originFillerData)` | `exact/ExactFillSettler_openFor.tree` | 10 |
| `resolve(OnchainCrossChainOrder) view` | `exact/ExactFillSettler_resolve.tree` | 4 |
| `resolveFor(GaslessCrossChainOrder,originFillerData) view` | `exact/ExactFillSettler_resolveFor.tree` | 5 |
| `fill(orderId,originData,fillerData)` | `exact/ExactFillSettler_fill.tree` | 22 |
| `finaliseAsSettled(orderId)` | `exact/ExactFillSettler_finaliseAsSettled.tree` | 7 |
| `finaliseAsRefunded(orderId,order)` | `exact/ExactFillSettler_finaliseAsRefunded.tree` | 9 |
| `finaliseAsCancelled(orderId,order,cancelSig)` | `exact/ExactFillSettler_finaliseAsCancelled.tree` | 8 |

### 5.1 `open` (6 NEW)

```
ExactFillSettler_open
├── when msg.sender != order.user → it should revert NotMaker
├── when srcCstToken == premiumToken → it should revert InvalidOrderTokenPair (INV-S15)
├── when orderData.allowPartialFills == true → it should revert InconsistentIntent
├── when status is Settled/Refunded/Cancelled → it should revert InvalidOrderStatus (terminal)
├── when status is None and validation passes
│   ├── it should transition status to Opened
│   └── it should emit Open with a fully resolved order (repaymentTo == address(0); onchain orders carry no originFillerData)
└── when status is already Opened → it should no-op idempotently and NOT emit Open again (RFC 003 line 269, 2055)
```

### 5.2 `openFor` (10 NEW)

`originFillerData` is ABI-encoded `OriginFillerData { uint256 outputAmount; address repaymentTo; }` per RFC 003 §A.11 lines 3556–3559. `outputAmount` only affects `resolveFor()`-returned `fillInstructions`; it is **not** recorded at `openFor` time and **not** read at `fill()` time. `repaymentTo` defaults the `openFor` relay incentive recipient; it is overridden by the recorded `rolloverFiller` if a fill-before-open already occurred (RFC 003 line 3558). The canonical `rolloverFiller` is derived from `fillRecords[orderId][rolloverOutputHash].filler` — not passed through `originFillerData`.

```
ExactFillSettler_openFor
├── when signature is EOA and valid
│   ├── it should transition status from None to Opened
│   ├── it should record repaymentTo (for the gasless incentive payout) from originFillerData.repaymentTo
│   └── it should emit Open with the resolved order
├── when signature is ERC-1271 valid → it should behave identically to the EOA path
├── when signature is invalid → it should revert InvalidSignature
├── (no openDeadline guard — RFC 003 line 671: "Cork's order logic uses only `fillDeadline` as the operational deadline")
├── when orderData.allowPartialFills == true → it should revert InconsistentIntent
├── when srcCstToken == premiumToken → it should revert InvalidOrderTokenPair (INV-S15)
├── when status is already Opened → it should no-op idempotently (RFC 003 line 2055, idempotent openFor)
├── when status is Settled/Refunded/Cancelled → it should revert InvalidOrderStatus
├── when fill-before-open occurred (rollover fillRecord exists before openFor lands)
│   └── it should still transition to Opened AND bind the recorded fillRecord.filler as the rolloverFiller precedence (RFC 003 line 3558: "overridden by rolloverFiller if fill preceded open")
└── when originFillerData is empty bytes → it should revert InvalidOriginFillerData (RFC 003 line 3566: "Always abi.encode(OriginFillerData) — never empty bytes")
```

### 5.3 `resolve` / `resolveFor` (4 + 5 NEW)

`resolve` covers: well-formed order returns `ResolvedCrossChainOrder` with two outputs (rollover, premium); `minReceived`/`maxSpent` reflect `orderSize` and `minPremiumPerShare`; `fillInstructions` encode `originData` byte-exact; view revert on `InvalidOrderTokenPair`.

`resolveFor` adds one leaf: the returned `fillInstructions[i].originData` uses `OriginFillerData.outputAmount` as the baked `Output.amount` (RFC 003 line 3562). A later fill with a different size simply calls `resolveFor` again with a fresh `OriginFillerData`.

### 5.4 `fill` (22 NEW)

```
ExactFillSettler_fill
├── when block.timestamp > order.fillDeadline → it should revert FillAfterDeadline
├── when orderStatus is Settled/Refunded/Cancelled → it should revert OrderInTerminalState (fill-before-open still permitted in None/Opened per RFC 003 line 664)
├── when orderData.allowPartialFills == true → it should revert InconsistentIntent
├── when orderData.srcCstToken == orderData.premiumToken → it should revert InvalidOrderTokenPair (fill-time INV-S15 enforcement per RFC line 543; required because fill-before-open permits filling before any open-time validation)
├── when fillerData.outputIndex == 0 (rollover leg)
│   ├── when output.amount != orderSize → it should revert PartialFillNotAllowed
│   ├── when fillRecords[orderId][rolloverOutputHash] already set → it should revert AlreadyFilled
│   ├── when intent hash mismatches od.cellarIntentHash → it should revert IntentNotBoundToOrder
│   ├── when CellarIntent decodes and hashes to od.cellarIntentHash
│   │   ├── it should forward factory.executeIntentHooks(.. phase=0, filler=msg.sender) and capture actualRolled
│   │   ├── it should observe dstCstProduced via dstCST balance delta on the settler (INV-S9, 1-wei tolerance against fillSize - leftover)
│   │   ├── it should record FillRecord { filler=msg.sender, dstCstProduced, filledAt=block.timestamp }
│   │   ├── it should pull leftover srcCST from RolloverModule to msg.sender
│   │   └── it should NOT transition orderStatus (remains None or Opened; RFC 003 line 2932)
│   └── when dstCstProduced + 1 < (fillSize - leftover) → it should revert DisproportionateOutput (INV-S9 solvency 1-wei tolerance)
├── when fillerData.outputIndex == 1 (premium leg)
│   ├── when rollover fill record does not exist → it should revert PremiumBeforeRollover (INV-S3 rollover-first)
│   ├── when fillRecords[orderId][premiumOutputHash] already set → it should revert AlreadyFilled
│   ├── when debitFrom has insufficient ERC-6909 balance → it should revert InsufficientBalance (bubbled from ERC-6909)
│   ├── when debitFrom does not authorize msg.sender → it should revert UnauthorizedSettler
│   ├── when debitFrom authorizes msg.sender (self or operator)
│   │   ├── it should debit requiredPremium via ERC6909.settle(debitFrom, msg.sender, tokenId, premium, cellar)
│   │   ├── it should forward factory.executeIntentHooks(.. phase=1, filler=rolloverFiller) — note filler is the rollover filler from fillRecords, NOT msg.sender
│   │   ├── it should flip paymentSettled=true (NOT status; orderStatus stays wherever it was per RFC 003 line 2932)
│   │   └── it should emit Fill for the premium output
│   ├── when requiredPremium == 0 → it should short-circuit the ERC-6909 debit but still fire phase-1 hooks and flip paymentSettled=true (INV-S10)
│   ├── when the cellar phase-1 premiumHooks revert after _settle has already debited ERC-6909 → the whole fill() must revert atomically; ERC-6909 balance unchanged (INV-S12 + EINV-3, no phantom debit)
│   └── when reentrant fill() attempted from inside premiumHooks → it should revert (nonReentrant)
└── when fillerData.outputIndex is not 0 nor 1 → it should revert InvalidOutputIndex
```

### 5.5 `finaliseAsSettled` (7 NEW)

```
ExactFillSettler_finaliseAsSettled
├── when orderStatus[orderId] != Opened → it should revert InvalidOrderStatus
│   └── specifically: status == None → InvalidOrderStatus (open/openFor has not been called yet — RFC 003 line 3028)
│   └── specifically: status == Settled/Refunded/Cancelled → InvalidOrderStatus (terminal)
├── when paymentSettled == false (premium leg never filled) → it should revert PaymentNotSettled (INV-S11)
├── when rollover fillRecord missing → it should revert InvalidFillRecord (INV-S11)
├── when status == Opened AND both legs filled AND paymentSettled == true
│   ├── it should transition status Opened → Settled (the ONLY status transition path to Settled, RFC 003 line 2320, 3028)
│   ├── it should dstCST.safeTransfer the escrowed amount to fillRecord.destination
│   └── it should emit OrderFinalised(orderId, Settled)
└── when called by any msg.sender → it should succeed (permissionless, RFC 003 line 2320)
```

### 5.6 `finaliseAsRefunded` (9 NEW)

Refund is callable only from `Opened`. RFC 003 line 612 says `finalise()` reverts in `None` — fill-before-open that is never followed by `open`/`openFor` leaves escrow stuck (the filler accepts that liveness risk). RFC 003 line 627 (state diagram) codifies `Opened → Refunded` as the sole transition.

```
ExactFillSettler_finaliseAsRefunded
├── when _hashOrder(order) != orderId → it should revert DigestMismatch
├── when block.timestamp <= order.fillDeadline → it should revert NotExpired (INV-S5)
├── when orderStatus == None → it should revert InvalidOrderStatus (RFC 003 line 612: "finalise() reverts" in None)
├── when orderStatus == Settled → it should revert OrderComplete (paymentSettled=true path)
├── when orderStatus == Refunded → it should revert InvalidOrderStatus (terminal)
├── when orderStatus == Cancelled → it should revert InvalidOrderStatus (terminal)
├── when orderStatus == Opened AND paymentSettled == true (premium already paid; should have gone through finaliseAsSettled) → it should revert OrderComplete
├── when orderStatus == Opened AND rollover leg filled AND paymentSettled == false (premium dodged)
│   ├── it should dstCST.safeTransfer the escrowed dstCstProduced to cellar (UW windfall)
│   ├── it should transition status Opened → Refunded
│   └── it should emit OrderFinalised(orderId, Refunded)
└── when orderStatus == Opened AND both legs un-filled → it should transition status Opened → Refunded but transfer zero tokens (terminalization only; keeper-friendly even for empty orders)
```

### 5.7 `finaliseAsCancelled` (8 NEW)

**Note on `cancelSig`:** RFC 003 does not pin a normative EIP-712 domain/schema for the maker cancel signature. This spec assumes a schema of the form `Cancel(bytes32 orderId,uint256 cancelDeadline)` under the settler's own EIP-712 domain — `cancelDeadline` is a **separate** field, distinct from `fillDeadline`, so UWs can issue a cancel-sig that expires independently of the order itself. Any implementation-level decision (separate domain, additional fields, or even a non-712 magic) is acceptable as long as the schema is fixed before test bodies are written. Tests treat `cancelSig` as implementation-schema-dependent; the leaves below are stable against schema choice.

Cancel is callable only from `Opened` (RFC 003 line 293: "Only when status is `Opened` and no fills are recorded."). Calling from `None` reverts with `InvalidOrderStatus` — the maker must `open`/`openFor` first if they want to cancel a not-yet-opened order (low-volume footgun; signing tools should surface). Calling after any fill reverts with `OrderHasFills` per RFC 003 line 293 ("the fills pre-empt cancellation").

```
ExactFillSettler_finaliseAsCancelled
├── when _hashOrder(order) != orderId → it should revert DigestMismatch
├── when status != Opened → it should revert InvalidOrderStatus
│   └── specifically: status == None → InvalidOrderStatus (RFC 003 line 293, 612)
│   └── specifically: status == Settled/Refunded/Cancelled → InvalidOrderStatus (terminal)
├── when ANY fill record exists for the order → it should revert OrderHasFills (INV-S6; RFC 003 line 293)
├── when status == Opened AND no fills AND msg.sender == order.user
│   ├── it should transition status Opened → Cancelled
│   └── it should emit OrderFinalised(orderId, Cancelled)
├── when status == Opened AND no fills AND msg.sender != order.user AND cancelSig is a valid maker cancel sig → it should succeed (gasless UW cancel support)
├── when cancelSig is invalid → it should revert NotMaker
├── when cancelSig signs a different orderId → it should revert NotMaker
└── when called after fillDeadline AND status == Opened AND no fills exist → it should still succeed (cancel and refund are independent paths; cancel gates on "no fills", not on deadline)
```

---

## 6. PartialFillSettler

**10 functions, 10 tree files, ~94 NET NEW leaves.** The complex settler — per-filler state and cumulative semantics drive deeper trees on `fill` and the two finalise paths.

> **Key binding (RFC 003 §A.7 vs §A.8).** `orderId` is ERC-7683's content-derived ID (includes `keccak256(orderData)`); `orderDigest` is the 19-field non-recursive hash used by the cellar for bitmask nonces and `CellarIntent` binding. Partial-settler state splits across the two:
>
> - keyed by `orderId`: `orderStatus` (ERC-7683 lifecycle, RFC 003 line 2445)
> - keyed by `orderDigest`: `fillerRollovers`, `totalDstCstEscrowed` (per-filler escrow accounting), and cellar-side `rolled`, `hookNonces`, `premiumFiredFor`
>
> Every function signature below uses the name that matches its primary lookup key. Any call that needs both keys derives `orderDigest` locally from the decoded order fields and never stores a cross-reference.

> **Lifecycle reminder.** Same rules as ExactFillSettler §5 preamble: `open/openFor` idempotent on `Opened`, `fill()` does not transition status, status transition `Opened → Settled` happens only when the per-order terminal condition is met per INV-P16 (`hookNonces[d] & 1 ≠ 0 ∧ totalDstCstEscrowed[d] == 0 ∧ ∀ a with srcCstProvided>0: f.finalised`) at the tail end of the last `finaliseAsSettled` call that drains escrow.

| Function | Tree File | Leaves |
|---|---|:---:|
| `open(OnchainCrossChainOrder)` | `partial/PartialFillSettler_open.tree` | 6 |
| `openFor(GaslessCrossChainOrder,sig,originFillerData)` | `partial/PartialFillSettler_openFor.tree` | 10 |
| `resolve(OnchainCrossChainOrder) view` | `partial/PartialFillSettler_resolve.tree` | 4 |
| `resolveFor(GaslessCrossChainOrder,originFillerData) view` | `partial/PartialFillSettler_resolveFor.tree` | 5 |
| `fill(orderId,originData,fillerData)` | `partial/PartialFillSettler_fill.tree` | 31 |
| `finaliseAsSettled(orderDigest,fillers[])` | `partial/PartialFillSettler_finaliseAsSettled.tree` | 10 |
| `finaliseAsRefunded(orderDigest,order,fillers[])` | `partial/PartialFillSettler_finaliseAsRefunded.tree` | 13 |
| `finaliseAsCancelled(orderId,order,cancelSig)` | `partial/PartialFillSettler_finaliseAsCancelled.tree` | 9 |
| `fillerRollovers(orderDigest,filler) view` | `partial/PartialFillSettler_fillerRollovers.tree` | 3 |
| `totalDstCstEscrowed(orderDigest) view` | `partial/PartialFillSettler_totalDstCstEscrowed.tree` | 3 |

### 6.1 `open` (6 NEW)

Mirrors ExactFillSettler §5.1 branch-for-branch with the partial-flag flipped:

```
PartialFillSettler_open
├── when msg.sender != order.user → it should revert NotMaker
├── when srcCstToken == premiumToken → it should revert InvalidOrderTokenPair (INV-S15)
├── when orderData.allowPartialFills == false → it should revert InconsistentIntent   (inverse of Exact)
├── when status is Settled/Refunded/Cancelled → it should revert InvalidOrderStatus
├── when status is None and validation passes → it should transition to Opened and emit Open
└── when status is already Opened → it should no-op idempotently
```

### 6.2 `openFor` (10 NEW)

Parity with Exact §5.2 (including `originFillerData = abi.encode(OriginFillerData{outputAmount, repaymentTo})` decoding and the RFC 003 line 3558 precedence override), with the partial-flag inversion:

```
PartialFillSettler_openFor
├── [leaves 1–4 identical to Exact §5.2]
├── when orderData.allowPartialFills == false → it should revert InconsistentIntent   (inverse)
├── [remaining leaves identical to Exact §5.2]
```

### 6.3 `resolve` / `resolveFor` (4 + 5 NEW)

`minReceived.amount` equals `orderSize * minPremiumPerShare / 1e18` (aggregate-premium reporting across all possible fillers) per RFC 003 §6.2 resolve semantics. `resolveFor` mirrors Exact §5.3 with the additional leaf on `outputAmount` baking.

### 6.4 `fill` (31 NEW)

No `minFillRatio` check (removed per extension §5.2 line 127 and INV-P2 numbering gap at extension line 500). Anti-spam derives from filler-paid unit economics and UW-favorable ceil-rounding on premium per extension §10.4.

```
PartialFillSettler_fill
├── when block.timestamp > order.fillDeadline → it should revert FillAfterDeadline
├── when orderStatus is Settled/Refunded/Cancelled → it should revert OrderInTerminalState
├── when orderData.allowPartialFills == false → it should revert InconsistentIntent
├── when orderData.srcCstToken == orderData.premiumToken → it should revert InvalidOrderTokenPair (fill-time INV-S15)
├── when intent hash mismatches od.cellarIntentHash → it should revert IntentNotBoundToOrder (INV-P18)
├── when fillerData.outputIndex == 0 (rollover leg)
│   ├── when targetFiller != msg.sender → it should revert TargetFillerMismatch (phase-0 self-deal guard)
│   ├── when destination == address(0) → it should revert InvalidDestination
│   ├── when f.srcCstProvided != 0 (filler already rolled) → it should revert AlreadyFilledByFiller (INV-P1)
│   ├── when cumulative + output.amount > orderSize → cellar reverts OverfillCeiling (bubbles, INV-C13)
│   ├── when cellar returns actualRolled == 0 → it should revert ZeroRollover (settler-side + cellar-side defense in depth, INV-C17)
│   ├── when allowUnderfill == false AND actualRolled < output.amount → cellar reverts UnderfillNotAllowed (bubbles)
│   ├── when actualRolled == output.amount (full source)
│   │   ├── it should write f.srcCstProvided = actualRolled
│   │   ├── it should observe f.dstCstProduced via dstCST balance delta
│   │   ├── it should write f.destination = fillerData.destination
│   │   ├── it should increment totalDstCstEscrowed[orderDigest]
│   │   ├── it should pull leftover srcCST from RolloverModule to msg.sender
│   │   └── it should NOT transition orderStatus (stays None or Opened)
│   ├── when actualRolled < output.amount AND allowUnderfill == true → same writes, f.srcCstProvided = actualRolled (smaller)
│   ├── when this fill brings cumulative to orderSize exactly → cellar flips phase-0 terminal bit AND deletes rolled[d] (INV-C15)
│   ├── when a subsequent rollover fill by any filler after phase-0 terminal → cellar reverts PhaseAlreadyConsumed (INV-P13)
│   └── when two concurrent fills race past ceiling → loser reverts OverfillCeiling (linearisation via cellar's single rolled[] slot, INV-P9)
├── when fillerData.outputIndex == 1 (premium leg)
│   ├── when f.srcCstProvided == 0 for targetFiller → it should revert NoRolloverLegForFiller (INV-P3)
│   ├── when f.premiumSettled == true → it should revert AlreadySettled
│   ├── when debitFrom == msg.sender → it should accept authorization
│   ├── when debitFrom != msg.sender AND isOperator(debitFrom, msg.sender) == true → it should accept
│   ├── when debitFrom != msg.sender AND isOperator false → it should revert UnauthorizedDebitFrom
│   ├── when msg.sender != targetFiller (anyone may settle another filler's premium on their behalf) → it should accept
│   ├── when all auth passes
│   │   ├── it should compute premium = ceilDiv(f.dstCstProduced * minPremiumPerShare, 1e18)
│   │   ├── it should debit via ERC6909.settle(debitFrom, msg.sender, tokenId, premium, cellar)
│   │   ├── it should flip f.premiumSettled = true
│   │   └── it should forward factory.executeIntentHooks(.. phase=1, filler=targetFiller) and the cellar flips premiumFiredFor[d][targetFiller]=true
│   ├── when the cellar phase-1 premiumHooks revert AFTER ERC-6909 debit → the whole fill() must revert atomically; ERC-6909 balance unchanged; f.premiumSettled unchanged (INV-S12 + EINV-3)
│   ├── when premiumFiredFor[d][targetFiller] already true → cellar reverts PremiumAlreadyFiredForFiller (bubbles, INV-P17)
│   └── when settler-identity binding fails at cellar (factory.originatingSettler() != intent.settler) → cellar reverts SettlerMismatch (bubbles, INV-C18 + §10.11)
├── when fillerData.outputIndex not in {0, 1} → it should revert InvalidOutputIndex
└── when reentrant fill from dstCST transferCallback → it should revert (nonReentrant, AS-P6)
```

### 6.5 `finaliseAsSettled` (10 NEW)

```
PartialFillSettler_finaliseAsSettled
├── when fillers[] is empty → it should no-op and return without emission
├── for each fillers[i]:
│   ├── when f.premiumSettled == false → it should skip (continue)
│   ├── when f.finalised == true → it should skip (idempotent)
│   ├── when f.refunded == true → it should skip (exclusive paths, INV-P4a)
│   └── otherwise:
│       ├── it should set f.finalised = true BEFORE any external call (CEI, INV-P10)
│       ├── it should decrement totalDstCstEscrowed[orderDigest] by f.dstCstProduced
│       ├── it should dstCST.safeTransfer(f.destination, f.dstCstProduced)
│       └── it should emit FillerFinalised(orderDigest, filler, f.dstCstProduced)
├── when the last in-escrow filler is finalised AND phase-0 terminal bit is set → it should transition orderStatus Opened → Settled and emit OrderFinalised(orderId, Settled) (INV-P16)
├── when dstCST.safeTransfer reverts for one filler (e.g., blocked recipient) → it should revert the whole call (batch atomicity by default; user-facing guidance: pass single filler to make progress)
├── when a re-entrant call from dstCST transferCallback targets the same fillers[] slice → it should observe f.finalised == true and skip (nonReentrant still guards, AS-P6)
└── when duplicate filler address appears twice in fillers[] → second occurrence skips (idempotent flag)
```

### 6.6 `finaliseAsRefunded` (13 NEW)

Same `status == Opened` requirement as Exact §5.6 — RFC 003 line 612 rules out `None`, state diagram line 627 codifies `Opened → Refunded`. The extension does not override this for partial fills; per-filler refund is gated by the same order-level status rule.

```
PartialFillSettler_finaliseAsRefunded
├── when _hashOrder(order) != orderDigest → it should revert DigestMismatch
├── when block.timestamp <= order.fillDeadline → it should revert NotExpired (INV-P5)
├── when orderStatus[orderId] != Opened → it should revert InvalidOrderStatus
│   └── specifically: status == None → InvalidOrderStatus (RFC 003 line 612); fill-before-open filler who never sees openFor eats the liveness cost
│   └── specifically: status == Settled/Refunded/Cancelled → InvalidOrderStatus (terminal)
├── liveness note: it should succeed even if UW's ERC-1271 smart-wallet policy has changed post-signing (no signature re-verification, extension §8.2)
├── for each fillers[i]:
│   ├── when f.premiumSettled == true → it should skip (route via finaliseAsSettled)
│   ├── when f.dstCstProduced == 0 → it should skip (no rollover-leg for this filler)
│   ├── when f.refunded == true → it should skip (idempotent)
│   ├── when f.finalised == true → it should skip (exclusive paths, INV-P4a)
│   └── otherwise:
│       ├── it should set f.refunded = true BEFORE any external call (CEI)
│       ├── it should decrement totalDstCstEscrowed[orderDigest] by f.dstCstProduced
│       ├── it should dstCST.safeTransfer(cellar, f.dstCstProduced) (UW windfall)
│       └── it should emit FillerRefunded(orderDigest, filler, f.dstCstProduced)
├── when the last un-settled filler is refunded AND `refundedCount == participantCount` (pure-refund terminalization; no filler was settled pre-deadline) → it should transition orderStatus Opened → Refunded and emit OrderFinalised(orderId, Refunded)
├── when the last un-settled filler is refunded BUT some earlier fillers were settled pre-deadline (mixed state, `refundedCount < participantCount`) → it should leave orderStatus as Opened; callers reconcile the mixed state via a follow-up `finaliseAsSettled` call on the settled path
├── when entire fillers[] is premium-paid → it should transfer zero tokens (all skip)
└── when called by any caller AND status == Opened → it should succeed (permissionless, keeper-friendly)
```

### 6.7 `finaliseAsCancelled` (9 NEW)

Same schema-dependency note as Exact §5.7.

Cancel is callable only from `Opened` (RFC 003 line 293, 616). Calling from `None` reverts — maker who never opened has no escrow to reclaim.

```
PartialFillSettler_finaliseAsCancelled
├── when _hashOrder(order) != orderId → it should revert DigestMismatch
├── when orderStatus[orderId] != Opened → it should revert InvalidOrderStatus
│   └── specifically: status == None → InvalidOrderStatus (RFC 003 line 293, 612)
│   └── specifically: status == Settled/Refunded/Cancelled → InvalidOrderStatus (terminal)
├── when cellar.rolled[orderDigest] > 0 OR totalDstCstEscrowed[orderDigest] > 0 → it should revert OrderHasFills (INV-P15, partial-specific "any fill" check; RFC 003 line 293 "fills pre-empt cancellation")
├── when status == Opened AND no fills AND msg.sender == order.user → it should transition Opened → Cancelled and emit OrderFinalised
├── when status == Opened AND no fills AND msg.sender != order.user AND cancelSig is a valid maker cancel sig → it should succeed
├── when cancelSig is invalid → it should revert NotMaker
├── when cancelSig signs a different orderId → it should revert NotMaker
├── when any filler attempted a rollover fill under allowUnderfill with actualRolled == 0 (reverts ZeroRollover) → no fill state written, escrow empty, rolled[digest]==0; cancel from Opened is still valid and should succeed
└── when called after fillDeadline AND status == Opened AND no fills exist → it should still succeed
```

### 6.8 View getters (6 NEW total)

`fillerRollovers(orderDigest, filler)` — returns the zero-struct for unfilled `(orderDigest, filler)` pairs, the populated struct for filled ones, and the populated struct with the appropriate flag set post-finalise. `totalDstCstEscrowed(orderDigest)` — follows INV-P6 sum form; tested via before/after deltas in integration scenarios A, C, E (§9).

---

## 7. ERC6909Premium

Standalone prepaid-balance contract with `settle(...)`. Ownerless, immutable, no pause (per RFC 003 Glossary).

**7 external/public functions, 6 tree files, ~34 NET NEW leaves.** `supportsInterface` is a standard EIP-165 view not counted as a consequential surface — its 3 leaves live inline in the `deposit` tree (same `.t.sol` contract) to avoid a separate tree file for interface-ID assertions.

| Function | Tree File | Leaves |
|---|---|:---:|
| `deposit(address token, address to, uint256 amount)` | `erc6909/ERC6909Premium_deposit.tree` | 6 (of which 3 cover `supportsInterface`) |
| `withdraw(uint256 tokenId, address to, uint256 amount)` | `erc6909/ERC6909Premium_withdraw.tree` | 5 |
| `settle(address debitFrom, address premiumFiller, uint256 tokenId, uint256 amount, address recipient)` | `erc6909/ERC6909Premium_settle.tree` | 11 |
| `setOperator(address operator, bool approved)` | `erc6909/ERC6909Premium_setOperator.tree` | 4 |
| `balanceOf(address, uint256) view` | `erc6909/ERC6909Premium_balanceOf.tree` | 2 |
| `isOperator(address, address) view` | `erc6909/ERC6909Premium_isOperator.tree` | 3 |
| `supportsInterface(bytes4) view` | (3 leaves inline in `ERC6909Premium_deposit.t.sol`) | — |

### 7.3 `settle` (11 NEW) — the consequential one

```
ERC6909Premium_settle
├── when msg.sender not authorized by debitFrom → it should revert UnauthorizedSettler
├── when premiumFiller not authorized by debitFrom → it should revert UnauthorizedPremiumFiller (dual-auth, INV-E2)
├── when balanceOf(debitFrom, tokenId) < amount → it should revert InsufficientBalance
├── when amount == 0 → it should no-op successfully (INV-S10 short-circuit)
├── when all checks pass
│   ├── it should decrement debitFrom's balance by amount
│   ├── it should IERC20(token).safeTransfer(recipient, amount) where token = address(uint160(tokenId))
│   ├── it should emit Settled(debitFrom, premiumFiller, tokenId, amount, recipient)
│   └── it should complete atomically (no partial state on revert)
├── when token reverts in transfer → it should revert (state reverts, no partial debit)
├── when token returns false (non-standard ERC20) → it should revert via SafeERC20
└── when reentrant settle from token transferCallback → it should revert (nonReentrant)
```

---

## 8. Supporting Libraries

Small, stateless, implementation-support libraries — validated inline in the consuming settler's `.t.sol` files, plus one standalone test file per library for differential coverage.

| Library | Test File | Leaves |
|---|---|:---:|
| `LibRolloverOrder` (encode/decode `OrderData`, `PartialFillerData`, `ExactFillerData`) | `libs/LibRolloverOrder.t.sol` | 10 |
| `LibSettlerHashing` (`_hashOrder`, `_hashOutput`, `orderId`, `orderDigest`) | `libs/LibSettlerHashing.t.sol` | 12 |

Total: 22 NEW. These libraries are verified directly against the RFC 003 §A.6–A.10 hash specs — any drift from the canonical encoding breaks cross-contract replay guards at cellar sig level.

---

## 9. Integration Tests

**File:** `test/integration/RolloverLifecycle.t.sol` — 15 end-to-end tests exercising the settler ↔ factory ↔ cellar path with real contracts (no mocks beyond DummyERC20).

The five extension §13.6 worked scenarios each produce at least one test here. Scenario A and Scenario D each require two tests: a **baseline** matching the narrative exactly (including the expected revert sub-flow) and an **alternate** covering the all-succeed / one-succeed path the extension describes in parallel. This preserves scenario parity.

| # | Test | Flow |
|---|---|---|
| INT-1 | `test_e2e_exactFill_fullLifecycle` | Exact: `openFor → fill(rollover) → fill(premium) → finaliseAsSettled` with one filler. Validates `hookNonces` phase-0 bit set, `premiumFiredFor[d][filler]` set, status transitions Opened → Settled at finaliseAsSettled (not at fill), dstCST delivered to filler's destination. |
| INT-2 | `test_e2e_exactFill_refundAfterPremiumDodge` | Exact: `openFor → fill(rollover)`, filler abandons premium, fast-forward past deadline, `finaliseAsRefunded(order)` routes dstCST to cellar as UW windfall. Status transitions Opened → Refunded. |
| INT-3 | `test_e2e_exactFill_cancelBeforeFill` | Exact: `openFor → finaliseAsCancelled` immediately, no fills. UW signs cancel sig → gasless path works too. |
| INT-3b | `test_e2e_exactFill_fillBeforeOpen` | Exact: `fill(rollover) → fill(premium) → openFor → finaliseAsSettled` — status stays None through fills, transitions None → Opened at openFor, then Opened → Settled at finaliseAsSettled. Exercises fill-before-open correctness (RFC 003 line 664). |
| INT-4a | `test_e2e_partialFill_scenarioA_terminalAtFillTwo` | Partial, baseline scenario A (extension §13.6.1): Filler₁ rolls 0.4S, Filler₂ rolls 0.6S (terminal, phase-0 bit flipped, `rolled` deleted), Filler₃ attempts 0.5S → reverts `PhaseAlreadyConsumed` at cellar step 6. Validates post-terminal revert. |
| INT-4b | `test_e2e_partialFill_threeSequentialFills_alternate` | Partial, alternate: three fillers roll 0.4S + 0.4S + 0.2S sequentially (sum == S). All three succeed; third is the terminal fill. Each settles premium independently; `finaliseAsSettled([f1,f2,f3])` releases dstCST to all three. |
| INT-5 | `test_e2e_partialFill_scenarioB_underfillMid` | Partial, scenario B (extension §13.6.2): `allowUnderfill=true`; UW's srcCPT availability shrinks mid-lifecycle; filler₂ receives `actualRolled < output.amount`. Validates INV-P7 cumulative alignment under underfill. |
| INT-6 | `test_e2e_partialFill_scenarioC_expirationMidFill` | Partial, scenario C (extension §13.6.3): two fillers rolled 0.3S + 0.4S without paying premium, `cellar.rolled[d]` sits at 0.7S non-terminal, advance past deadline, `finaliseAsRefunded(order, [f1, f2])` routes both to cellar. Edge-state assertion: after refund, `cellar.rolled[d]` still 0.7S (dead storage per extension §11 non-goal on cleanup), `hookNonces` phase-0 bit still unset, `totalDstCstEscrowed[d] == 0`, `orderStatus == Refunded`. |
| INT-7a | `test_e2e_partialFill_scenarioD_bothRevertAtCeiling` | Partial, baseline scenario D (extension §13.6.4): `rolled==0.5S`, Tx_A and Tx_B both request 0.6S; whichever lands first reverts `OverfillCeiling`, the second also reverts. Post-state: `rolled == 0.5S` unchanged. |
| INT-7b | `test_e2e_partialFill_scenarioD_oneWinsAfterSmallerRequest_alternate` | Partial, alternate: Tx_A requests 0.4S and lands first (`rolled → 0.9S`); Tx_B's 0.6S then reverts `OverfillCeiling` against `0.9 + 0.6 = 1.5S > S`. Loser's state unchanged. |
| INT-8 | `test_e2e_partialFill_scenarioE_underfillDisallowed` | Partial, scenario E (extension §13.6.5): `allowUnderfill=false`, `_sourceable() == 0.3S < fillAmount 0.5S` → fill reverts `UnderfillNotAllowed` at cellar step 8. No state mutated. |
| INT-9 | `test_e2e_partialFill_mixedSettleAndRefund` | Partial: 2 fillers, one settles premium, one doesn't. `finaliseAsSettled([f1,f2])` skips the non-payer; `finaliseAsRefunded(order, [f2])` routes the non-payer's escrow to cellar. |
| INT-10 | `test_e2e_griefingDefense_directFactoryCall` | Attacker calls `factory.executeIntentHooks(.. phase=1)` directly; cellar rejects `SettlerMismatch` because `originatingSettler()` is the EOA, not a settler. Closes §10.11 griefing vector. |
| INT-11 | `test_e2e_crossSettlerSigReplayBlocked` | Sign a `GaslessCrossChainOrder` against ExactFillSettler's domain, replay against PartialFillSettler → recovers to wrong signer → `InvalidSignature`. |
| INT-12 | `test_e2e_factoryBlocklist_stopsSettler` | Admin blocks PartialFillSettler on factory; subsequent fills revert at the factory. |
| INT-13 | `test_e2e_premiumHooksRevert_rollsBackERC6909Debit` | Exact AND Partial: phase-1 `premiumHooks` revert inside the cellar *after* `ERC6909.settle()` has already debited `debitFrom`. Assert: the whole `fill()` reverts atomically, `IERC6909.balanceOf(debitFrom, tokenId)` is unchanged from pre-fill, `orderStatus` unchanged, settler-side `f.premiumSettled`/`paymentSettled` unchanged. Covers INV-S12, EINV-3, and the reviewer's MAJOR 3 gap. |

---

## 10. Invariant Tests

### 10.1 Shared Settler Handler Actions

**Cellar-side actions** (reused from cellar-private tests): `deployCellar`, `blockSettler`, factory emergency controls.

**Settler-side actions** (17): `open_exact`, `openFor_exact`, `fill_rolloverLeg_exact`, `fill_premiumLeg_exact`, `finaliseAsSettled_exact`, `finaliseAsRefunded_exact`, `finaliseAsCancelled_exact`, `open_partial`, `openFor_partial`, `fill_rolloverLeg_partial`, `fill_premiumLeg_partial`, `finaliseAsSettled_partial`, `finaliseAsRefunded_partial`, `finaliseAsCancelled_partial`, `advanceTime`, `depositPremium`, `setOperator_erc6909`.

**Ghost variables:** `ghost_rolledPerOrder` (map), `ghost_fillersOf` (map), `ghost_premiumPaid` (map), `ghost_terminalOrders` (set), `ghost_erc6909Balances` (map), `ghost_orderStatus` (map).

### 10.2 ExactFillSettler Invariants (INV-S series)

| # | Invariant Function | Property |
|---|---|---|
| SINV-1 | `invariant_S1_escrowAccounting` | `fillRecords[orderId][rolloverOutputHash].dstCstProduced` equals observed dstCST balance delta at that orderId |
| SINV-2 | `invariant_S2_perTokenSolvency` | Σ `fillRecords[oid].dstCstProduced` for unsettled orders ≤ `dstCST.balanceOf(settler)` |
| SINV-3 | `invariant_S3_fillOncePerOutput` | For every `(orderId, outputHash)`, fillRecords.filledAt is 0 or immutable once set |
| SINV-3b | `invariant_S3_rolloverFirstOrdering` | A premium fill exists only if a rollover fill record exists for the same orderId |
| SINV-4 | `invariant_S4_fillBeforeDeadline` | No fill record has `filledAt > order.fillDeadline` |
| SINV-5 | `invariant_S5_refundAfterDeadline` | No `status=Refunded` order has `block.timestamp ≤ fillDeadline` at transition time |
| SINV-6 | `invariant_S6_cancelPreFill` | No `status=Cancelled` order has a fill record |
| SINV-7 | `invariant_S7_statusMonotone` | Status transitions are forward-only |
| SINV-11 | `invariant_S11_fillRecordIntegrity` | Every `finaliseAsSettled` predecessor has both fill records present |
| SINV-15 | `invariant_S15_tokenDistinctness` | `srcCstToken ≠ premiumToken` for every opened order |

### 10.3 PartialFillSettler Invariants (INV-P series)

**Note on INV-P2:** The extension removed `minFillRatio` (§5.2 line 127) and retains INV-P2 as a numbering gap (§9.2 line 500). No test function is generated for PINV-2.

| # | Invariant Function | Property |
|---|---|---|
| PINV-1 | `invariant_P1_oneRolloverLegPerFiller` | `f.srcCstProvided` is 0 or, once written to a non-zero value, never changes |
| PINV-2 | — | removed (gap; see note above) |
| PINV-3 | `invariant_P3_rolloverFirstPerFiller` | `f.premiumSettled ⇒ f.srcCstProvided > 0` |
| PINV-4 | `invariant_P4_singleFinalisation` | `¬(f.finalised ∧ f.refunded)` and both flags are latching |
| PINV-5 | `invariant_P5_refundPrecondition` | Any transition of f.refunded from false→true had `block.timestamp > fillDeadline` and `premiumSettled == false` at entry |
| PINV-6 | `invariant_P6_orderCompletenessSum` | `totalDstCstEscrowed[d] == Σ f.dstCstProduced × [¬finalised ∧ ¬refunded]` |
| PINV-7 | `invariant_P7_cumulativeAlignment` | Pre-terminal: `Σ f.srcCstProvided == cellar.rolled[d]`. Post-terminal: `Σ == orderSize ∧ cellar.rolled[d] == 0` |
| PINV-8 | `invariant_P8_perFillerAtomicity` | `f.premiumSettled ⇒ (f.dstCstProduced > 0 ∧ f.srcCstProvided > 0 ∧ f.destination ≠ 0)` |
| PINV-10 | `invariant_P10_finalisationCEI` | Flags flip before `safeTransfer`, verified via mock-callback reentrancy probe |
| PINV-11 | `invariant_P11_premiumMonotonicityUnderRounding` | `totalPremiumCollected ≥ ceilDiv(Σ dstCstProduced × minPremiumPerShare, 1e18)` |
| PINV-12 | `invariant_P12_terminalAwareConservation` | phase-0 bit ⇔ `rolled == 0 ∧ Σ srcCstProvided == orderSize` |
| PINV-13 | `invariant_P13_noPostTerminalFillers` | No filler state written after the phase-0 terminal bit is set |
| PINV-14 | `invariant_P14_perTokenSolvency` | Σ `totalDstCstEscrowed[d]` ≤ `dstCST.balanceOf(partialSettler)` |
| PINV-15 | `invariant_P15_cancelBeforeAnyFill` | Cancel rejects once `rolled[digest] > 0` |
| PINV-16 | `invariant_P16_orderTerminalState` | Order reaches Settled iff phase-0 bit set AND escrow zero AND all finalised |
| PINV-17 | `invariant_P17_premiumHookSingularity` | Cellar `premiumFiredFor[d][a]` set at most once for each `(d, a)` pair |
| PINV-18 | `invariant_P18_intentHashBinding` | Every fill record was produced with `keccak256(intent) == od.cellarIntentHash` |

### 10.4 ERC-6909 Invariants

| # | Invariant Function | Property |
|---|---|---|
| EINV-1 | `invariant_E1_balanceConservation` | Σ balances for tokenId = Σ deposits − Σ withdraws − Σ settles |
| EINV-2 | `invariant_E2_dualAuthSettle` | Every successful settle had BOTH msg.sender authorized AND premiumFiller authorized by debitFrom |
| EINV-3 | `invariant_E3_noPhantomDebit` | A revert inside settle (token transfer) leaves balances unchanged |

---

## 11. Summary

| Category | Source | Total Leaves | Net New |
|---|---|:---:|:---:|
| BaseSettler (4 trees) | abstract, tested via concretes + `MockBaseSettler` harness | 26 | **26** |
| ExactFillSettler (8 functions) | 8 `.tree` files | 71 | **71** |
| PartialFillSettler (10 functions) | 10 `.tree` files | 94 | **94** |
| ERC6909Premium (6 trees + inline `supportsInterface`) | 6 `.tree` files | 31 | **31** |
| Supporting Libraries (2) | 2 test files | 22 | **22** |
| Integration | 1 file, 15 scenarios | 15 | **15** |
| Invariant — Settler (S + P, P2 removed as gap) | handler + 2 test files | 26 | **26** |
| Invariant — ERC-6909 | handler + test file | 3 | **3** |
| **Total** | | **288** | **288** |

---

## 12. Invariant Coverage Matrix

Cellar-layer invariants (INV-C series) are maintained by `CorkCellar` and are primary-tested in cellar-private's invariant suite. Entries below that list a cellar invariant are **cross-referenced** — the row shows which settler-side test or integration test exercises the invariant through the settler's fill path, but the authoritative tightness check is cellar-private's responsibility.

| Invariant | Description | BTT Leaf Tests | Invariant Fuzzing |
|---|---|---|---|
| INV-S1 | ExactFill per-order escrow accounting | `fill` rollover leg leaves (balance-delta observation) | SINV-1 |
| INV-S2 | ExactFill per-token solvency | `finaliseAsSettled/Refunded` leaves | SINV-2 |
| INV-S3 | Fill-once per output | `fill` `AlreadyFilled` leaves | SINV-3 |
| INV-S3 (rollover-first) | Premium gated on rollover fillRecord | `fill` `PremiumBeforeRollover` leaf | SINV-3b |
| INV-S4 | Fill before fillDeadline | `fill` `FillAfterDeadline` leaves | SINV-4 |
| INV-S5 | Refund after fillDeadline | `finaliseAsRefunded` leaves | SINV-5 |
| INV-S6 | Cancel when no fills | `finaliseAsCancelled` `OrderHasFills` leaf | SINV-6 |
| INV-S7 | Status monotonicity | status-gate leaves across all trees | SINV-7 |
| INV-S8 | orderId integrity | library tests (`LibSettlerHashing`) | — |
| INV-S9 | Callback post-condition (solvency, 1-wei tolerance) | `fill` rollover `DisproportionateOutput` leaf | SINV-1 |
| INV-S10 | Premium sufficiency (zero-premium short-circuit) | `fill` premium leaves + BaseSettler `_settlePremium` + ERC-6909 `settle` | EINV-2 |
| INV-S11 | Fill record integrity | `finaliseAsSettled` `InvalidFillRecord`/`PaymentNotSettled` leaves | SINV-11 |
| INV-S12 | Settlement atomicity (incl. premium-hook revert rollback) | `fill` premium-hook-revert leaf + INT-13 | — |
| INV-S15 | Token distinctness | `open` / `openFor` / `fill` srcCst==premium leaves (Exact §5.1, §5.2, §5.4; Partial §6.1, §6.2, §6.4) | SINV-15 |
| INV-P1 | One rollover-leg per filler | Partial `fill` `AlreadyFilledByFiller` leaf | PINV-1 |
| ~~INV-P2~~ | Removed per extension §5.2 line 127 and §9.2 line 500 | — | — |
| INV-P3 | Per-filler rollover-first | Partial `fill` `NoRolloverLegForFiller` leaf | PINV-3 |
| INV-P4 | Single finalisation per filler | `finaliseAsSettled/Refunded` skip-branch leaves | PINV-4 |
| INV-P5 | Refund precondition | Partial `finaliseAsRefunded` leaves | PINV-5 |
| INV-P6 | Completeness sum form | view tests + integration snapshots | PINV-6 |
| INV-P7 | Cumulative alignment with cellar | INT-4a, INT-4b, INT-5 (underfill), INT-7a | PINV-7 |
| INV-P8 | Per-filler atomicity | Partial `fill` premium leaves | PINV-8 |
| INV-P9 | Concurrency linearisation | INT-7a, INT-7b ceiling races | — |
| INV-P10 | Finalisation CEI | `finaliseAsSettled/Refunded` reentrancy-callback leaves | PINV-10 |
| INV-P11 | Premium monotonicity under rounding | ceil-rounding fuzz in `fill` premium | PINV-11 |
| INV-P12 | Terminal-aware conservation | INT-4a post-terminal snapshot | PINV-12 |
| INV-P13 | No post-terminal fillers | Partial `fill` `PhaseAlreadyConsumed` post-terminal leaf | PINV-13 |
| INV-P14 | Per-token solvency | integration snapshots | PINV-14 |
| INV-P15 | Cancel-before-any-fill | Partial `finaliseAsCancelled` `OrderHasFills` leaf | PINV-15 |
| INV-P16 | Order terminal state | INT-4a, INT-4b, finaliseAsSettled terminal-transition leaf | PINV-16 |
| INV-P17 | Premium-hook singularity | cellar phase-1 replay leaf bubbled through Partial `fill` | PINV-17 |
| INV-P18 | Intent-hash binding | Partial `fill` `IntentNotBoundToOrder` leaf | PINV-18 |
| INV-C13 | Cellar cumulative ceiling | INT-4a, INT-7a (bubbled from cellar) | (cellar-side primary, covered in cellar suite) |
| INV-C14 | Phase-0 terminal marker permanence | INT-4a (post-terminal revert observes permanence); cross-ref cellar suite | (cellar-side primary) |
| INV-C15 | Phase-0 terminal cleanup (rolled[] deletion) | INT-4a post-terminal snapshot (`rolled[d]==0 ∧ hookNonces[d]&1!=0`); cross-ref cellar suite | (cellar-side primary) |
| INV-C16 | Pre-terminal counter monotonicity | INT-4a, INT-4b cumulative snapshots; cross-ref cellar suite | (cellar-side primary) |
| INV-C17 | Zero-roll guard | Partial `fill` `ZeroRollover` leaf | (cellar-side primary) |
| INV-C18 | Settler identity binding | INT-10 griefing defense | (cellar-side primary) |
| INV-C19 | Transient slot hygiene | INT-10 post-call snapshot asserts `factory.originatingSettler() == address(0)`; cross-ref cellar suite | (cellar-side primary) |
| AS-P6 | Reentrancy on finalise | `finaliseAsSettled/Refunded` nonReentrant leaves | — |
| AS-P cross-settler replay | Cross-domain sig rejection | BaseSettler `_recover` leaves, INT-11 | — |
| EINV-3 | ERC-6909 no phantom debit on downstream revert | ERC-6909 `settle` reentrancy/revert leaves + INT-13 | EINV-3 |

---

## 13. File Layout

```
contracts/
├── settlers/
│   ├── BaseSettler.sol                           (abstract)
│   ├── ExactFillSettler.sol
│   └── PartialFillSettler.sol
├── erc6909/
│   └── ERC6909Premium.sol
├── libs/
│   ├── LibRolloverOrder.sol
│   └── LibSettlerHashing.sol
└── interfaces/
    ├── IOriginSettler.sol                        (ERC-7683 verbatim)
    ├── IDestinationSettler.sol                   (ERC-7683 verbatim)
    ├── IERC6909Premium.sol
    ├── IPartialFillSettler.sol
    └── IExactFillSettler.sol

test/
├── BaseTestSettler.sol                           (inherits cellar's BaseTestCorkCellar)
├── base/
│   ├── MockBaseSettler.sol                       (test-only harness)
│   ├── BaseSettler_domainSeparator.tree / .t.sol
│   └── BaseSettler_recover.tree / .t.sol
├── exact/
│   ├── ExactFillSettler_open.tree / .t.sol
│   ├── ExactFillSettler_openFor.tree / .t.sol
│   ├── ExactFillSettler_resolve.tree / .t.sol
│   ├── ExactFillSettler_resolveFor.tree / .t.sol
│   ├── ExactFillSettler_fill.tree / .t.sol
│   ├── ExactFillSettler_finaliseAsSettled.tree / .t.sol
│   ├── ExactFillSettler_finaliseAsRefunded.tree / .t.sol
│   └── ExactFillSettler_finaliseAsCancelled.tree / .t.sol
├── partial/
│   ├── PartialFillSettler_open.tree / .t.sol
│   ├── PartialFillSettler_openFor.tree / .t.sol
│   ├── PartialFillSettler_resolve.tree / .t.sol
│   ├── PartialFillSettler_resolveFor.tree / .t.sol
│   ├── PartialFillSettler_fill.tree / .t.sol
│   ├── PartialFillSettler_finaliseAsSettled.tree / .t.sol
│   ├── PartialFillSettler_finaliseAsRefunded.tree / .t.sol
│   ├── PartialFillSettler_finaliseAsCancelled.tree / .t.sol
│   ├── PartialFillSettler_fillerRollovers.tree / .t.sol
│   └── PartialFillSettler_totalDstCstEscrowed.tree / .t.sol
├── erc6909/
│   ├── ERC6909Premium_deposit.tree / .t.sol
│   ├── ERC6909Premium_withdraw.tree / .t.sol
│   ├── ERC6909Premium_settle.tree / .t.sol
│   ├── ERC6909Premium_setOperator.tree / .t.sol
│   ├── ERC6909Premium_balanceOf.tree / .t.sol
│   └── ERC6909Premium_isOperator.tree / .t.sol
├── libs/
│   ├── LibRolloverOrder.t.sol
│   └── LibSettlerHashing.t.sol
├── integration/
│   └── RolloverLifecycle.t.sol                   (12 scenarios)
└── invariant/
    ├── SettlerInvariantHandler.sol
    ├── ExactFillInvariantTest.t.sol              (SINV series)
    ├── PartialFillInvariantTest.t.sol            (PINV series)
    ├── ERC6909PremiumInvariantHandler.sol
    └── ERC6909PremiumInvariantTest.t.sol         (EINV series)

script/foundry-scripts/
└── DeploySettlers.s.sol                          (deploys ERC6909Premium + both settlers against an existing factory)
```

---

## 14. PR Chunking (TDD per chunk)

**Each sub-PR ships tests + implementation together.** TDD within each chunk: write failing tests first, then implementation to pass them. Uses the real `CorkCellar` + `CorkCellarFactory` from `lib/cellar`, Phoenix's existing mocks via cellar's `BaseTestCorkCellar`, and a real `ERC6909Premium` (no ERC-6909 mock).

PR 4 is split into 5 sub-PRs ordered by dependency. See `plan/implementation-plan.md` for the full sub-PR structure, branch names, dependency graph, and merge workflow.

| PR | What | Gate |
|---|---|---|
| **PR 1** `chore/bump-solc-and-add-cellar-submodule` | Bump Solc → 0.8.30, EVM → prague. Add `lib/cellar` submodule. Update remappings. `forge build` on empty src. | `forge build` |
| **PR 2** `feat/settler-interfaces-and-libs` | ERC-7683 interfaces (`IOriginSettler`, `IDestinationSettler`), `IERC6909Premium`, `LibRolloverOrder`, `LibSettlerHashing` **with their tests** (22 lib leaves co-shipped). Stub `BaseSettler` (abstract, revert-on-external). **Zero settler logic.** | `forge build` + `forge test --match-path "test/libs/*"` (22 pass) |
| **PR 3** `feat/erc6909-premium` | ERC6909Premium — tests + implementation. Standalone, no settler dependency. | `forge test --match-path "test/erc6909/*"` |
| **PR 4** `feat/settlers` | **Tests + implementation for both settlers.** Integration branch with 5 sub-PRs: | `forge test` — all pass |
| | **4a** `feat/settler-test-infra` — `BaseTestSettler` harness only (library tests already shipped in PR 2) | |
| | **4b** `feat/settler-base` — 26 BaseSettler leaves + BaseSettler impl (depends: 4a) | |
| | **4c** `feat/settler-exact` — 71 ExactFillSettler BTT tests + impl (depends: 4a, 4b) | |
| | **4d** `feat/settler-partial` — 94 PartialFillSettler BTT tests + impl (depends: 4a, 4b; parallel with 4c) | |
| | **4e** `feat/settler-integration` — 15 integration + 29 invariant tests + deploy script (depends: 4c, 4d; last) | |

Merge order: 1 → 2 → 3 → 4a → 4b → (4c ∥ 4d) → 4e

Stacked PR — each PR's description includes a diff link to its parent branch. See `plan/implementation-plan.md` for stacked PR workflow details.
