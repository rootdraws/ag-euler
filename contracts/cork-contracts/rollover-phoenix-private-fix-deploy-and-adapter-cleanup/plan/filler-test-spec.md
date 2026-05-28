# Rollover Filler Contracts — Test Specification

> Covers `RolloverFiller` — the RFC 003 §7.2 reference implementation. Parameterised per settler type (DP-A resolved): one contract, two deployments — one bound to `ExactFillSettler`, one to `PartialFillSettler`. `EvcRolloverAdapter` is out of scope (DP-D). The AvantGarde Safe pattern (§7.4) is docs-only (DP-E). Multi-tx execution profile is docs-only.
>
> Tests structured using **Branching Tree Technique (BTT)**: one `.tree` file per (function × settler binding) defines the control-flow tree; each leaf (`it should ...`) becomes a test case. Trees are the source of truth.
>
> **Test + implementation split:** Tree + tests ship on a `test/...` branch that gates on `forge test` **failing red** against the stub. Implementation ships on a stacked `impl/...` branch that turns the tests green. See `plan/filler-implementation-plan.md` for the full PR stack.
>
> **Test organization:** Co-located — each `.tree` lives next to its `.t.sol` in the same domain folder. Exact and Partial paths get separate tree files under `test/filler/exact/` and `test/filler/partial/`.
>
> **Mocking policy:** Use the **real** `CorkCellar` + `CorkCellarFactory` + rhinestone `Registry` + Phoenix pool manager via `BaseTestCorkCellar` (reached through `BaseTestSettler` → `BaseTestFiller`). Use the **real** `ExactFillSettler`, `PartialFillSettler`, and `ERC6909Premium` from the landed settler stack. No new mocks. The existing `test/mocks/MockERC1271Signer.sol` is re-used for the ERC-1271 UW integration scenario.

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
- Root node → test contract name (e.g., `RolloverFiller_execute_Exact`)
- `when` nodes → `modifier when<Condition>() { _; }` in the test contract
- `it should` leaves → `function test_<What>() external when<A> when<B> { ... }`
- `test_RevertWhen_<Condition>` for revert branches
- `test_<functionName>_<whatItDoes>` for success branches

