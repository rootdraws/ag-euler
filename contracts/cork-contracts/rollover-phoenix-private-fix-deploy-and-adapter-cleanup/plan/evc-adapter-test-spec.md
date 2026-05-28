# EVC Rollover Adapter — Test Specification

> Covers `EvcRolloverAdapter` — the RFC 003 §7.3 reference EVC-aware filler for Euler vault curators. Parameterised per settler type (DP-A parity with `RolloverFiller`): one contract, two deployments — one bound to `ExactFillSettler`, one bound to `PartialFillSettler`. Vault interactions are out of scope (RFC §7.3: "the adapter doesn't pull tokens from the caller or return leftovers" — vault IO lives in sibling `evc.batch()` items composed by the curator).
>
> Tests structured using **Branching Tree Technique (BTT)**: one `.tree` file per (function × settler binding) defines the control-flow tree; each leaf (`it should ...`) becomes a test case. Trees are the source of truth.
>
> **Test + implementation split:** Tree + tests ship on a `test/...` branch that gates on `forge test` **failing red** against the stub. Implementation ships on a stacked `impl/...` branch that turns the tests green. See `plan/evc-adapter-implementation-plan.md` for the full PR stack.
>
> **Test organization:** Co-located — each `.tree` lives next to its `.t.sol` in the same domain folder. Exact and Partial paths get separate tree files under `test/filler/evc/exact/` and `test/filler/evc/partial/`.
>
> **Mocking policy:** Use the **real** `EthereumVaultConnector` (installed as a submodule), the **real** `CorkCellar` + `CorkCellarFactory` + rhinestone `Registry` + Phoenix pool manager via `BaseTestCorkCellar` (reached through `BaseTestSettler` → `BaseTestFiller` → `BaseTestEvcFillerAdapter`), the **real** `ExactFillSettler`, `PartialFillSettler`, and `ERC6909Premium` from the landed settler stack. No new mocks. The existing `test/mocks/MockERC1271Signer.sol` is available if needed but the ERC-1271 path is already covered by the `RolloverFiller` integration suite and is not duplicated here.

---

## Table of Contents

