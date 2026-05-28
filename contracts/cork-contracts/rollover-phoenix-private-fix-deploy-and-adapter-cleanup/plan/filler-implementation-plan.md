# Rollover Filler Contracts Implementation Plan

> **Execution method:** `execute-cork` skill — one Opus agent run per PR, sequential across PRs. Each PR is one execute-cork run; within a run, multiple agents may dispatch in parallel for file-level work on one task, but never across tasks.
>
> **Discipline:** Tests and implementation ship in **separate stacked PRs**. Tree + failing tests land first on a `test/...` branch; implementation lands second on an `impl/...` branch that bases on the test branch. This splits the work along the axis `execute-cork` uses internally — it dispatches `write-solidity-tests-cork` for test-only tasks and `write-solidity-cork` for implementation tasks. Keeping each PR's task set single-purpose lets each run route to one specialised skill rather than juggling both, which the settler plan's "one branch per chunk" style had to do.
>
> **Test details:** See `plan/filler-test-spec.md` for the full BTT tree inventory, leaf counts, invariant matrix, mock policy, and infrastructure design. This plan covers only execution steps, source-side changes, and dependency ordering.

**Goal:** Deliver the `RolloverFiller` reference implementation specified in RFC 003 §7.2. Parameterised per settler type — one contract, two deployments (one bound to `ExactFillSettler`, one to `PartialFillSettler`). `EvcRolloverAdapter` (§7.3) is **out of scope** for this stack. The AvantGarde Fund pattern (§7.4) is documented only; no contract, no integration test.

**Architecture:** `RolloverFiller` is a thin, reentrancy-guarded wrapper around an immutable settler reference. It exposes a single `execute(bytes orderData, bytes signature, bytes originFillerData, uint256 srcCstAmount, address debitFrom, address destination)` that (a) pulls srcCST from `msg.sender`, (b) calls `openFor`, (c) calls `fill` twice (rollover leg then premium leg), (d) calls the concrete's `finaliseAsSettled`, and (e) returns leftover srcCST to the caller. Holds no persistent state. Never custodies premium tokens — premium flows through `ERC6909Premium` via the settler's `_settle()` primitive. One contract; the constructor binds it to an Exact or Partial settler at deployment via `(address settler, bool isPartial)`. Builds on the already-landed settler + ERC-6909 stack (see `plan/implementation-plan.md`).

**Tech stack:** Solidity 0.8.30 (matches cellar-private + landed settler stack), Foundry, OpenZeppelin (`SafeERC20`, `ReentrancyGuardTransient`), bulloak for BTT scaffolding. Real `CorkCellar` + `CorkCellarFactory` + rhinestone `Registry` + Cork Phoenix pool manager via cellar's `BaseTestCorkCellar` (reached through the landed `BaseTestSettler`).

**Source of truth:** RFC `003-underwriter-rollover-intent.md` §7.2 (`RolloverFiller`), §7.5 (11 integrator requirements), RFC `003-partial-fill-dual-settler.md` §8 (settler fill-flow differences per settler type), §9 (invariants fillers indirectly interact with). BTT `.tree` files authored up-front in `plan/btt-draft/` and copied into `test/filler/{exact,partial}/` by PR 2a / PR 3a. `plan/filler-test-spec.md`.

**BTT drafts (authored before PR 2a starts):**

- `plan/btt-draft/RolloverFiller_execute_Exact.tree` — 44 leaves against the `ExactFillSettler` surface (`finaliseAsSettled(bytes32 orderId)`, `PremiumFillerData{debitFrom}` for the premium leg, `RolloverFillerData{destination}` for the rollover leg).
- `plan/btt-draft/RolloverFiller_execute_Partial.tree` — 50 leaves against the `PartialFillSettler` surface (`finaliseAsSettled(bytes32 orderDigest, address[] fillers)`, `PartialFillerData{destination, debitFrom, targetFiller, intent, cellarSig}` for both legs).

Every branch in the draft trees corresponds to a concrete revert surface on the landed settlers — no speculative branches. Leaf counts drive the test-PR gate (PR 2a MUST have 44 red tests, PR 3a MUST have 50 red tests).

---

## Resolved design decisions

Recorded for future agents so downstream tasks don't rediscover them. Each decision was confirmed with the user before this plan was authored.

- **DP-A (filler shape):** One parameterised `RolloverFiller(settler, isPartial)` contract, deployed per user on the Partial path and once shared on the Exact path. Rationale: `PartialFillSettler` keys per-filler state on `msg.sender` at the settler (`_fillerRollovers[digest][msg.sender]`, `TargetFillerMismatch` at `PartialFillSettler.sol:287`, `AlreadyFilledByFiller` at line 292). A shared `RolloverFiller(partial)` would collapse every caller into one slot — the second EOA's call reverts with `AlreadyFilledByFiller`. Exact path is unaffected because `ExactFillSettler` keys by `orderId`, not per-filler. Two separate `RolloverFillerExact` / `RolloverFillerPartial` concretes are NOT used — one contract with a constructor flag serves both, but the Partial binding is meant for self-deployment (one `RolloverFiller(partial)` per caller identity). The deploy script produces one Exact filler + one Partial filler as a canonical reference; production Partial fillers deploy their own instance.
- **DP-B (`execute` signature):** `execute(bytes orderData, bytes signature, bytes originFillerData, uint256 srcCstAmount, address debitFrom, address destination)`. `orderData` is ABI-decoded inside the function (per RFC §7.2). `signature` + `originFillerData` are required because `openFor(order, sig, originFillerData)` consumes them. `solveParams` from the RFC §7.2 body text is **not** accepted: neither `IExactFillSettler.finaliseAsSettled(bytes32)` nor `IPartialFillSettler.finaliseAsSettled(bytes32, address[])` take solve params, so accepting the argument would be a dead parameter. RFC 003 §7.2's signature is already ambiguous (declared as 4 args, body references 3 more); if a future consumer surfaces, `solveParams` is a non-breaking addition. See also RFC gap R1 in the plan review — worth a follow-up RFC patch.
- **DP-D (EVC):** Out of scope for this stack. `EvcRolloverAdapter` is deferred to a later release; no interface, no submodule, no fixture.
- **DP-E (§7.4 Safe-direct-settler):** Docs only. No integration test, no Safe submodule. A follow-up `docs/integrations/safe-direct-settler.md` page covers the recipe.
- **Multi-tx execution profile (RFC §7.5 Execution Profiles "Multi-tx"):** Docs only. Reference `RolloverFiller` enforces the atomic profile; multi-tx advanced fillers are an integrator concern. No tests.
- **ERC-6909 preflight helper:** NOT in v1. Rationale: `execute` is atomic, so any preflight-detectable failure already reverts the whole tx — on-chain preflight would only trade revert selectors at a 3-SLOAD cost per successful fill. Off-chain preflight (viem/ethers simulation or a standalone library view) gives the same diagnostic power without taxing the happy path. Document in the integrator README.