**Scaffolding:** Use [`bulloak`](https://github.com/alexfertel/bulloak) to generate Solidity test stubs from `.tree` files, and `bulloak check` in CI to keep trees and tests in sync. Matches the cellar-private + landed settler convention.

**Two test contracts per function** (Exact binding + Partial binding). Each inherits `BaseTestFiller` and targets exactly one `(execute, settler type)` pair. The function under test is the same; the tree and leaves diverge where the settler-type discriminant changes behaviour.

### Test-first / impl-second discipline

Every test-only PR MUST fail red against the current implementation on its parent branch. If a test-only PR passes against the stub or against the Exact-only impl (when Partial tests land), that means the test is asserting the wrong thing — stop and fix the test before merge.

Every impl-only PR MUST turn the preceding test PR's failing suite green **without regressing** any earlier test PR's passing suite. Regressions are stop-ship.

### Fuzz & Invariant Fuzzing

- Handler contracts expose bounded `execute` actions and maintain ghost state (srcCST deposited, premium prepaid, dstCST expected at destination, caller baseline balances). Invariant contracts target the handler and assert one property per `invariant_` function.
- Per-function fuzz tests cover value ranges on `srcCstAmount` (including 0, `orderSize`, and `orderSize + ε` overfund) and on `debitFrom` selection (caller vs third-party authoriser).

### Real-contract policy

Fillers are caller-side orchestration — their correctness is meaningful **only** when wired to the real settler + ERC-6909 + cellar + Phoenix. Every leaf under `test/filler/` runs against the real stack.

---

## 2. Test Infrastructure

### 2.1 Version alignment

Already aligned from the landed settler stack: Solc 0.8.30, EVM `prague`, `via_ir = true`, `optimizer_runs = 1_000_000`. No pragma work in this spec.

### 2.2 Remappings

No additions. All infrastructure reachable through the existing remap set (cellar, phoenix, openzeppelin, forge-std).

### 2.3 Test Harness (`BaseTestFiller`)

Inherits **`BaseTestSettler`** (landed). Adds:

- `RolloverFiller rolloverFillerExact` — deployed with `address(exactSettler)`.
- `RolloverFiller rolloverFillerPartial` — deployed with `address(partialSettler)`.
- Convenience helpers:
  - `_prepareFillerState(actor, filler, srcCstAmount, premiumToken, premiumAmount)` — one-shot: deposit premium via ERC-6909, `setOperator(settlerOfFiller, true)`, approve filler to pull srcCST.
  - `_executeRollover(filler, order, signature, originFillerData, srcCstAmount, debitFrom, destination)` — wrapper around `filler.execute(...)` that encodes `order` as `bytes orderData` per DP-B. No `solveParams` — dropped in plan revision after verifying no consumer on either `finaliseAsSettled` surface.
  - `_settlerOf(filler)` — staticcall helper to read `RolloverFiller.SETTLER()`.
  - `_fillerSnapshot(filler)` — post-execute asserter for INV-F1 (zero token holdings) + INV-F2 (zero approvals). Iterates every token used by any order touched during the test.
  - `_computeOrderDigest(order)` — helper for the Partial-path `finaliseAsSettled(orderDigest, fillers[])` assertion (delegates to `LibSettlerHashing.computeOrderDigest`).

### 2.4 Signing helpers

Inherited from `BaseTestSettler` (`_signOrder`, `_signOrderWithSmartWallet`, `_signCancel`, `_createRolloverOrder`, `_buildExactRolloverFillerData`, `_buildExactPremiumFillerData`, `_buildPartialFillerData`). No additions.

### 2.5 Foundry profile

Inherited from the landed settler stack. No changes.

---

## 3. Contract Surface Summary

| Contract | External/Public Functions | Tree Files | Role |
|---|:---:|:---:|---|
| `RolloverFiller` | 1 (`execute`) | 2 (Exact binding + Partial binding) | Retail / simple-bot reference filler (RFC 003 §7.2). One contract, two deployments. |

**Expected test contract names:**
- `RolloverFiller_execute_Exact` — tree: `test/filler/exact/RolloverFiller_execute.tree`; tests: `RolloverFiller_execute.t.sol`.
- `RolloverFiller_execute_Partial` — tree: `test/filler/partial/RolloverFiller_execute.tree`; tests: `RolloverFiller_execute.t.sol`.

Invariant handler + test live under `test/filler/invariant/`. Integration scenarios under `test/filler/integration/`.

---

## 4. BTT Tree Outlines

Trees are authored in full alongside this spec and live at `plan/btt-draft/`. The execute-cork runs for PR 2a and PR 3a copy them into `test/filler/exact/` and `test/filler/partial/` respectively, then scaffold `.t.sol` via `bulloak`. Any leaf edits during authoring MUST update the draft tree in `plan/btt-draft/` in the same PR so this spec stays the source of truth.

### 4.1 `RolloverFiller_execute_Exact` — 44 leaves

Draft tree: `plan/btt-draft/RolloverFiller_execute_Exact.tree`.

Branch summary (each branch has 1+ leaves; full bodies in the draft file):
- 1 destination zero-address guard
- 1 srcCstAmount zero (settler-side revert)
- 3 srcCST transferFrom failure modes (no allowance / short balance / token reverts)
- 4 `SETTLER.openFor` revert paths (`InvalidSignature`, `NotMaker`, `InconsistentIntent`, `InvalidOrderTokenPair`)
- 1 openFor idempotent no-op on already-Opened order
- 6 rollover-leg `fill` revert paths (`FillAfterDeadline`, `AlreadyFilled`, `PartialFillNotAllowed`, `IntentNotBoundToOrder`, `DisproportionateOutput`, `OrderInTerminalState`)
- 4 rollover-leg happy-path assertions (allowance set, FillRecord observed, dstCST escrowed, allowance reset to 0 before premium leg)
- 5 premium-leg `fill` revert paths (`PremiumBeforeRollover`, `AlreadyFilled`, `InsufficientBalance`, `UnauthorizedSettler`, `UnauthorizedPremiumFiller`)
- 4 premium-leg happy-path assertions (debit == requiredPremium, premium delivered to cellar, `paymentSettled == true`, zero residual srcCST allowance)
- 1 premium-hook revert atomicity
- 2 `finaliseAsSettled` revert paths (`InvalidOrderStatus`, `PaymentNotSettled`) — `InvalidFillRecord` removed per CONSOLIDATED.md P24-G2 (unreachable through any live flow; covered by settler's own unit tests)
- 7 full-happy-path assertions, no underfill (INV-F1 × 2, INV-F4, INV-F2, dstCST at destination, zero leftover, INV-F8)
- 2 full-happy-path assertions, with underfill (dstCST at destination, leftover returned — INV-F3)
- 1 reentrant-destination guard
- 1 third-party `debitFrom` happy path

### 4.2 `RolloverFiller_execute_Partial` — 50 leaves

Draft tree: `plan/btt-draft/RolloverFiller_execute_Partial.tree`.

Branch summary:
- 1 destination zero-address guard
- 1 srcCstAmount zero (cellar-side `ZeroRollover`)
- 2 srcCST transferFrom failure modes
- 2 `SETTLER.openFor` revert paths (`InvalidSignature`, `InconsistentIntent` — Partial must have `allowPartialFills == true`)
- 1 openFor idempotent no-op
- 4 fillerData construction assertions (outputIndex 0 prefix, `targetFiller == address(this)`, embedded `CellarIntent` struct, embedded `cellarSig`)
- 6 rollover-leg `fill` revert paths (`FillAfterDeadline`, `TargetFillerMismatch`, `AlreadyFilledByFiller`, `ZeroRollover`, `IntentNotBoundToOrder`, `OrderInTerminalState`)
- 6 rollover-leg happy-path assertions for exact fill (FillerRollover entry keyed on `(orderDigest, address(this))`, `srcCstProvided == srcCstAmount`, `dstCstProduced` from cellar, `destination` stored, flags false, allowance reset)
- 2 rollover-leg happy-path assertions for underfill (`srcCstProvided == actualRolled`, leftover returned)
- 4 premium-leg `fill` revert paths (`NoRolloverLegForFiller`, `AlreadySettled`, `UnauthorizedDebitFrom`, `InsufficientBalance`)
- 4 premium-leg happy-path assertions (ceil-rounded premium debit, premium to cellar, `premiumSettled == true`, exactly one phase-1 hook fire)
- 1 premium-hook revert atomicity
- 3 `finaliseAsSettled(orderDigest, [address(this)])` happy-path assertions (dstCST to destination, `finalised == true`, `totalDstCstEscrowed` decrement)
- 1 `finaliseAsSettled` revert path (`InvalidOrderStatus`)
- 3 second-filler-contract-on-same-digest assertions (test deploys a second `RolloverFiller(partialSettler, true)`; separate FillerRollover entry keyed on the second contract's address, no slot collision per INV-P1, independent settlement — exercises DP-A's per-user Partial deployment model)
- 5 full-happy-path assertions, exact fill (INV-F1, INV-F2, INV-F4, INV-F8, dstCST at destination)
- 2 full-happy-path assertions, underfill (INV-F3, dstCST at destination)
- 1 reentrant-destination guard
- 1 third-party `debitFrom` happy path

### 4.3 Leaf-count totals

| Tree | Leaves |
|---|---:|
| `RolloverFiller_execute_Exact` | 44 |
| `RolloverFiller_execute_Partial` | 50 |
| **Total BTT leaves** | **94** |

Integration + invariant tests are additional — see §6 and §7.

---

## 5. Integrator Requirements Matrix

Every requirement in RFC 003 §7.5 MUST map to at least one test (or an explicit N/A).

| # | Requirement (RFC 003 §7.5) | Test Name(s) / Disposition |
|---|---|---|
| 1 | Atomic execution | `RolloverFiller_execute_Exact::test_execute_revertsIfAnyStepReverts` (one leaf per revert branch) + `test_execute_revertsOnReentry` |
| 2 | Simulate before fill | N/A for filler tests — off-chain integrator concern. Documented in integrator README. |
| 3 | Simulate `finalise` independently (multi-tx) | N/A — multi-tx profile out of scope; reference filler is atomic-only. |
| 4 | Single-frame cST movements | Inherited from settler (INV-S9 / INV-C). Filler-side: `test_execute_allCstMovementsInOneFrame` — assert no intermediate settled state between legs. |
| 5 | Same-CA pool pairs only | Inherited from settler. Filler-side: `test_execute_delegatesCaValidationToSettler` (negative path with mismatched CA bubbles settler revert). |
| 6 | Handle leftover tokens | `test_execute_returnsLeftoverSrcCstToCaller` + INV-F3. |
| 7 | ERC-6909 prerequisites | `test_execute_revertsIfErc6909BalanceInsufficient`, `test_execute_revertsIfSettlerNotAuthorizedOnErc6909`, `test_execute_revertsIfThirdPartyDebitFromLacksOperatorAuth` |
| 8 | No legacy hooks | Inherited from settler/cellar. Filler-side: no dedicated test — the filler never constructs `executeHooks` calls, so there is no path to regress. |
| 9 | Deadline staggering | Off-chain (Cork API policy). N/A. |
| 10 | Minimum open incentive | Off-chain (Cork API policy). N/A. |
| 11 | ERC-6909 commitment tracking | Off-chain. Documented as a WARNING in the integrator README; no filler-level test. |

---

## 6. Invariant Tests

Handler-based invariants targeting the filler layer. Named with `INV-F` prefix to distinguish from INV-S (settler), INV-P (partial), INV-C (cellar), EINV (ERC-6909).

| ID | Invariant | Handler action surface | Assertion |
|---|---|---|---|
| **INV-F1** | Filler contract holds zero tokens post-execute | `execute` variants over random orders (Exact + Partial weighted) | For every token referenced by any order run, `token.balanceOf(filler) == 0` after each action returns. |
| **INV-F2** | No dangling approvals | Same | For every (token, spender) pair touched, `token.allowance(filler, spender) == 0` after action returns. |
| **INV-F3** | Caller receives leftover srcCST | `execute` with randomised `srcCstAmount >= actualRolled` | `(srcCST.balanceOf(caller)_after - srcCST.balanceOf(caller)_before) == srcCstAmount - actualRolled`. |
| **INV-F4** | Filler holds zero ERC-6909 units | Same | `erc6909.balanceOf(filler, tokenId) == 0` for every tokenId touched. |
| **INV-F5** | Filler is never an ERC-6909 operator of anyone | Same | `erc6909.isOperator(any, filler) == false` post-action. |
| **INV-F7**¹ | Atomic revert parity | Handler includes revert-paths as equally-weighted actions | On any revert from `execute`, all pre-state is restored (filler balances, filler allowances, caller balances, ERC-6909, settler `orderStatus`, settler `fillRecords`, `fillerRollovers`). |
| **INV-F8**¹ | Filler emits no events of its own | Every action | `vm.recordLogs()` → zero logs whose `emitter == address(filler)`. |

¹ INV-F7 and INV-F8 are **filler-policy invariants** derived from RFC 003 §7.5 item 1 (atomic execution) and the RFC's general "thin wrapper" framing for the reference filler, not explicit RFC numbered invariants. INV-F1..F5 are directly derivable from RFC 003 §7.2 + §7.5 item 6.

> INV-F6 (EVC caller resolution) is defined but skipped — EVC out of scope per DP-D. Reserved number so renumbering isn't needed when EVC lands.

Handler distributes actions across `rolloverFillerExact` and `rolloverFillerPartial` in weighted fashion. Ghost state separates ledgers by filler so per-filler assertions are unambiguous.

---

## 7. Integration Tests

End-to-end flows exercising `RolloverFiller` (both bindings) + settler + cellar + ERC-6909 + Phoenix. Mirror the style of `test/integration/RolloverLifecycle.t.sol`.

Minimum set:

| # | Test File | Scenario |
|---|---|---|
| 1 | `test/filler/integration/RolloverFiller_ExactHappyPath.t.sol` | UW signs GaslessCrossChainOrder (Exact) → `rolloverFillerExact.execute` → UW cellar holds dstCPT + premium; destination holds dstCST. |
| 2 | `test/filler/integration/RolloverFiller_PartialTwoFillers.t.sol` | Two distinct fillers each call `rolloverFillerPartial.execute` against the same Partial order; cumulative fills reach `orderSize`; both `finaliseAsSettled` paths drain escrow. |
| 3 | `test/filler/integration/RolloverFiller_RefundPath.t.sol` | Premium leg fails inside `execute` (e.g. insufficient ERC-6909); full tx reverts. Separately: a rollover-only fill path where a keeper (not the filler contract) calls `finaliseAsRefunded` post-deadline. |
| 4 | `test/filler/integration/RolloverFiller_CancelNoFills.t.sol` | UW cancels an Opened order pre-fill. Subsequent `RolloverFiller.execute` reverts with the settler's `InvalidOrderStatus`. Also include a cross-binding isolation assertion: calling `rolloverFillerExact.execute` with `orderData` signed for a Partial order (or vice versa) reverts with the settler-side revert corresponding to the incompatible `allowPartialFills` flag — exercises that the constructor-flag binding and the settler's validation guards stay in sync. |
| 5 | `test/filler/integration/RolloverFiller_Erc1271UwSignature.t.sol` | UW is a contract wallet returning ERC-1271 `isValidSignature`. Uses existing `test/mocks/MockERC1271Signer.sol`. Proves `openFor` signature-recovery works through the filler for smart-wallet UWs. |

Scenarios that were considered but **excluded**:
- EVC-batch path — DP-D out of scope.
- Safe-direct-settler (§7.4) — DP-E docs-only.
- ERC-6909 cascading failure — off-chain concern per §7.5 item 11.

---

## 8. File Layout

```
contracts/
├── fillers/
│   └── RolloverFiller.sol
└── interfaces/
    └── IRolloverFiller.sol

test/
└── filler/
    ├── BaseTestFiller.sol
    ├── infra/
    │   └── HarnessSmoke.t.sol
    ├── exact/
    │   ├── RolloverFiller_execute.tree
    │   └── RolloverFiller_execute.t.sol
    ├── partial/
    │   ├── RolloverFiller_execute.tree
    │   └── RolloverFiller_execute.t.sol
    ├── invariant/
    │   ├── FillerInvariantHandler.sol
    │   └── FillerInvariant.t.sol
    └── integration/
        ├── RolloverFiller_ExactHappyPath.t.sol
        ├── RolloverFiller_PartialTwoFillers.t.sol
        ├── RolloverFiller_RefundPath.t.sol
        ├── RolloverFiller_CancelNoFills.t.sol
        └── RolloverFiller_Erc1271UwSignature.t.sol

script/
└── foundry-scripts/
    └── DeployFillers.s.sol

docs/
└── integrations/
    └── safe-direct-settler.md    # RFC §7.4 docs-only recipe (DP-E)
```

---

## 9. PR Chunking

Seven-PR stacked layout, one `execute-cork` run per PR. Tests and impl ship on **separate branches**; the impl branch bases on the test branch and turns red tests green. Full rationale in `plan/filler-implementation-plan.md`.

| PR | Branch | Test Scope | Impl Scope | Gate |
|---|---|---|---|---|
| **1** | `feat/filler-interfaces-and-stubs` | `test/filler/infra/HarnessSmoke.t.sol` + `BaseTestFiller` smoke | Interface + reverting stub + harness | `forge build` PASS; smoke PASS; `forge fmt --check` PASS |
| **2a** | `test/filler-exact-btt` | `test/filler/exact/*` — 44 leaves from draft tree | — | `forge build` PASS; 44 exact tests FAIL red; `forge fmt --check` PASS |
| **2b** | `impl/filler-exact` | none | `RolloverFiller.sol` Exact-settler body | 44 exact tests PASS; infra still PASS; `forge fmt --check` PASS |
| **3a** | `test/filler-partial-btt` | `test/filler/partial/*` — 50 leaves from draft tree | — | `forge build` PASS; 50 partial tests FAIL red; `forge fmt --check` PASS |
| **3b** | `impl/filler-partial` | none | `RolloverFiller.sol` parameterised (Exact + Partial routing) | 50 partial + 44 exact + infra all PASS; `forge fmt --check` PASS |
| **4a** | `test/filler-invariants-and-integration` | `test/filler/invariant/*` + `test/filler/integration/*` | — | build PASS; up to 3 documented failures allowed (test name + hypothesis + linked 4b task); `forge fmt --check` PASS |
| **4b** | `impl/filler-integration-and-deploy` | none | Impl fixes + `script/foundry-scripts/DeployFillers.s.sol` | ALL filler tests PASS; deploy script dry-run PASS; `forge fmt --check` PASS |

Strictly sequential merge order: PR 1 → 2a → 2b → 3a → 3b → 4a → 4b. Every child rebases on its parent after merge (see `plan/filler-implementation-plan.md` "Rebase discipline").