1. [Test Methodology](#1-test-methodology)
2. [Test Infrastructure](#2-test-infrastructure)
3. [Contract Surface Summary](#3-contract-surface-summary)
4. [BTT Tree Outlines](#4-btt-tree-outlines)
5. [Integrator Requirements Matrix](#5-integrator-requirements-matrix)
6. [Invariant Tests](#6-invariant-tests)
7. [Integration Tests](#7-integration-tests)
8. [File Layout](#8-file-layout)
9. [PR Chunking](#9-pr-chunking)

---

## 1. Test Methodology

### Branching Tree Technique (BTT)

Every external/public function gets a `.tree` file that mirrors its code's validation order top-to-bottom. Each `when` node is a decision point; each `it should` leaf is a test case. The `.tree` file lives in the **same directory** as its `.t.sol` test file.

**Tree → Solidity mapping:**
- Root node → test contract name (e.g., `EvcRolloverAdapter_execute_Exact`)
- `when` nodes → `modifier when<Condition>() { _; }` in the test contract
- `it should` leaves → `function test_<What>() external when<A> when<B> { ... }`
- `test_RevertWhen_<Condition>` for revert branches
- `test_<functionName>_<whatItDoes>` for success branches

**Scaffolding:** [`bulloak`](https://github.com/alexfertel/bulloak) scaffolds Solidity test stubs from `.tree` files. `bulloak check` keeps trees and tests in sync. Matches the cellar-private + landed settler + landed `RolloverFiller` convention.

**Two test contracts per function** (Exact binding + Partial binding). Each inherits `BaseTestEvcFillerAdapter` and targets exactly one `(execute, settler type)` pair. The function under test is the same; the tree and leaves diverge where the settler-type discriminant changes behaviour.

### Test-first / impl-second discipline

Every test-only PR MUST fail red against the current implementation on its parent branch. If a test-only PR passes against the stub, that means the test is asserting the wrong thing — stop and fix the test before merge.

Every impl-only PR MUST turn the preceding test PR's failing suite green **without regressing** the landed `RolloverFiller` suite or any earlier EVC test PR's passing suite. Regressions are stop-ship.

### Fuzz & Invariant Fuzzing

- Handler contracts expose bounded `execute` actions wrapped inside `evc.batch([...])` calls with a sibling pre-funding item that seeds the adapter with srcCST. Ghost state tracks adapter srcCST excess (pre-balance over-funding) separately from post-call retained srcCST (underfill leftover), because the adapter does not sweep either.
- Per-function fuzz tests cover value ranges on `srcCstAmount` (zero, `orderSize`, over-funded balance, under-funded balance) and on `debitFrom` (caller-subaccount vs third-party authoriser).

### Real-contract policy

EVC adapters are caller-side orchestration — their correctness is meaningful **only** when wired to the real EVC + real settler + real ERC-6909 + real cellar + real Phoenix. Every leaf under `test/filler/evc/` runs against the real stack.

---

## 2. Test Infrastructure

### 2.1 Version alignment

Solc 0.8.30, EVM `prague`, `via_ir = true`, `optimizer_runs = 1_000_000` — unchanged from the landed settler + filler stacks.

### 2.2 Submodule & remapping additions

- **Submodule:** `lib/ethereum-vault-connector` — `forge install euler-xyz/ethereum-vault-connector` at plan-execution time. Pin the commit in `.gitmodules`. Licence check (GPL-2.0 on EVC master); add an `ACKNOWLEDGEMENTS` entry if the repo convention requires it.
- **Remapping:** add `evc/=lib/ethereum-vault-connector/src/` to `remappings.txt`. Verify `import "evc/EthereumVaultConnector.sol"` compiles.
- **No other remap changes.** All other infrastructure reachable through the existing remap set (cellar, phoenix, openzeppelin, forge-std).

### 2.3 Test Harness (`BaseTestEvcFillerAdapter`)

Inherits **`BaseTestFiller`** (landed). Adds:

- `EthereumVaultConnector evc` — deployed fresh in `setUp()`.
- `EvcRolloverAdapter evcAdapterExact` — deployed with `(address(exactSettler), false, address(0), address(evc))`.
- `EvcRolloverAdapter evcAdapterPartial` — deployed with `(address(partialSettler), true, expectedFactory, address(evc))`.
- Convenience helpers:
  - `_authoriseAdapterOperator(subaccount, adapter)` — `evc.setAccountOperator(subaccount, address(adapter), true)` as `subaccount`.
  - `_prepareAdapterErc6909(subaccount, adapter, premiumToken, premiumAmount)` — deposit premium via ERC-6909 keyed on `subaccount`, then `setOperator(..., true)` on `subaccount`'s behalf for **both** the adapter's bound settler AND the adapter itself. Dual authorisation is required: `BaseSettler._requireDebitFromAuthorized` compares `debitFrom` against the settler's `msg.sender` (the adapter), while `ERC6909Premium.settle` cross-checks operator status for both the settler (its own `msg.sender`) and the forwarded `premiumFiller` (the adapter). The `adapter` parameter is required so the helper can resolve the correct bound settler for the ERC-6909 operator grant (there are two adapters in the harness — Exact and Partial — bound to different settlers).
  - `_executeViaEvcBatch(adapter, subaccount, prefixItems, suffixItems, order, signature, originFillerData, srcCstAmount, debitFrom, destination)` — wraps an `evc.batch([...prefixItems, adapterExecuteItem, ...suffixItems])` call with the correct `onBehalfOfAccount`. `prefixItems` typically holds seed/funding steps (ERC-20 transfer to adapter; future EVault withdrawal). `suffixItems` typically holds sweep/deposit steps (leftover srcCST collection; future EVault deposit). Either list may be empty. Variadic shape supports the 7 integration scenarios which compose 1- to 3-step batches.
  - `_executeViaEvcCall(adapter, subaccount, orderData, signature, originFillerData, srcCstAmount, debitFrom, destination)` — convenience wrapper around `evc.call(address(adapter), subaccount, 0, abi.encodeWithSelector(execute, ...))` pranked as `subaccount`. Demonstrates that the adapter does not distinguish `call` from `batch` — both yield non-zero `getCurrentOnBehalfOfAccount`. Used in PR 3a integration scenario #6 (`EvcRolloverAdapter_CallPath.t.sol`) as a smoke test for the `evc.call` path; the adapter itself makes no `batch`-only assumption.
  - `_seedAdapterSrcCst(adapter, srcCstToken, amount)` — helper to pre-fund the adapter outside `evc.batch()` (for lower-level unit tests that target a single revert path without building a full batch).
  - `_adapterSnapshot(adapter, srcCstToken, dstCstToken, expectedSrcCstLeftover)` — post-execute asserter for a single srcCST/dstCST token pair. Covers INV-F1 (srcCST balance equals `expectedSrcCstLeftover`, dstCST balance is zero) and INV-F2 (zero srcCST and dstCST allowance to the bound settler). The per-pair signature is clearer than a `tokens[]` array for the adapter's 1-src-1-dst model. INV-F4 (zero ERC-6909 balance), INV-F5 (no operator status), and INV-F8 (no events emitted by the adapter) are covered by the invariant handler landed in PR 3a — they are **not** asserted by this helper.
  - `_computeOrderDigest(order)` — inherited from `BaseTestFiller`.

### 2.4 Signing helpers

Inherited from `BaseTestSettler` / `BaseTestFiller`. No additions.

### 2.5 Foundry profile

Inherited from the landed settler + filler stacks. No changes.

---

## 3. Contract Surface Summary

| Contract | External/Public Functions | Tree Files | Role |
|---|:---:|:---:|---|
| `EvcRolloverAdapter` | 1 (`execute`) | 2 (Exact binding + Partial binding) | EVC-aware filler for Euler vault curators (RFC 003 §7.3). One contract, two deployments. |

**Expected test contract names:**
- `EvcRolloverAdapter_execute_Exact` — tree: `test/filler/evc/exact/EvcRolloverAdapter_execute.tree`; tests: `EvcRolloverAdapter_execute.t.sol`.
- `EvcRolloverAdapter_execute_Partial` — tree: `test/filler/evc/partial/EvcRolloverAdapter_execute.tree`; tests: `EvcRolloverAdapter_execute.t.sol`.

Invariant handler + test live under `test/filler/evc/invariant/`. Integration scenarios under `test/filler/evc/integration/`.

---

## 4. BTT Tree Outlines

Trees are authored in full alongside this spec and live at `plan/btt-draft/`. The `execute-cork` run for PR 2a copies them into `test/filler/evc/exact/` and `test/filler/evc/partial/`, then scaffolds `.t.sol` via `bulloak`. Any leaf edits during authoring MUST update the draft tree in `plan/btt-draft/` in the same PR so this spec stays the source of truth.

### 4.1 `EvcRolloverAdapter_execute_Exact` — 48 leaves

Draft tree: `plan/btt-draft/EvcRolloverAdapter_execute_Exact.tree`.

Branch summary (validation order top-to-bottom mirrors RFC §7.3: zero-destination guard fires **before** EVC caller resolution):

- 1 destination zero-address guard (first — matches RFC §7.3 line 2365)
- 2 EVC caller-resolution guards (outside-batch call; zero-caller contrived path)
- 4 pre-balance-check paths (zero balance; short balance; exact balance → proceeds; over-funded → proceeds and retains excess)
- 1 srcCstAmount zero — the leaf does NOT lock a selector at tree-authoring time; scaffold-time it reframes to whatever revert surface the real stack exposes, mirroring the landed `RolloverFiller_execute_Exact` test body at `test/filler/exact/RolloverFiller_execute.t.sol:101` which reframed the same branch because `TestMintModule` fixture fidelity diverges from production `RolloverModule`
- 4 `SETTLER.openFor` revert paths (`InvalidSignature`, `NotMaker`, `InconsistentIntent`, `InvalidOrderTokenPair`)
- 1 openFor idempotent no-op
- 6 rollover-leg `fill` revert paths (`FillAfterDeadline`, `AlreadyFilled`, `PartialFillNotAllowed`, `IntentNotBoundToOrder`, `DisproportionateOutput`, `OrderInTerminalState`)
- 4 rollover-leg happy-path assertions (allowance, FillRecord, dstCST escrow, allowance reset pre-premium)
- 5 premium-leg `fill` revert paths (`PremiumBeforeRollover`, `AlreadyFilled`, `InsufficientBalance`, `UnauthorizedSettler`, `UnauthorizedDebitFrom`) — `UnauthorizedPremiumFiller` is unreachable through `execute` because `BaseSettler._requireDebitFromAuthorized` (at `contracts/settlers/BaseSettler.sol:169`) rejects the same pre-state earlier with `UnauthorizedDebitFrom`; this mirrors the landed filler coverage at `test/filler/exact/RolloverFiller_execute.t.sol:682` and RFC-level behaviour
- 4 premium-leg happy-path assertions (debit, premium to cellar, `paymentSettled == true`, zero residual srcCST allowance)
- 1 premium-hook revert atomicity
- 2 `finaliseAsSettled` revert paths (`InvalidOrderStatus`, `PaymentNotSettled`) — `InvalidFillRecord` omitted, matches landed Exact filler tree after P24-G2
- 6 full-happy-path assertions (exact funding): INV-F1 × 2 (srcCST=0 with exact-funding comment, dstCST=0), INV-F4, INV-F2, dstCST at destination, INV-F8
- 3 full-happy-path assertions (over-funded): dstCST at destination, residual srcCST retained on adapter, INV-F2
- 1 resolved-caller debitFrom happy path (INV-F6)
- 1 third-party subaccount debitFrom happy path
- 1 destination-callback reentrancy — documented non-reproducible gap (plain ERC-20 transfers do not call a recipient callback; matches landed filler framing). Asserts post-execute invariants rather than a guard-revert selector.
- 1 back-to-back execute-in-same-batch happy path (transient guard clears between `BatchItem`s)

### 4.2 `EvcRolloverAdapter_execute_Partial` — 58 leaves

Draft tree: `plan/btt-draft/EvcRolloverAdapter_execute_Partial.tree`.

Branch summary (validation order: zero-destination fires first):

- 1 destination zero-address guard (first)
- 2 EVC caller-resolution guards
- 4 pre-balance-check paths (zero / short / exact / over-funded)
- 1 srcCstAmount zero (cellar `ZeroRollover`)
- 2 `SETTLER.openFor` revert paths (`InvalidSignature`, `InconsistentIntent` — Partial must have `allowPartialFills == true`)
- 1 openFor idempotent no-op
- 4 fillerData construction assertions (outputIndex 0 prefix, `targetFiller == address(this)`, embedded `CellarIntent`, embedded `cellarSig`)
- 7 rollover-leg `fill` revert paths (`FillAfterDeadline`, `TargetFillerMismatch`, `AlreadyFilledByFiller`, `ZeroRollover`, `IntentNotBoundToOrder`, `DisproportionateOutput` — requires malicious-cellar fixture parity with `test/partial/PartialFillSettler_maliciousCellar.t.sol:49` — `OrderInTerminalState`)
- 6 rollover-leg happy-path assertions for exact fill (FillerRollover entry, `srcCstProvided`, `dstCstProduced`, `destination`, flags false, allowance reset)
- 2 rollover-leg happy-path assertions for underfill (`srcCstProvided == actualRolled`, leftover retained on adapter — no caller-return)
- 4 premium-leg `fill` revert paths (`NoRolloverLegForFiller`, `AlreadySettled`, `UnauthorizedDebitFrom`, `InsufficientBalance`)
- 4 premium-leg happy-path assertions (ceil-rounded debit, premium to cellar, `premiumSettled == true`, exactly one phase-1 hook fire)
- 1 premium-hook revert atomicity
- 3 `finaliseAsSettled(orderDigest, [address(this)])` happy-path assertions (dstCST to destination, `finalised == true`, `totalDstCstEscrowed` decrement)
- 1 `finaliseAsSettled` revert path (`InvalidOrderStatus`)
- 1 second-adapter-on-**same**-digest **terminal-state revert** — atomic `execute` finalises immediately via `finaliseAsSettled(digest, [address(this)])`, driving the order terminal. A second adapter calling `execute` on the same digest reverts at the rollover leg with `OrderInTerminalState`. (Previous versions of this spec treated this path as positive success; corrected to match landed `PartialFillSettler` semantics at `contracts/settlers/PartialFillSettler.sol:114` and the positive-isolation case at `test/filler/integration/RolloverFiller_PartialTwoFillers.t.sol:15` which uses staged non-finalising fills, not the adapter's atomic path.)
- 3 second-adapter-on-**different**-digest positive isolation (deploys a second `EvcRolloverAdapter(partialSettler, true, ...)`; the second adapter runs `execute` on a distinct orderDigest concurrently with the first; separate FillerRollover entry; no slot collision per INV-P1; independent settlement — exercises DP-EVC-A's per-subaccount Partial deployment model under atomic-execute semantics)
- 5 full-happy-path assertions, exact fill (INV-F1, INV-F2, INV-F4, INV-F8, dstCST at destination)
- 2 full-happy-path assertions, underfill (INV-F2, dstCST at destination — no INV-F3)
- 1 resolved-caller debitFrom happy path (INV-F6)
- 1 third-party subaccount debitFrom happy path
- 1 destination-callback reentrancy — documented non-reproducible gap (plain ERC-20 transfers do not call a recipient callback). Asserts post-execute invariants rather than a guard-revert selector.
- 1 back-to-back execute-in-same-batch happy path on a different orderDigest

### 4.3 Leaf-count totals

| Tree | Leaves |
|---|---:|
| `EvcRolloverAdapter_execute_Exact` | 48 |
| `EvcRolloverAdapter_execute_Partial` | 58 |
| **Total BTT leaves** | **106** |

Integration + invariant tests are additional — see §6 and §7.

---

## 5. Integrator Requirements Matrix

Every requirement in RFC 003 §7.5 MUST map to at least one test (or an explicit N/A).

| # | Requirement (RFC 003 §7.5) | Test Name(s) / Disposition |
|---|---|---|
| 1 | Atomic execution | Every revert branch in both trees + `invariant_F7_atomicRevertParity` |
| 2 | Simulate before fill | N/A — off-chain (bot via `evc.batchSimulation`) concern |
| 3 | Simulate `finalise` independently (multi-tx) | N/A — multi-tx profile out of scope; atomic-only |
| 4 | Single-frame cST movements | Inherited from settler (INV-S9 / INV-C). Adapter-side: `test_execute_allCstMovementsInOneFrame` (Exact + Partial) |
| 5 | Same-CA pool pairs only | Inherited from settler. Adapter-side: `test_execute_delegatesCaValidationToSettler` (negative path with mismatched CA bubbles settler revert) |
| 6 | Handle leftover tokens | Inverted for EVC reference adapter: `test_execute_retainsLeftoverOnAdapter` — adapter never routes leftovers to caller per RFC §7.3. Documented in the integrator README: curators MUST compose a sibling sweep step in `evc.batch([...])` if they want leftover routing. |
| 7 | ERC-6909 prerequisites | `test_execute_revertsIfErc6909BalanceInsufficient`, `test_execute_revertsIfSettlerNotAuthorizedOnErc6909`, `test_execute_revertsIfThirdPartyDebitFromLacksOperatorAuth` |
| 8 | No legacy hooks | Inherited. Adapter never constructs `executeHooks` calls. |
| 9 | Deadline staggering | Off-chain (Cork API policy). N/A. |
| 10 | Minimum open incentive | Off-chain (Cork API policy). N/A. |
| 11 | ERC-6909 commitment tracking | Off-chain. Documented as a WARNING in the integrator README; no adapter-level test. |
| 12 | Partial-fill finalisation keeper scaling (`finaliseAsSettled(digest, [self])` self-service; over-sized `fillers[]` array self-reverts) | Satisfied by design in both bindings — the Partial path always calls `finaliseAsSettled(digest, [address(this)])` inside `execute`, which self-services per RFC §7.5 item 12. No keeper dependency. The over-sized array path is exercised by the settler's own unit tests; not duplicated here. |

---

## 6. Invariant Tests

Handler-based invariants targeting the adapter layer. Named with `INV-F` prefix (shared namespace with the `RolloverFiller` invariants; see `plan/filler-test-spec.md` §6 for the source definitions). Deltas vs the landed filler invariants are noted.

| ID | Invariant | Handler action surface | Assertion |
|---|---|---|---|
| **INV-F1** ⚠ | Adapter holds zero dstCST and no token beyond the caller-supplied pre-balance excess | `execute` variants over random orders (Exact + Partial weighted) inside `evc.batch` | `erc20.balanceOf(adapter) == ghostPreBalanceExcess[adapter][token]` for every token referenced by any order run, where `ghostPreBalanceExcess` tracks the over-funding delta (srcCST pre-balance minus srcCstAmount at entry time) plus any underfill leftover. `balanceOf(adapter, dstCST) == 0` unconditionally. |
| **INV-F2** | No dangling approvals | Same | For every (token, spender) pair touched, `token.allowance(adapter, spender) == 0` after action returns. |
| **INV-F3** ✗ | ~~Caller receives leftover srcCST~~ | — | **Dropped.** Reference adapter does not route leftovers (RFC §7.3). |
| **INV-F4** | Adapter holds zero ERC-6909 units | Same | `erc6909.balanceOf(adapter, tokenId) == 0` for every tokenId touched. |
| **INV-F5** | Adapter is never an ERC-6909 operator of anyone | Same | `erc6909.isOperator(any, adapter) == false` post-action. |
| **INV-F6** ✓ | EVC caller resolution | `execute` wrapped in `evc.batch([item with onBehalfOfAccount=subaccount])` | For every successful `execute`, the settler records `msg.sender == address(adapter)` (not the EVC) and the subaccount that authorised the adapter is the one whose ERC-6909 balance is debited when `debitFrom == resolvedCaller`. |
| **INV-F7** | Atomic revert parity | Handler includes revert-paths as equally-weighted actions | On any revert from `execute` (surfaced as a revert of the whole `evc.batch`), all pre-state is restored (adapter balances, adapter allowances, caller balances, ERC-6909, settler `orderStatus`, settler `fillRecords`, `fillerRollovers`). |
| **INV-F8** | Adapter emits no events of its own | Every action | `vm.recordLogs()` → zero logs whose `emitter == address(adapter)`. |

> **INV-F6 is activated here** (it was declared but skipped in `RolloverFiller`'s invariant suite per DP-D deferral). The handler ensures every action goes through `evc.batch([...])` so `getCurrentOnBehalfOfAccount` is always non-zero.

Handler distributes actions across `evcAdapterExact` and `evcAdapterPartial` in weighted fashion. Ghost state separates ledgers by adapter so per-adapter assertions are unambiguous.

---

## 7. Integration Tests

End-to-end flows exercising `EvcRolloverAdapter` (both bindings) + real `EVC` + settler + cellar + ERC-6909 + Phoenix. Mirror the style of `RolloverLifecycle.t.sol` and the landed `RolloverFiller` integration suite.

Minimum set:

| # | Test File | Scenario |
|---|---|---|
| 1 | `test/filler/evc/integration/EvcRolloverAdapter_ExactHappyPath.t.sol` | Curator authorises `evcAdapterExact` as an EVC operator on their subaccount. `evc.batch([seedAdapterWithSrcCst, adapter.execute, sweepLeftover])` — end state: UW cellar holds dstCPT + premium; destination (curator subaccount) holds dstCST; adapter holds zero. |
| 2 | `test/filler/evc/integration/EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests.t.sol` | Two distinct `EvcRolloverAdapter(partialSettler, true, ...)` instances deployed against two distinct subaccounts. Each subaccount runs its own `evc.batch([seed, execute])` on a **distinct** Partial order digest (two different UW orders). Both adapters succeed independently — no slot collision per INV-P1. This exercises DP-EVC-A's per-subaccount deployment requirement under atomic-execute semantics. **Corrected from an earlier version that tested same-digest concurrent fills — that path cannot succeed because atomic `execute` finalises immediately, driving the first order terminal; see scenario #2b for the terminal-state revert case.** |
| 2b | `test/filler/evc/integration/EvcRolloverAdapter_PartialSameDigestTerminal.t.sol` | Two distinct `EvcRolloverAdapter(partialSettler, true, ...)` instances. Adapter-A runs `execute` on digest-X and finalises. Adapter-B then runs `execute` on the same digest-X — reverts at the rollover leg with `OrderInTerminalState`. Asserts atomic-execute's self-finalising semantics close out the order to other adapters. |
| 3 | `test/filler/evc/integration/EvcRolloverAdapter_DirectCallRejected.t.sol` | Calling `adapter.execute(...)` directly (not inside `evc.batch` / `evc.call`) reverts with `EvcRolloverAdapter__InvalidCaller`. Also: calling from a contract that is not EVC-aware bubbles the same revert. |
| 4 | `test/filler/evc/integration/EvcRolloverAdapter_InsufficientPreBalance.t.sol` | `evc.batch([seed=reduced, execute])` where the seed under-funds the adapter → `execute` reverts with `EvcRolloverAdapter__InsufficientTokens(token, required, available)`; whole batch reverts atomically. Also: a batch with no seed at all reverts with available=0. |
| 5 | `test/filler/evc/integration/EvcRolloverAdapter_RefundPath.t.sol` | Premium leg fails inside `execute` (short ERC-6909 on `debitFrom`) → full `evc.batch` reverts; no state change. Separately: a rollover-only fill path where a keeper (not through the adapter) calls `finaliseAsRefunded` post-`fillDeadline`. |
| 6 | `test/filler/evc/integration/EvcRolloverAdapter_CallPath.t.sol` | Smoke test for the `evc.call` path: adapter invoked via `evc.call(adapter, subaccount, 0, calldata)` instead of `evc.batch` — `getCurrentOnBehalfOfAccount` resolves correctly, happy path completes. Asserts the adapter does not require `batch` specifically. |

Scenarios considered but **excluded**:
- Direct vault (EVault / ERC-4626) integration — out of scope per Q3 (adapter is pure settler orchestration; vault IO lives in sibling batch items). Curators compose those siblings themselves.
- ERC-1271 UW signature — covered by the landed `RolloverFiller_Erc1271UwSignature.t.sol`; `openFor` path is shared.
- Safe-direct-settler (§7.4) — DP-E docs-only in the `RolloverFiller` plan; no equivalent EVC variant scheduled.
- Multi-tx execution profile — atomic-only by design.

---

## 8. File Layout

```
contracts/
├── fillers/
│   ├── RolloverFiller.sol            # landed
│   └── EvcRolloverAdapter.sol        # new
└── interfaces/
    ├── IRolloverFiller.sol           # landed
    └── IEvcRolloverAdapter.sol       # new

test/
└── filler/
    ├── BaseTestFiller.sol                         # landed
    ├── BaseTestEvcFillerAdapter.sol               # new, extends BaseTestFiller
    ├── infra/HarnessSmoke.t.sol                   # landed
    └── evc/
        ├── infra/
        │   └── HarnessSmoke.t.sol                 # EVC-specific smoke
        ├── exact/
        │   ├── EvcRolloverAdapter_execute.tree
        │   └── EvcRolloverAdapter_execute.t.sol
        ├── partial/
        │   ├── EvcRolloverAdapter_execute.tree
        │   └── EvcRolloverAdapter_execute.t.sol
        ├── invariant/
        │   ├── EvcAdapterInvariantHandler.sol
        │   └── EvcAdapterInvariant.t.sol
        └── integration/
            ├── EvcRolloverAdapter_ExactHappyPath.t.sol
            ├── EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests.t.sol
            ├── EvcRolloverAdapter_PartialSameDigestTerminal.t.sol
            ├── EvcRolloverAdapter_DirectCallRejected.t.sol
            ├── EvcRolloverAdapter_InsufficientPreBalance.t.sol
            ├── EvcRolloverAdapter_RefundPath.t.sol
            └── EvcRolloverAdapter_CallPath.t.sol

script/
└── foundry-scripts/
    └── DeployEvcAdapters.s.sol

lib/
└── ethereum-vault-connector/         # new submodule (forge install)
```

---

## 9. PR Chunking

Five-PR stacked layout, one `execute-cork` run per PR. Tests and impl ship on **separate branches**; the impl branch bases on the test branch and turns red tests green. Full rationale in `plan/evc-adapter-implementation-plan.md`.

| PR | Branch | Test Scope | Impl Scope | Gate |
|---|---|---|---|---|
| **1** | `feat/evc-adapter-interfaces-and-stubs` | `test/filler/evc/infra/HarnessSmoke.t.sol` + `BaseTestEvcFillerAdapter` smoke | EVC submodule + remap + `IEvcRolloverAdapter` + reverting stub + harness | `forge build` PASS; smoke PASS; `forge fmt --check` PASS; `mise fmt-check` PASS |
| **2a** | `test/evc-adapter-btt` | `test/filler/evc/exact/*` (48 leaves) + `test/filler/evc/partial/*` (58 leaves) from draft trees | — | `forge build` PASS; 48 + 58 = 106 FAIL red; `forge fmt --check` PASS; `mise fmt-check` PASS |
| **2b** | `impl/evc-adapter` | none | `EvcRolloverAdapter.sol` parameterised for Exact + Partial | 106 EVC tests PASS; `RolloverFiller` suite still PASS (no regression); infra still PASS; `forge fmt --check` PASS; `mise fmt-check` PASS |
| **3a** | `test/evc-adapter-invariants-and-integration` | `test/filler/evc/invariant/*` + `test/filler/evc/integration/*` (7 scenarios) | — | build PASS; up to 3 documented failures allowed (PR 3a is carved out of the test-first fail-red rule — zero failures also acceptable); `forge fmt --check` PASS; `mise fmt-check` PASS |
| **3b** | `impl/evc-adapter-integration-and-deploy` | none | Impl fixes + `script/foundry-scripts/DeployEvcAdapters.s.sol` | ALL `test/filler/evc/*` PASS; `test/filler/*` (incl. landed filler) still PASS; deploy script dry-run PASS; `forge fmt --check` PASS; `mise fmt-check` PASS |

Strictly sequential merge order: PR 1 → 2a → 2b → 3a → 3b. Every child rebases on its parent after merge (see `plan/evc-adapter-implementation-plan.md` "Rebase discipline").