---

## Coding conventions (hard rules)

Apply to every contract, test, and script in this plan. These override any looser interpretation that could be inferred from the surrounding code. (Verbatim from `plan/implementation-plan.md` — no drift.)

- **No `unchecked` blocks** unless an inline comment explicitly justifies the bound (e.g., a loop counter with a compile-time ceiling).
- **Custom errors only.** No string reverts, no `require(..., "msg")`. Every revert carries a typed error.
- **OpenZeppelin first.** Prefer `SafeERC20`, `ECDSA`, `SignatureChecker`, `Math`, `ReentrancyGuard` / `ReentrancyGuardTransient`, `Ownable2Step`, `TimelockController`. Do not reimplement anything OZ already ships.
- **No bespoke timelocks.** If any function needs timelock gating, use `TimelockController` and mark the function with a NatSpec `@dev` line identifying it as timelock-gated.
- **One interface per file.** Events and custom errors live on the interface, not the implementation. Implementations import the interface and re-use its error/event types.
- **Detailed NatSpec on every interface.** `@notice`, `@param`, `@return`, and `@dev` where state transitions or revert conditions are non-obvious. **The agent drafts NatSpec and confirms with the user before committing it.** Interface NatSpec does not land without explicit approval.
- **Immutables at contract scope.** Anything set once in the constructor is `immutable` and declared as a top-level state variable. Do not inline constants into function bodies — lift them to contract-scope `constant` / `immutable` fields.
- **No mocks for protocol integrations.** Deploy real contracts as test fixtures. Phoenix + cellar + settlers + ERC-6909 all flow through `BaseTestSettler`. No new mocks in this stack.
- **Compact, readable code layout.** Group by responsibility; separate groups with a single blank line used as a logical section break. Delete dead code; never leave commented-out blocks. No trailing whitespace.
- **Solidity 0.8.30**; pragma line matches cellar-private and the landed settler stack.

## Execution conventions (hard rules)

- **Sequential tasks, not parallel.** One task completes before the next starts. Parallel agents can dispatch **within a single task** (e.g., multiple files under one task) but never across tasks — agents step on shared state.
- **Post-task compliance re-check.** After every task's `forge build` + scoped `forge test` pass, re-read the task body, diff against the produced code and tests, and re-verify cited RFC / test-spec sections. Report any divergence before dispatching the next task. If the plan is wrong, stop and raise it — do not silently deviate.
- **State the goal before acting.** Every agent dispatch begins with a one-sentence statement of the task and its success criteria. No speculative changes outside the stated goal.
- **Test branch must fail visibly.** On test-only branches, `forge test --match-path "test/filler/<scope>/*"` MUST fail on the stub implementation before the branch is merged. A passing test suite against a stub is a bug (the tests aren't testing anything). The gate for a test-only branch is `forge build` PASS + `forge test` FAIL with every leaf red.
- **Impl branch flips gates green.** The impl branch rebases on the test branch, populates the stub, and the gate becomes `forge test` all GREEN.

---

## Stacked PR Strategy

**7 top-level stacked PRs.** Each PR is one `execute-cork` run. Test and implementation ship in separate stacked PRs: every implementation PR has a preceding test PR that establishes failing tests first, then the impl PR turns them green.

Base branch assumption: `main` **after** the settler + ERC-6909 stack (`plan/implementation-plan.md` PRs 1–4) has merged.

| PR | Name | Base | Description |
|---|---|---|---|
| **PR 1** | `feat/filler-interfaces-and-stubs` | `main` (post-settler) | `IRolloverFiller` interface, reverting stub `RolloverFiller.sol`, `BaseTestFiller` harness, harness smoke test. **Zero filler logic.** |
| **PR 2a** | `test/filler-exact-btt` | PR 1 | Co-located `.tree` + `.t.sol` for `RolloverFiller` bound to `ExactFillSettler`. Tests fail against the stub. **Tests only, no impl.** |
| **PR 2b** | `impl/filler-exact` | PR 2a | `RolloverFiller.execute` body wired for `ExactFillSettler`'s surface. Flips PR 2a's tests green. **Impl only, no new tests.** |
| **PR 3a** | `test/filler-partial-btt` | PR 2b | Co-located `.tree` + `.t.sol` for `RolloverFiller` bound to `PartialFillSettler`. Tests fail against the current impl (Exact-only). **Tests only.** |
| **PR 3b** | `impl/filler-partial` | PR 3a | Parameterise `RolloverFiller.execute` to route through either settler's finalise signature (Exact: `finaliseAsSettled(orderId)` vs Partial: `finaliseAsSettled(orderDigest, fillers[])`). Flips PR 3a's tests green while keeping PR 2b's green. **Impl only.** |
| **PR 4a** | `test/filler-invariants-and-integration` | PR 3b | INV-F invariant handlers + invariant test contract, plus end-to-end integration tests (`test/filler/integration/*`). Tests fail where handler actions exercise un-implemented edge cases; otherwise green. **Tests only.** |
| **PR 4b** | `impl/filler-integration-and-deploy` | PR 4a | Any impl fixes surfaced by the invariants + integration run. Deploy script. Final gate: all filler tests green. **Impl + script.** |

```
main (post-settler-merge)
 └── PR 1: feat/filler-interfaces-and-stubs
      └── PR 2a: test/filler-exact-btt               ← tests fail on stub
           └── PR 2b: impl/filler-exact              ← impl turns them green
                └── PR 3a: test/filler-partial-btt   ← tests fail for Partial
                     └── PR 3b: impl/filler-partial  ← parameterisation turns them green
                          └── PR 4a: test/filler-invariants-and-integration
                               └── PR 4b: impl/filler-integration-and-deploy
```

### Merge order
PR 1 → PR 2a → PR 2b → PR 3a → PR 3b → PR 4a → PR 4b. Strictly sequential; no parallel merges.

### Rebase discipline

Every child rebases on its parent after the parent merges:

```bash
git fetch origin
git checkout impl/filler-exact
git rebase origin/test/filler-exact-btt
# resolve conflicts (most likely in RolloverFiller.sol if the interface drifted)
git push --force-with-lease
```

Never `--no-verify` to skip hooks. If the rebase surfaces a real conflict (e.g. the test branch asserted a behaviour the impl can't support), stop and raise — do not silently edit the tests on the impl branch.

### Offline push deferral (fallback)

Identical protocol to `plan/implementation-plan.md`. On credential/push failure: append a row to `plan/pending-branches.md`, continue branching against the local tip, run all gates locally. Never `--force`, never rewrite pushed commits, never change remotes.

### PR description templates

**PR 1:**
```markdown
## Stack Position: 1/7 `feat/filler-interfaces-and-stubs`
**Base:** `main` (post-settler-merge)
**Diff from parent:** [compare](../../compare/main...feat/filler-interfaces-and-stubs)
**Tests:** `BaseTestFiller` harness smoke test only
**Implementation:** stub (revert on `execute`)
**Gate:** `forge build` passes; `forge test --match-path "test/filler/infra/*"` — smoke passes.
```

**PR 2a (test-only):**
```markdown
## Stack Position: 2a/7 `test/filler-exact-btt`
**Base:** `feat/filler-interfaces-and-stubs` (PR 1)
**Diff from parent:** [compare](../../compare/feat/filler-interfaces-and-stubs...test/filler-exact-btt)
**Tests:** `test/filler/exact/RolloverFiller_execute.tree` (44 leaves, copied from `plan/btt-draft/`) + `RolloverFiller_execute.t.sol`
**Implementation:** none
**Gate:** `forge build` PASS; `forge test --match-path "test/filler/exact/*"` — **44 FAIL red** (every leaf hits the stub's `NotImplemented()`). Failing is the correct signal.
```

**PR 2b (impl-only):**
```markdown
## Stack Position: 2b/7 `impl/filler-exact`
**Base:** `test/filler-exact-btt` (PR 2a)
**Diff from parent:** [compare](../../compare/test/filler-exact-btt...impl/filler-exact)
**Tests:** no new tests
**Implementation:** `contracts/fillers/RolloverFiller.sol` body wired for Exact settler
**Gate:** `forge test --match-path "test/filler/exact/*"` — **all pass**. Also `forge test --match-path "test/filler/infra/*"` — still green (no harness regression).
```

**PR 3a (test-only):**
```markdown
## Stack Position: 3a/7 `test/filler-partial-btt`
**Base:** `impl/filler-exact` (PR 2b)
**Diff from parent:** [compare](../../compare/impl/filler-exact...test/filler-partial-btt)
**Tests:** `test/filler/partial/RolloverFiller_execute.tree` (50 leaves, copied from `plan/btt-draft/`) + `RolloverFiller_execute.t.sol`
**Implementation:** none
**Gate:** `forge build` PASS; `forge test --match-path "test/filler/partial/*"` — **50 FAIL red** (Partial-settler finalise signature mismatch; fill-data shape differs; `targetFiller` check bites).
```

**PR 3b (impl-only):**
```markdown
## Stack Position: 3b/7 `impl/filler-partial`
**Base:** `test/filler-partial-btt` (PR 3a)
**Diff from parent:** [compare](../../compare/test/filler-partial-btt...impl/filler-partial)
**Tests:** no new tests
**Implementation:** parameterisation in `RolloverFiller.sol` + `LibFillerDispatch` helper if needed
**Gate:** `forge test --match-path "test/filler/partial/*"` — all pass; `forge test --match-path "test/filler/exact/*"` — still all pass (no regression).
```

**PR 4a (test-only):**
```markdown
## Stack Position: 4a/7 `test/filler-invariants-and-integration`
**Base:** `impl/filler-partial` (PR 3b)
**Diff from parent:** [compare](../../compare/impl/filler-partial...test/filler-invariants-and-integration)
**Tests:** `test/filler/invariant/*` (handler + INV-F1..F8) + `test/filler/integration/*` (5 scenarios)
**Implementation:** none
**Gate:** `forge test --match-path "test/filler/invariant/*"` and `"test/filler/integration/*"` — **most pass, up to 3 documented failures allowed** pending PR 4b fixes. Each failure MUST be listed in the PR body with (a) the exact test name, (b) the observed vs expected behaviour, (c) a one-line root-cause hypothesis, and (d) the PR 4b task that fixes it. More than 3 failures → stop-ship; fold the fixes into PR 4b Task 10 instead.
```

**PR 4b (impl-only):**
```markdown
## Stack Position: 4b/7 `impl/filler-integration-and-deploy`
**Base:** `test/filler-invariants-and-integration` (PR 4a)
**Diff from parent:** [compare](../../compare/test/filler-invariants-and-integration...impl/filler-integration-and-deploy)
**Tests:** no new tests
**Implementation:** any fix to `RolloverFiller.sol` surfaced by invariants/integration + `script/foundry-scripts/DeployFillers.s.sol`
**Gate:** `forge test --match-path "test/filler/*"` — ALL green; deploy script dry-runs against anvil.
```

### Stacked PR Workflow

```bash
# Top-level stack
gh pr create --base main --title "PR 1: feat/filler-interfaces-and-stubs"
gh pr create --base feat/filler-interfaces-and-stubs --title "PR 2a: test/filler-exact-btt"
gh pr create --base test/filler-exact-btt --title "PR 2b: impl/filler-exact"
gh pr create --base impl/filler-exact --title "PR 3a: test/filler-partial-btt"
gh pr create --base test/filler-partial-btt --title "PR 3b: impl/filler-partial"
gh pr create --base impl/filler-partial --title "PR 4a: test/filler-invariants-and-integration"
gh pr create --base test/filler-invariants-and-integration --title "PR 4b: impl/filler-integration-and-deploy"
```

### Branch names

```
feat/filler-interfaces-and-stubs            (PR 1,  base: main)
test/filler-exact-btt                       (PR 2a, base: PR 1)
impl/filler-exact                           (PR 2b, base: PR 2a)
test/filler-partial-btt                     (PR 3a, base: PR 2b)
impl/filler-partial                         (PR 3b, base: PR 3a)
test/filler-invariants-and-integration      (PR 4a, base: PR 3b)
impl/filler-integration-and-deploy          (PR 4b, base: PR 4a)
```

---

## Source files changed per PR

### Added (PR 1)
- `contracts/interfaces/IRolloverFiller.sol`
- `contracts/fillers/RolloverFiller.sol` (stub — reverts `NotImplemented()`)
- `test/filler/BaseTestFiller.sol` (harness, extends `BaseTestSettler`)
- `test/filler/infra/HarnessSmoke.t.sol`
- `docs/integrations/safe-direct-settler.md` (optional — may slip to a follow-up docs PR; note the decision in the PR body either way)

### Added (PR 2a — tests only)
- `test/filler/exact/RolloverFiller_execute.tree`
- `test/filler/exact/RolloverFiller_execute.t.sol`

### Modified (PR 2b — impl only)
- `contracts/fillers/RolloverFiller.sol` (replace stub with Exact-settler body)

### Added (PR 3a — tests only)
- `test/filler/partial/RolloverFiller_execute.tree`
- `test/filler/partial/RolloverFiller_execute.t.sol`

### Modified (PR 3b — impl only)
- `contracts/fillers/RolloverFiller.sol` (parameterise for Partial)
- (optional) `contracts/libs/LibFillerDispatch.sol` if the settler-type branching wants to live in a library rather than inline

### Added (PR 4a — tests only)
- `test/filler/invariant/FillerInvariantHandler.sol`
- `test/filler/invariant/FillerInvariant.t.sol`
- `test/filler/integration/RolloverFiller_ExactHappyPath.t.sol`
- `test/filler/integration/RolloverFiller_PartialTwoFillers.t.sol`
- `test/filler/integration/RolloverFiller_RefundPath.t.sol`
- `test/filler/integration/RolloverFiller_CancelNoFills.t.sol`
- `test/filler/integration/RolloverFiller_Erc1271UwSignature.t.sol` (minimal ERC-1271 UW scenario using the existing `MockERC1271Signer`; Safe-direct path is docs-only per DP-E)

### Added (PR 4b — impl + script)
- `script/foundry-scripts/DeployFillers.s.sol`
- any `RolloverFiller.sol` fixes from invariants/integration findings

---

## PR 1: `feat/filler-interfaces-and-stubs`

**Diff from parent:** `compare/main...feat/filler-interfaces-and-stubs` (where `main` is the post-settler-merge tip)

Creates the compilation surface for tests. **Zero filler logic** — only interface, reverting stub, and the test harness.

### Task 1: `IRolloverFiller` interface

- [ ] Add `contracts/interfaces/IRolloverFiller.sol`:
  - `function execute(bytes calldata orderData, bytes calldata signature, bytes calldata originFillerData, uint256 srcCstAmount, address debitFrom, address destination) external;` — signature per DP-B. `solveParams` is NOT accepted — no consumer on either `finaliseAsSettled` surface.
  - Custom errors:
    - `RolloverFiller__ZeroDestination()` — RFC 003 §7.2 line 2519.
    - No `RolloverFiller__ZeroSrcCstAmount` — the `srcCstAmount == 0` case is caught by the settler (Exact: `PartialFillNotAllowed` at `ExactFillSettler._onRolloverLegFill`; Partial: `ZeroRollover` from the cellar). Adding a filler-side guard would shadow the real revert surface and add no defense.
  - NatSpec drafts for each parameter + the atomic-execution guarantee (RFC 003 §7.5 item 1).
  - Draft NatSpec, confirm with user before committing (per coding conventions).

### Task 2: Reverting stub `RolloverFiller.sol`

- [ ] `contracts/fillers/RolloverFiller.sol`:
  - Constructor: `constructor(address settler_, bool isPartial_)` — two immutables `SETTLER` and `IS_PARTIAL`. Both are needed from PR 1 so the stub's ABI matches the final impl and downstream PRs don't churn the constructor.
  - `execute(...)` reverts with `NotImplemented()` (import the existing `NotImplemented` error from `contracts/settlers/BaseSettlerErrors.sol` for consistency — no new error type needed).
  - Import path hygiene: import `IRolloverFiller` from `contracts/interfaces/IRolloverFiller.sol`, implement it. `execute` signature MUST match the interface byte-for-byte so ABI tools line up.
- [ ] `forge build` passes.

### Task 3: `BaseTestFiller` harness

- [ ] Create `test/filler/BaseTestFiller.sol` inheriting `BaseTestSettler` (landed):
  - `super.setUp()` deploys factory, registry, cellars, modules, tokens, both settlers, `ERC6909Premium`.
  - Deploy `RolloverFiller rolloverFillerExact = new RolloverFiller(address(exactSettler), false);`.
  - Deploy `RolloverFiller rolloverFillerPartial = new RolloverFiller(address(partialSettler), true);` — this is the canonical reference deployment; Partial integration tests that need a second distinct caller identity deploy their own additional `RolloverFiller(partialSettler, true)` instance (see Task 9 integration-test guidance).
  - Convenience helpers:
    - `_approveFillerToPullSrcCst(actor, filler, amount)` — standard ERC-20 approval.
    - `_prepareFillerState(actor, filler, srcCstAmount, premiumToken, premiumAmount)` — one-shot: deposit premium via ERC-6909, `setOperator(settlerOfFiller, true)`, approve filler to pull srcCST.
    - `_settlerOf(filler)` — staticcall `RolloverFiller.SETTLER()`.
    - `_fillerSnapshot(filler)` — post-execute asserter for INV-F1 (zero token holdings) + INV-F2 (zero approvals). Touches every token referenced by any order seen in `setUp`.
- [ ] Add `test/filler/infra/HarnessSmoke.t.sol` — a single test that asserts all immutables are set, the two fillers bind to distinct settlers, and calling `execute` on either hits the stub revert.
- [ ] `forge test --match-path "test/filler/infra/*"` passes.

**Gate:** `forge build` PASS; `forge test --match-path "test/filler/infra/*"` PASS (smoke); stub reverts observable; `forge fmt --check` PASS.

---

## PR 2a: `test/filler-exact-btt`

**Diff from parent:** `compare/feat/filler-interfaces-and-stubs...test/filler-exact-btt`

Tree + tests for `RolloverFiller` bound to `ExactFillSettler`. **Tests only** — the stub remains. Tests MUST fail red against the stub.

### Task 4: BTT tree for Exact path

- [ ] Copy `plan/btt-draft/RolloverFiller_execute_Exact.tree` → `test/filler/exact/RolloverFiller_execute.tree`. Rename root node to match the target contract if bulloak requires exact casing.
- [ ] `bulloak scaffold test/filler/exact/RolloverFiller_execute.tree` → `RolloverFiller_execute.t.sol`.
- [ ] Hand-extend leaves where bulloak rejects the leaf text (repo precedent: PR 3 `ERC6909Premium` hand-fixed snake_case names — same pattern acceptable here).
- [ ] Implement all 44 leaf bodies against the stub — every leaf MUST fail with the stub's `NotImplemented()`. Use `_executeRollover(rolloverFillerExact, ...)` wrapper from `BaseTestFiller`.
- [ ] Any leaf-level edits (re-wording, splitting a branch, dropping a defensive leaf) MUST round-trip back into `plan/btt-draft/RolloverFiller_execute_Exact.tree` in the same commit so the draft stays authoritative.

**Gate:** `forge build` PASS; `forge test --match-path "test/filler/exact/*"` — 44 FAIL red; `forge fmt --check` PASS. If any leaf passes against the stub, the leaf is not testing anything — fix the leaf before merge.

---

## PR 2b: `impl/filler-exact`

**Diff from parent:** `compare/test/filler-exact-btt...impl/filler-exact`

Implementation only. Flips PR 2a's failing tests green.

### Task 5: Implement `RolloverFiller.execute` for Exact settler

**File:** `contracts/fillers/RolloverFiller.sol` — replace stub body.

- [ ] `execute(bytes calldata orderData, bytes calldata signature, bytes calldata originFillerData, uint256 srcCstAmount, address debitFrom, address destination) external nonReentrant`:
  1. `if (destination == address(0)) revert RolloverFiller__ZeroDestination();`
  2. Decode `GaslessCrossChainOrder memory order = abi.decode(orderData, (GaslessCrossChainOrder));`.
  3. Decode `OrderData memory od = LibRolloverOrder.decode(order.orderData);` — get `srcCstToken` + `premiumToken`.
  4. Compute `bytes32 orderId = LibSettlerHashing.computeOrderId(SETTLER, order);` — the library takes the settler explicitly (see `LibSettlerHashing.sol:53`).
  5. `SafeERC20.safeTransferFrom(IERC20(od.srcCstToken), msg.sender, address(this), srcCstAmount);`.
  6. `IExactFillSettler(SETTLER).openFor(order, signature, originFillerData);` — idempotent; safe if someone front-ran the open.
  7. `IERC20(od.srcCstToken).forceApprove(SETTLER, srcCstAmount);`.
  8. `bytes memory originDataForFill = abi.encode(order);` — A.9 wire format.
  9. `bytes memory rolloverFillerData = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: destination})));` — Exact rollover leg (A.10).
  10. `IDestinationSettler(SETTLER).fill(orderId, originDataForFill, rolloverFillerData);`.
  11. `IERC20(od.srcCstToken).forceApprove(SETTLER, 0);` — release allowance unconditionally before premium leg.
  12. `bytes memory premiumFillerData = abi.encodePacked(uint8(1), abi.encode(PremiumFillerData({debitFrom: debitFrom})));` — Exact premium leg (A.10). Triggers `_settle` on the settler.
  13. `IDestinationSettler(SETTLER).fill(orderId, originDataForFill, premiumFillerData);`.
  14. `IExactFillSettler(SETTLER).finaliseAsSettled(orderId);` — Exact-only signature.
  15. Leftover return:
      ```solidity
      uint256 leftover = IERC20(od.srcCstToken).balanceOf(address(this));
      if (leftover > 0) SafeERC20.safeTransfer(IERC20(od.srcCstToken), msg.sender, leftover);
      ```
- [ ] No `solveParams` parameter — neither settler's `finaliseAsSettled` accepts one (`ExactFillSettler.finaliseAsSettled(bytes32)`, `PartialFillSettler.finaliseAsSettled(bytes32, address[])`). RFC 003 §A.12's `SolveParams` struct is consumed only by `finaliseAsRefunded` / `finaliseAsCancelled`, which are out of `execute`'s scope.
- [ ] NatSpec: drafted on the interface in PR 1; confirm with user before committing per coding conventions.
- [ ] Persistent-state invariant: the contract MUST end every `execute` call holding zero tokens and zero non-zero approvals. Enforced by `_fillerSnapshot` helper in the happy-path leaf.
- [ ] `forge test --match-path "test/filler/exact/*"` — all pass.
- [ ] `forge test --match-path "test/filler/infra/*"` — still pass (no regression).

**Gate:** All Exact filler tests green + infra smoke green; `forge fmt --check` PASS.

---

## PR 3a: `test/filler-partial-btt`

**Diff from parent:** `compare/impl/filler-exact...test/filler-partial-btt`

Tree + tests for `RolloverFiller` bound to `PartialFillSettler`. The Exact impl is wrong for Partial (different fillerData shape, different finalise signature), so these tests fail red against the current impl.

### Task 6: BTT tree for Partial path

- [ ] Copy `plan/btt-draft/RolloverFiller_execute_Partial.tree` → `test/filler/partial/RolloverFiller_execute.tree`.
- [ ] `bulloak scaffold` → `RolloverFiller_execute.t.sol`. Hand-extend leaf names where bulloak rejects text.
- [ ] Implement all 50 leaf bodies against the Exact-only impl inherited from PR 2b — every leaf MUST fail (Partial fillerData shape, `finaliseAsSettled(orderDigest, fillers[])` signature, `targetFiller` check, per-filler slot semantics all diverge from Exact).
- [ ] If any leaf passes against the Exact-only impl, the leaf is not asserting Partial-specific behaviour — fix before merge.
- [ ] Any leaf-level edits round-trip back into `plan/btt-draft/RolloverFiller_execute_Partial.tree` in the same commit.

**Gate:** `forge build` PASS; `forge test --match-path "test/filler/partial/*"` — 50 FAIL red; `forge fmt --check` PASS.

---

## PR 3b: `impl/filler-partial`

**Diff from parent:** `compare/test/filler-partial-btt...impl/filler-partial`

Parameterise `RolloverFiller.execute` so one contract serves both settler types (DP-A resolved to parameterised). Flips PR 3a green, keeps PR 2b green.

### Task 7: Parameterise `RolloverFiller.execute`

**File:** `contracts/fillers/RolloverFiller.sol` — extend Exact impl with settler-type routing.

**Discriminant: constructor-passed `bool isPartial`.** `PartialFillSettler` does not implement ERC-165 (`supportsInterface` is only implemented on `ERC6909Premium`). Calling `IERC165(settler).supportsInterface(...)` on the partial settler reverts (no matching selector, no fallback). Don't go there. The caller declares the binding at deploy time and the contract trusts it — a mismatched flag produces an immediately-failing filler and is caught by the first integration test that runs against it.

Rejected alternatives:
- ERC-165 introspection — reverts at deploy (documented above).
- Call-time `staticcall` introspection — same revert, plus a SLOAD-class cost on every fill.
- Two separate concretes — rejected per DP-A.

- [ ] Extend the constructor to accept the flag:
  ```solidity
  bool public immutable IS_PARTIAL;

  constructor(address settler_, bool isPartial_) {
      SETTLER = settler_;
      IS_PARTIAL = isPartial_;
  }
  ```
  The PR 1 stub constructor must match this signature so downstream PRs don't churn the interface. Update PR 1 Task 2 to take `(address, bool)` when this PR lands — PR 1's body says "one immutable `SETTLER`"; extend it to two immutables up front so the stub constructor already matches.
- [ ] Diverge at three points inside `execute`:
  - **fillerData construction (rollover leg):** if `IS_PARTIAL`, build `PartialFillerData{destination, debitFrom, targetFiller: address(this), intent, cellarSig}`. Reuse the existing `LibRolloverOrder.extractCellarIntentFromOrderData(od, order, SETTLER, ICorkCellarFactory(...).factory)` helper (see `LibRolloverOrder.sol:160`) — it already returns both `intent` and `cellarSig`, and both the Exact and Partial paths want the same reconstruction. Do NOT introduce a new helper. The helper is `view` (reads `block.chainid` via `computeOrderDigest`); that is fine inside `execute`. The `factory` argument is retrievable via `BaseSettler(SETTLER).factory()` — cache in an immutable on first deployment if the repeated staticcall cost is undesirable, but a single staticcall per execute is acceptable.
  - **fillerData construction (premium leg):** if `IS_PARTIAL`, same `PartialFillerData` shape with the same `targetFiller`, reusing the same `(intent, cellarSig)` pair from the rollover leg. Exact path still uses `PremiumFillerData{debitFrom}`.
  - **`finaliseAsSettled` invocation:** if `IS_PARTIAL`, call `IPartialFillSettler(SETTLER).finaliseAsSettled(orderDigest, fillers)` with `fillers = [address(this)]`; Exact path uses `IExactFillSettler(SETTLER).finaliseAsSettled(orderId)`. `orderDigest` computed via `LibSettlerHashing.computeOrderDigest(SETTLER, order, od)` — settler address is the mandatory first arg (see `LibSettlerHashing.sol:117`).
- [ ] Optional refactor: lift the branching into an internal `_finaliseSettled(order, od, orderId, orderDigest)` so the main `execute` body stays linear. Whether this warrants a standalone `LibFillerDispatch.sol` library is a judgment call for the impl agent — if the branching is three lines, keep inline; if the fillerData packing grows, extract.
- [ ] `forge test --match-path "test/filler/partial/*"` — all pass.
- [ ] `forge test --match-path "test/filler/exact/*"` — still all pass (regression check).
- [ ] `forge test --match-path "test/filler/infra/*"` — still all pass.

**Gate:** All Exact + Partial + infra tests green; `forge fmt --check` PASS.

---

## PR 4a: `test/filler-invariants-and-integration`

**Diff from parent:** `compare/impl/filler-partial...test/filler-invariants-and-integration`

Invariant handler + invariant tests + integration scenarios. Tests only. Most should pass (the impl is complete for happy paths); a subset may fail where invariants expose edge-case impl gaps — those failures are resolved in PR 4b.

### Task 8: Invariant handler + test contract

- [ ] `test/filler/invariant/FillerInvariantHandler.sol`:
  - Actions: `actionExecuteExactHappy`, `actionExecutePartialHappy`, `actionExecuteZeroDestination`, `actionExecuteOverfund` (srcCstAmount > orderSize), `actionExecuteInsufficient6909`, `actionExecuteRevertingDestination` (dest is a reverting contract).
  - Ghost state: `ghost_callerSrcCstBefore`, `ghost_callerSrcCstAfter`, `ghost_actualRolled` (recovered from FillRecord/FillerRollover), `ghost_fillerBalanceSeen[token]`, `ghost_fillerAllowanceSeen[token][spender]`.
- [ ] `test/filler/invariant/FillerInvariant.t.sol`:
  - `invariant_F1_fillerHoldsNoTokens()` — for every (token, filler) pair seen, `balanceOf == 0`.
  - `invariant_F2_noDanglingApprovals()` — `allowance == 0`.
  - `invariant_F3_leftoverReturnedToCaller()` — ghost delta matches on-chain delta.
  - `invariant_F4_fillerHoldsNo6909()`.
  - `invariant_F5_fillerNotOperator()`.
  - `invariant_F7_atomicRevertParity()` — revert-action runs don't mutate any observable pre-state on filler, settler, ERC-6909.
  - `invariant_F8_noEventsFromFiller()` — `vm.recordLogs()` → zero events emit from `address(filler)`.
  - Skip INV-F6 (EVC) — out of scope.
- [ ] Handler calls route through BOTH `rolloverFillerExact` and `rolloverFillerPartial` in weighted fashion.

### Task 9: Integration tests

- [ ] `test/filler/integration/RolloverFiller_ExactHappyPath.t.sol` — UW signs, caller calls `rolloverFillerExact.execute`, UW cellar holds dstCPT + premium, destination holds dstCST.
- [ ] `test/filler/integration/RolloverFiller_PartialTwoFillers.t.sol` — two **distinct `RolloverFiller` instances**, each deployed with `new RolloverFiller(address(partialSettler), true)` (per DP-A: the Partial settler keys per-filler state on `msg.sender`, which is the filler contract address). Each filler's caller calls `execute`; cumulative fills reach `orderSize`; `finaliseAsSettled(digest, [address(fillerA), address(fillerB)])` drains escrow. The test's primary purpose is demonstrating the per-user Partial deployment pattern — a shared Partial deployment would revert on the second call with `AlreadyFilledByFiller`.
- [ ] `test/filler/integration/RolloverFiller_RefundPath.t.sol` — rollover fills, premium leg fails (e.g. ERC-6909 balance zero at call-time), full `execute` reverts, no state change. Separately: a partial no-filler path where the settler times out and `finaliseAsRefunded` is called by a keeper (not through `RolloverFiller`).
- [ ] `test/filler/integration/RolloverFiller_CancelNoFills.t.sol` — UW cancels an Opened order pre-fill. `RolloverFiller.execute` attempted post-cancel reverts with the settler's `InvalidOrderStatus`. Also include a cross-binding isolation case: calling `rolloverFillerExact.execute` with `orderData` signed for a Partial order (and vice versa) reverts with the appropriate settler-side revert (Exact rejects `allowPartialFills == true` at `_validateOpen`; Partial rejects `allowPartialFills == false` at `InconsistentIntent`) — proves the filler does not paper over binding mismatches.
- [ ] `test/filler/integration/RolloverFiller_Erc1271UwSignature.t.sol` — UW is a contract wallet that returns ERC-1271 `isValidSignature`. Use existing `test/mocks/MockERC1271Signer.sol`. Proves `openFor` signature-recovery path works through the filler.
- [ ] Run: most pass, some may fail (e.g. if an invariant exposes a missing `forceApprove(0)` edge case). Any failure that does fail MUST be documented in the PR body with a link to the PR 4b task that resolves it.

**Gate:** `forge build` PASS; integration + invariant suites run; failures documented; `forge fmt --check` PASS.

---

## PR 4b: `impl/filler-integration-and-deploy`

**Diff from parent:** `compare/test/filler-invariants-and-integration...impl/filler-integration-and-deploy`

Any impl fixes surfaced by PR 4a + deploy script.

### Task 10: Impl fixes from PR 4a findings

- [ ] Read every failing test in PR 4a's PR body; triage each. Fix in `contracts/fillers/RolloverFiller.sol`.
- [ ] `forge test --match-path "test/filler/*"` — ALL pass.

### Task 11: Deploy script

- [ ] `script/foundry-scripts/DeployFillers.s.sol`:
  ```solidity
  function run() external returns (address exactFiller, address partialFiller) {
      address exactSettler = _resolveSettlerAddress("ExactFillSettler");
      address partialSettler = _resolveSettlerAddress("PartialFillSettler");
      vm.startBroadcast();
      exactFiller = address(new RolloverFiller(exactSettler, false));
      partialFiller = address(new RolloverFiller(partialSettler, true));
      vm.stopBroadcast();
  }
  ```
  Resolution order: env override (`EXACT_SETTLER_OVERRIDE`, `PARTIAL_SETTLER_OVERRIDE`) → rollover-phoenix `networks.json` if the landed `DeploySettlers.s.sol` writes one → fail with a clear revert if neither resolves. The Partial filler this script produces is a **canonical reference deployment**, not a shared instance for all users — per DP-A, production Partial fillers deploy their own `RolloverFiller(partialSettler, true)` to get a unique `msg.sender` at the settler.
- [ ] `test/script/DeployFillers.t.sol` — assert the script deploys two fillers, each bound to the correct settler (check `RolloverFiller.SETTLER()` returns the expected address) and `IS_PARTIAL` flag matches.
- [ ] `forge script DeployFillers --fork-url <anvil>` — dry-runs green.

**Gate:** `forge test --match-path "test/filler/*"` — ALL pass; `forge script DeployFillers` dry-runs green; `forge fmt --check` PASS.

---

## execute-cork Execution Schedule

| Run | PR | Tasks | Agents | Gate |
|---|---|---|---|---|
| 1 | PR 1 | 1–3 | 2 | `forge build` PASS; infra smoke PASS |
| 2 | PR 2a | 4 | 1 | `forge build` PASS; `forge test --match-path "test/filler/exact/*"` — 44 FAIL red |
| 3 | PR 2b | 5 | 1 | 44 exact PASS; infra still PASS |
| 4 | PR 3a | 6 | 1 | `forge build` PASS; `forge test --match-path "test/filler/partial/*"` — 50 FAIL red |
| 5 | PR 3b | 7 | 1 | 50 partial PASS; 44 exact + infra still PASS (regression check) |
| 6 | PR 4a | 8–9 | 2 | Invariant + integration runs; failures documented |
| 7 | PR 4b | 10–11 | 2 | ALL filler tests PASS; deploy script dry-run PASS |

**Total: 7 runs, 10 agents.**

Strictly sequential. Each test-only branch is gated by "fails visibly against stub/prior impl"; each impl branch is gated by "turns parent branch's failing tests green with no regressions elsewhere."

---

## Risks + unknowns

- **`IS_PARTIAL` discrimination mechanism (resolved).** Confirmed: `PartialFillSettler` does not implement ERC-165 (see `grep supportsInterface contracts/`; only `ERC6909Premium` implements it). Calling `IERC165(partialSettler).supportsInterface(...)` reverts at deploy (no matching selector, no fallback). The constructor takes a caller-supplied `bool isPartial_` as the only discrimination path. Pre-emptive verification for PR 3b Task 7 — do not re-attempt ERC-165.
- **`forceApprove(0)` ordering under settler revert.** The plan wires the approval reset unconditionally before the premium leg, but if the rollover-leg fill reverts, the approval has been set and the reset hasn't fired. `ReentrancyGuardTransient` + atomic revert means state rolls back, so the approval is gone too. Verified in PR 2a's "rollover-leg reverts" leaf (INV-F2 post-revert = 0).
- **`CellarIntent` reconstruction helper (resolved).** Both Exact and Partial fillers use the landed `LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory)` (see `LibRolloverOrder.sol:160`). No new helper. The helper is `view` (reads `block.chainid`); factory is reachable via `BaseSettler(SETTLER).factory()` or cached as an immutable on the filler.
- **`solveParams` consumer divergence (resolved).** Confirmed: neither `finaliseAsSettled` surface accepts solve params. `solveParams` is dropped from the `execute` signature — see DP-B. RFC 003 §A.12 `SolveParams` is consumed by `finaliseAsRefunded` / `finaliseAsCancelled` only. Patch the RFC in a follow-up; this plan does not block on it.
- **Partial identity collision (resolved).** `PartialFillSettler` keys per-filler state on `msg.sender` at the settler. A shared Partial filler collapses every EOA into one slot. DP-A addresses this: Partial fillers deploy-per-user. Integration test #2 (`RolloverFiller_PartialTwoFillers.t.sol`) deploys two separate `RolloverFiller(partialSettler, true)` instances. The canonical deploy script ships one Partial filler as a reference only.
- **`LibRolloverOrder.encode*FillerData` helpers are settler-incompatible (landed-code drift).** `encodeRolloverFillerData` / `encodePremiumFillerData` / `encodePartialFillerData` use `abi.encode(uint8, struct)` which left-pads uint8 to 32 bytes, but `BaseSettler.fill` reads `fillerData[0:1]` (one byte). Their first byte is always `0x00`, so every encoded premium payload routes to the rollover leg at the settler. Production callers must use `bytes.concat(bytes1(uint8(x)), abi.encode(...))` (pattern already used in `test/BaseTestSettler.sol:219-226` and `test/integration/RolloverLifecycle.t.sol:595-599`). The filler impl (Task 5 step 9, 12) uses `abi.encodePacked(uint8(...), abi.encode(...))` which is correct. **Do NOT call the library encoders from the filler.** File a separate issue to fix the library helpers in a follow-up PR; not scoped here. `BaseTestSettler._buildPartialFillerData` at line 236-254 has the same bug and must be either avoided by filler tests or shadowed in `BaseTestFiller`.
- **Public-mempool griefing on `openFor`.** Plan flags idempotent no-op as a leaf. Between `openFor` and the caller's `fill`, a griefer can race the rollover leg; Exact path bubbles `AlreadyFilled`, Partial path bubbles `AlreadyFilledByFiller` for the shared-filler case or proceeds cleanly for per-user deploys. Document in the integrator README as a MEV consideration.
- **Fee-on-transfer / rebasing / ERC-777 srcCST or premium tokens.** RFC 003 §6.6 declares these unsupported and offloads enforcement to the Cork API. The filler inherits this — if an unsupported token is wired into an order, behaviour is undefined. Copy the blocklist language into the integrator README.
- **Transient reentrancy guard semantics.** `ReentrancyGuardTransient` clears at tx end. If `execute` reverts mid-way, the guard releases and a subsequent tx can retry cleanly — no persistent lock-out. Called out for clarity; not a risk.
- **ERC-6909 preflight helper.** Deferred per user decision. If integrators later request on-chain preflight, the follow-up is a standalone `FillerPreflight.sol` view library called via `eth_call` — does not require modifying `RolloverFiller`.
- **Multi-tx advanced profile.** Out of scope. Reference `RolloverFiller` enforces the atomic profile only. Document in the integrator README that advanced fillers operating under the multi-tx profile are the integrator's own responsibility.
- **Safe-direct-settler (§7.4).** Docs-only per DP-E. `docs/integrations/safe-direct-settler.md` may ship as part of PR 1 or slip to a follow-up docs PR — agent decides based on how much context the doc needs beyond the RFC text. Record the decision in the PR 1 body.
