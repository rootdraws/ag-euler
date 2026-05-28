# EVC Rollover Adapter Implementation Plan

> **Execution method:** `execute-cork` skill — one Opus agent run per PR, sequential across PRs. Each PR is one `execute-cork` run; within a run, multiple agents may dispatch in parallel for file-level work on one task, but never across tasks.
>
> **Discipline:** Tests and implementation ship in **separate stacked PRs**. Tree + failing tests land first on a `test/...` branch; implementation lands second on an `impl/...` branch that bases on the test branch. This splits the work along the axis `execute-cork` uses internally — it dispatches `write-solidity-tests-cork` for test-only tasks and `write-solidity-cork` for implementation tasks.
>
> **Test details:** See `plan/evc-adapter-test-spec.md` for the full BTT tree inventory, leaf counts, invariant matrix, mock policy, and infrastructure design. This plan covers only execution steps, source-side changes, and dependency ordering.

**Goal:** Deliver the `EvcRolloverAdapter` reference implementation specified in RFC 003 §7.3. Parameterised per settler type (DP-A parity with the landed `RolloverFiller`): one contract, two deployments — one bound to `ExactFillSettler`, one bound to `PartialFillSettler`. The adapter is EVC-aware (callable only inside `evc.batch()` / `evc.call()`) and targets the Euler vault curator user journey (RFC §8).

**Architecture:** `EvcRolloverAdapter` is a thin, reentrancy-guarded wrapper around an immutable `(SETTLER, IS_PARTIAL, FACTORY, EVC)` quadruple. It exposes a single `execute(bytes orderData, bytes signature, bytes originFillerData, uint256 srcCstAmount, address debitFrom, address destination)` that (a) guards `destination != address(0)` **first**, (b) resolves the real caller via `EVC.getCurrentOnBehalfOfAccount(msg.sender)`, (c) asserts the adapter already holds ≥ `srcCstAmount` srcCST (seeded by a prior batch item), (d) calls `openFor`, (e) calls `fill` twice (rollover leg then premium leg), and (f) calls the concrete's `finaliseAsSettled`. It holds no persistent state and never custodies premium — premium flows through `ERC6909Premium` via the settler's `_settle()` primitive. The adapter **does not** pull tokens from the caller and **does not** return leftovers — per RFC §7.3, vault IO and sweep steps live in sibling `evc.batch()` items composed by the curator.

**RFC §7.3 vs §8 alignment.** The RFC has two representations of the curator flow. §7.3 is the **code** — the adapter is pure settler orchestration with no vault IO. §8's "Filler: Euler Vault Curator" **narrative** reads as if the adapter itself performs vault withdrawals and deposits. This plan follows §7.3 verbatim and intentionally does **not** implement §8's narrative behaviour — curators compose `[EVault.withdraw, adapter.execute, EVault.deposit]` as sibling batch items. Rationale: matches the canonical Euler integration pattern (operators are narrow orchestrators; vault IO lives in sibling batch items); keeps the adapter vault-agnostic (EVault, ERC-4626, or any vault primitive). If §8's narrative is the true intent, that requires a separate RFC amendment — not a v1 scope change.

**Tech stack:** Solidity 0.8.30, Foundry, OpenZeppelin (`SafeERC20`, `ReentrancyGuardTransient`), bulloak for BTT scaffolding. Real `EthereumVaultConnector` (new submodule) + real `CorkCellar` + `CorkCellarFactory` + rhinestone `Registry` + Cork Phoenix pool manager via cellar's `BaseTestCorkCellar` (reached through the landed `BaseTestFiller`).

**Source of truth:** RFC `003-underwriter-rollover-intent.md` §7.3 (`EvcExactFillAdapter` code), §7.5 (12 integrator requirements — mapping in `plan/evc-adapter-test-spec.md` §5), §8 "Filler: Euler Vault Curator" journey. BTT `.tree` files authored up-front in `plan/btt-draft/` and copied into `test/filler/evc/{exact,partial}/` by PR 2a. `plan/evc-adapter-test-spec.md`.

**BTT drafts (authored before PR 2a starts):**

- `plan/btt-draft/EvcRolloverAdapter_execute_Exact.tree` — 48 leaves against the `ExactFillSettler` surface.
- `plan/btt-draft/EvcRolloverAdapter_execute_Partial.tree` — 58 leaves against the `PartialFillSettler` surface.

Every branch corresponds to a concrete revert surface on the landed settlers or to a new EVC-specific guard. Leaf counts drive the test-PR gate (PR 2a MUST have 48 + 58 = 106 red tests).

---

## Resolved design decisions

Recorded for future agents so downstream tasks don't rediscover them. Each decision was confirmed with the user before this plan was authored.

- **DP-EVC-A (adapter shape):** Parameterised `EvcRolloverAdapter(settler, isPartial, expectedFactory, evc)` — one contract, two deployments (Exact + Partial). Mirrors the landed `RolloverFiller` DP-A. The Partial binding is meant for per-subaccount self-deployment — one `EvcRolloverAdapter(partial, ...)` per caller identity — because `PartialFillSettler` keys per-filler state on `msg.sender`. A shared Partial adapter would collapse every EOA into one slot. The deploy script produces one Exact adapter + one Partial adapter as a canonical reference; production Partial adapters are deployed by curators per subaccount.
- **DP-EVC-B (EVC dependency):** `forge install euler-xyz/ethereum-vault-connector` at PR 1 time. Pin the commit in `.gitmodules`. Add `evc/=lib/ethereum-vault-connector/src/` to `remappings.txt`. Real `EthereumVaultConnector` deployed in `BaseTestEvcFillerAdapter.setUp()` — no mocks. GPL-2.0 licence — add to `ACKNOWLEDGEMENTS` if the repo convention requires it.
- **DP-EVC-C (adapter scope — no vault IO):** Adapter is pure settler orchestration. srcCST is seeded into the adapter by a prior batch item (typically an EVault withdraw on the curator's subaccount). dstCST flows out to `destination` (typically a staging address consumed by the next batch item, e.g. an EVault deposit). The adapter asserts `balanceOf(this) >= srcCstAmount` at entry and reverts `EvcRolloverAdapter__InsufficientTokens` if short. No EVault interface, no vault calls inside the adapter. Matches RFC §7.3 verbatim and matches Euler's canonical integration pattern (each `BatchItem` is independent).
- **DP-EVC-D (`debitFrom` semantics):** Pass-through as supplied. The caller (typically a curator bot) decides which authorised ERC-6909 account funds premium. The settler enforces authorisation. The EVC-specific safety is that the `msg.sender` to the settler is the adapter itself (the adapter calls the settler directly, not through `evc.call`) and `getCurrentOnBehalfOfAccount` resolves the caller subaccount for the adapter's use.
- **DP-EVC-E (constructor guards):** Same shape as `RolloverFiller.sol` — Exact-probe on a Partial-only selector, plus factory cross-check on Partial bindings. Errors are adapter-specific (`EvcRolloverAdapter__SettlerMismatch`, `__FactoryMismatch`, `__ZeroEvc`, `__InvalidCaller`, `__ZeroDestination`, `__InsufficientTokens`), not shared with `RolloverFiller`. Small duplication; errors belong to the contract that throws them. Per-interface errors match the repo's "one interface per file" convention.
- **DP-EVC-F (test harness):** `BaseTestEvcFillerAdapter extends BaseTestFiller`. Deploys real EVC, both EVC adapters, and helpers for wrapping adapter calls inside `evc.batch([...])` with subaccount `onBehalfOfAccount`. Reuses premium setup and signing helpers from the landed filler base.
- **DP-EVC-G (PR stack size):** Five PRs (vs the seven used for `RolloverFiller`). Exact + Partial collapse into one test PR + one impl PR because the parameterisation pattern is already proven. Test-first discipline preserved: PR 2a must fail red with 106 leaves against the stub.
- **Out of scope:** EVault-specific integration (curators compose siblings themselves), AvantGarde Safe EVC pattern, multi-tx execution profile, ERC-1271 UW signature test (covered by the landed `RolloverFiller` suite — `openFor` path is shared).

---

## Coding conventions (hard rules)

Apply to every contract, test, and script in this plan. These override any looser interpretation that could be inferred from the surrounding code. (Verbatim from `plan/filler-implementation-plan.md` — no drift.)

- **No `unchecked` blocks** unless an inline comment explicitly justifies the bound.
- **Custom errors only.** No string reverts, no `require(..., "msg")`.
- **OpenZeppelin first.** Prefer `SafeERC20`, `ECDSA`, `SignatureChecker`, `Math`, `ReentrancyGuard` / `ReentrancyGuardTransient`. Do not reimplement anything OZ already ships.
- **No bespoke timelocks.** If any function needs timelock gating, use `TimelockController` and mark the function with a NatSpec `@dev` line identifying it as timelock-gated.
- **One interface per file.** Events and custom errors live on the interface, not the implementation.
- **Detailed NatSpec on every interface.** Agent drafts NatSpec and confirms with the user before committing it. Interface NatSpec does not land without explicit approval.
- **Immutables at contract scope.** Anything set once in the constructor is `immutable` and declared at top-level.
- **No mocks for protocol integrations.** Deploy real contracts as test fixtures — real EVC, real Phoenix, real cellar, real settlers, real ERC-6909.
- **Compact, readable code layout.** Group by responsibility; separate groups with a single blank line. Delete dead code; no commented-out blocks. No trailing whitespace.
- **Solidity 0.8.30**; pragma line matches the landed settler + filler stacks.

## Execution conventions (hard rules)

- **Sequential tasks, not parallel.** One task completes before the next starts. Parallel agents may dispatch **within a single task** (e.g. multiple files under one task) but never across tasks.
- **Post-task compliance re-check.** After every task's `forge build` + scoped `forge test` pass, re-read the task body, diff against the produced code and tests, and re-verify cited RFC / test-spec sections. Report any divergence before dispatching the next task.
- **State the goal before acting.** Every agent dispatch begins with a one-sentence statement of the task and its success criteria.
- **Test branch must fail visibly.** On test-only branches, `forge test --match-path "test/filler/evc/<scope>/*"` MUST fail on the stub before the branch is merged. A passing test suite against a stub is a bug.
- **Impl branch flips gates green.** The impl branch rebases on the test branch, populates the stub, and the gate becomes `forge test` all GREEN with no regression of the landed `RolloverFiller` suite.
- **`forge fmt` + `mise fmt-check`** included in every gate per standing user preference.

---

## Stacked PR Strategy

**5 top-level stacked PRs.** Each PR is one `execute-cork` run. Test and implementation ship in separate stacked PRs: every implementation PR has a preceding test PR that establishes failing tests first, then the impl PR turns them green.

Base branch assumption: `main` **after** the `RolloverFiller` PR 4b has merged (`plan/filler-implementation-plan.md` complete).

| PR | Name | Base | Description |
|---|---|---|---|
| **PR 1** | `feat/evc-adapter-interfaces-and-stubs` | `main` (post-filler) | EVC submodule + `evc/=` remap, `IEvcRolloverAdapter` interface, reverting stub `EvcRolloverAdapter.sol`, `BaseTestEvcFillerAdapter` harness, harness smoke test. **Zero adapter logic.** |
| **PR 2a** | `test/evc-adapter-btt` | PR 1 | Co-located `.tree` + `.t.sol` for `EvcRolloverAdapter` bound to both Exact and Partial settlers. Tests fail against the stub. **Tests only, no impl.** |
| **PR 2b** | `impl/evc-adapter` | PR 2a | `EvcRolloverAdapter.execute` body parameterised for both settler surfaces. Flips PR 2a's tests green without regressing the landed `RolloverFiller` suite. **Impl only, no new tests.** |
| **PR 3a** | `test/evc-adapter-invariants-and-integration` | PR 2b | INV-F invariant handlers + invariant test contract, plus end-to-end integration tests (`test/filler/evc/integration/*`). Tests may fail where handler actions expose edge-case impl gaps; failures are documented and resolved in PR 3b. **Tests only.** |
| **PR 3b** | `impl/evc-adapter-integration-and-deploy` | PR 3a | Any impl fixes surfaced by the invariants + integration run. Deploy script. Final gate: all EVC adapter tests green. **Impl + script.** |

```
main (post-RolloverFiller-merge)
 └── PR 1: feat/evc-adapter-interfaces-and-stubs
      └── PR 2a: test/evc-adapter-btt                  ← tests fail on stub (106 red)
           └── PR 2b: impl/evc-adapter                  ← impl turns them green
                └── PR 3a: test/evc-adapter-invariants-and-integration
                     └── PR 3b: impl/evc-adapter-integration-and-deploy
```

### Merge order
PR 1 → PR 2a → PR 2b → PR 3a → PR 3b. Strictly sequential; no parallel merges.

### Rebase discipline

Every child rebases on its parent after the parent merges:

```bash
git fetch origin
git checkout impl/evc-adapter
git rebase origin/test/evc-adapter-btt
# resolve conflicts (most likely in EvcRolloverAdapter.sol if the interface drifted)
git push --force-with-lease
```

Never `--no-verify` to skip hooks. If the rebase surfaces a real conflict, stop and raise — do not silently edit the tests on the impl branch.

### Offline push deferral (fallback)

Identical protocol to the filler stack. On credential/push failure: append a row to `plan/pending-branches.md`, continue branching against the local tip, run all gates locally.

### PR description templates

**PR 1:**
```markdown
## Stack Position: 1/5 `feat/evc-adapter-interfaces-and-stubs`
**Base:** `main` (post-RolloverFiller-merge)
**Diff from parent:** [compare](../../compare/main...feat/evc-adapter-interfaces-and-stubs)
**Tests:** `BaseTestEvcFillerAdapter` harness smoke test only
**Implementation:** stub (revert on `execute`) + EVC submodule + remap
**Gate:** `forge build` PASS; `forge test --match-path "test/filler/evc/infra/*"` — smoke passes; `forge fmt --check` PASS; `mise fmt-check` PASS.
```

**PR 2a (test-only):**
```markdown
## Stack Position: 2a/5 `test/evc-adapter-btt`
**Base:** `feat/evc-adapter-interfaces-and-stubs` (PR 1)
**Diff from parent:** [compare](../../compare/feat/evc-adapter-interfaces-and-stubs...test/evc-adapter-btt)
**Tests:**
 - `test/filler/evc/exact/EvcRolloverAdapter_execute.tree` (48 leaves, copied from `plan/btt-draft/`) + `.t.sol`
 - `test/filler/evc/partial/EvcRolloverAdapter_execute.tree` (58 leaves, copied from `plan/btt-draft/`) + `.t.sol`
**Implementation:** none
**Gate:** `forge build` PASS; `forge test --match-path "test/filler/evc/exact/*"` — **45 FAIL red + 3 direct-settler PASS**; `forge test --match-path "test/filler/evc/partial/*"` — **54 FAIL red + 4 direct-settler PASS**; `forge fmt --check` PASS; `mise fmt-check` PASS. See §PR 2a "Direct-settler unreachable-branch carve-out" for why 3 Exact + 4 Partial leaves pass today.
```

**PR 2b (impl-only):**
```markdown
## Stack Position: 2b/5 `impl/evc-adapter`
**Base:** `test/evc-adapter-btt` (PR 2a)
**Diff from parent:** [compare](../../compare/test/evc-adapter-btt...impl/evc-adapter)
**Tests:** no new tests
**Implementation:** `contracts/fillers/EvcRolloverAdapter.sol` body wired for Exact + Partial surfaces
**Gate:** `forge test --match-path "test/filler/evc/exact/*"` + `"test/filler/evc/partial/*"` + `"test/filler/evc/infra/*"` — all PASS. `forge test --match-path "test/filler/*"` — landed `RolloverFiller` suite still PASS (no regression). `forge fmt --check` PASS; `mise fmt-check` PASS.
```

**PR 3a (test-only — carve-out from strict test-first discipline):**

> **Gate exception:** PR 3a does NOT have to fail red. The impl at PR 2b is complete for happy paths and most invariants; PR 3a's purpose is to surface edge-case impl gaps through property-based invariants + end-to-end integration scenarios. A PR 3a that passes green on day 1 is **valid** — it means the impl is already correct on those surfaces. This is the only exception to the repo-wide test-first / fail-red discipline (vs. PR 2a which MUST fail red). Rationale: forcing artificial failures in PR 3a to satisfy the rule would pollute the handler and obscure real regressions.

```markdown
## Stack Position: 3a/5 `test/evc-adapter-invariants-and-integration`
**Base:** `impl/evc-adapter` (PR 2b)
**Diff from parent:** [compare](../../compare/impl/evc-adapter...test/evc-adapter-invariants-and-integration)
**Tests:** `test/filler/evc/invariant/*` (handler + INV-F1..F8) + `test/filler/evc/integration/*` (7 scenarios)
**Implementation:** none
**Gate:** `forge test --match-path "test/filler/evc/invariant/*"` and `"test/filler/evc/integration/*"` — **up to 3 documented failures allowed** pending PR 3b fixes. Zero failures is also acceptable (carve-out above — this PR is not required to fail red). Each failure MUST be listed in the PR body with (a) the exact test name, (b) the observed vs expected behaviour, (c) a one-line root-cause hypothesis, and (d) the PR 3b task that fixes it. More than 3 failures → stop-ship; fold the fixes into PR 3b Task 9 instead. `forge fmt --check` PASS; `mise fmt-check` PASS.
```

**PR 3b (impl-only):**
```markdown
## Stack Position: 3b/5 `impl/evc-adapter-integration-and-deploy`
**Base:** `test/evc-adapter-invariants-and-integration` (PR 3a)
**Diff from parent:** [compare](../../compare/test/evc-adapter-invariants-and-integration...impl/evc-adapter-integration-and-deploy)
**Tests:** no new tests
**Implementation:** any fix to `EvcRolloverAdapter.sol` surfaced by invariants/integration + `script/foundry-scripts/DeployEvcAdapters.s.sol`
**Gate:** `forge test --match-path "test/filler/*"` — ALL green (EVC + landed filler + infra); `forge script DeployEvcAdapters` dry-runs against anvil. `forge fmt --check` PASS; `mise fmt-check` PASS.
```

### Stacked PR Workflow

```bash
gh pr create --base main --title "PR 1: feat/evc-adapter-interfaces-and-stubs"
gh pr create --base feat/evc-adapter-interfaces-and-stubs --title "PR 2a: test/evc-adapter-btt"
gh pr create --base test/evc-adapter-btt --title "PR 2b: impl/evc-adapter"
gh pr create --base impl/evc-adapter --title "PR 3a: test/evc-adapter-invariants-and-integration"
gh pr create --base test/evc-adapter-invariants-and-integration --title "PR 3b: impl/evc-adapter-integration-and-deploy"
```

### Branch names

```
feat/evc-adapter-interfaces-and-stubs            (PR 1,  base: main)
test/evc-adapter-btt                             (PR 2a, base: PR 1)
impl/evc-adapter                                 (PR 2b, base: PR 2a)
test/evc-adapter-invariants-and-integration      (PR 3a, base: PR 2b)
impl/evc-adapter-integration-and-deploy          (PR 3b, base: PR 3a)
```

---

## Source files changed per PR

### Added (PR 1)
- `lib/ethereum-vault-connector` (submodule via `forge install euler-xyz/ethereum-vault-connector`)
- `remappings.txt` (add `evc/=lib/ethereum-vault-connector/src/`)
- `contracts/interfaces/IEvcRolloverAdapter.sol`
- `contracts/fillers/EvcRolloverAdapter.sol` (stub — reverts `NotImplemented()`)
- `test/filler/BaseTestEvcFillerAdapter.sol` (harness, extends `BaseTestFiller`)
- `test/filler/evc/infra/HarnessSmoke.t.sol`

### Added (PR 2a — tests only)
- `test/filler/evc/exact/EvcRolloverAdapter_execute.tree`
- `test/filler/evc/exact/EvcRolloverAdapter_execute.t.sol`
- `test/filler/evc/partial/EvcRolloverAdapter_execute.tree`
- `test/filler/evc/partial/EvcRolloverAdapter_execute.t.sol`

### Modified (PR 2b — impl only)
- `contracts/fillers/EvcRolloverAdapter.sol` (replace stub with parameterised Exact + Partial body)

### Added (PR 3a — tests only)
- `test/filler/evc/invariant/EvcAdapterInvariantHandler.sol`
- `test/filler/evc/invariant/EvcAdapterInvariant.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_ExactHappyPath.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_PartialSameDigestTerminal.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_DirectCallRejected.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_InsufficientPreBalance.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_RefundPath.t.sol`
- `test/filler/evc/integration/EvcRolloverAdapter_CallPath.t.sol`

### Added (PR 3b — impl + script)
- `script/foundry-scripts/DeployEvcAdapters.s.sol`
- any `EvcRolloverAdapter.sol` fixes from invariants/integration findings

---

## PR 1: `feat/evc-adapter-interfaces-and-stubs`

**Diff from parent:** `compare/main...feat/evc-adapter-interfaces-and-stubs`

Creates the compilation surface for tests. **Zero adapter logic** — only submodule, interface, reverting stub, and the test harness.

### Task 1: EVC submodule + remap

- [ ] `forge install euler-xyz/ethereum-vault-connector` — pin the commit in `.gitmodules`.
- [ ] `remappings.txt` — add `evc/=lib/ethereum-vault-connector/src/`.
- [ ] Verify compile: a throwaway `import "evc/EthereumVaultConnector.sol";` inside `BaseTestEvcFillerAdapter` (see Task 3) builds cleanly.
- [ ] Add an `ACKNOWLEDGEMENTS.md` entry (if the repo has one; otherwise note the GPL-2.0 obligation in the PR body for reviewer sign-off).

### Task 2: `IEvcRolloverAdapter` interface + reverting stub

- [ ] `contracts/interfaces/IEvcRolloverAdapter.sol`:
  - `function execute(bytes calldata orderData, bytes calldata signature, bytes calldata originFillerData, uint256 srcCstAmount, address debitFrom, address destination) external;` — same shape as `IRolloverFiller.execute` (DP-B parity).
  - Custom errors:
    - `EvcRolloverAdapter__ZeroDestination()` — destination is zero.
    - `EvcRolloverAdapter__InvalidCaller()` — `EVC.getCurrentOnBehalfOfAccount(msg.sender) == address(0)`.
    - `EvcRolloverAdapter__InsufficientTokens(address token, uint256 required, uint256 available)` — pre-balance check shortfall.
    - `EvcRolloverAdapter__SettlerMismatch(bool expectedPartial)` — constructor probe.
    - `EvcRolloverAdapter__FactoryMismatch(address expected, address actual)` — constructor cross-check.
    - `EvcRolloverAdapter__ZeroEvc()` — constructor zero-EVC guard.
  - NatSpec drafts for each parameter + the EVC-caller-resolution + no-sweep-of-leftovers invariant.
  - Draft NatSpec, confirm with user before committing (per coding conventions).
- [ ] `contracts/fillers/EvcRolloverAdapter.sol`:
  - Constructor `(address settler_, bool isPartial_, address expectedFactory_, address evc_)` — four immutables `SETTLER`, `IS_PARTIAL`, `FACTORY` (zero on Exact), `EVC`.
  - Stub body: revert with `NotImplemented()` (reuse the existing error from `BaseSettlerErrors.sol`).
  - Import path hygiene: import `IEvcRolloverAdapter` from `contracts/interfaces/IEvcRolloverAdapter.sol`, implement it.
- [ ] `forge build` passes.

### Task 3: `BaseTestEvcFillerAdapter` harness

- [ ] Create `test/filler/BaseTestEvcFillerAdapter.sol` inheriting `BaseTestFiller` (landed):
  - `super.setUp()` deploys factory, registry, cellars, modules, tokens, both settlers, `ERC6909Premium`, and the landed `RolloverFiller` fillers.
  - Deploy `EthereumVaultConnector evc = new EthereumVaultConnector();`.
  - Deploy `EvcRolloverAdapter evcAdapterExact = new EvcRolloverAdapter(address(exactSettler), false, address(0), address(evc));`.
  - Deploy `EvcRolloverAdapter evcAdapterPartial = new EvcRolloverAdapter(address(partialSettler), true, expectedFactory, address(evc));`.
  - Convenience helpers per `plan/evc-adapter-test-spec.md` §2.3:
    - `_authoriseAdapterOperator(subaccount, adapter)`
    - `_prepareAdapterErc6909(subaccount, premiumToken, premiumAmount)`
    - `_executeViaEvcBatch(adapter, subaccount, preFundingItem, order, ...)` — builds the `BatchItem[]` and calls `evc.batch(items)`.
    - `_seedAdapterSrcCst(adapter, srcCstToken, amount)` — direct transfer for isolated unit tests.
    - `_adapterSnapshot(adapter, expectedSrcCstLeftover)` — post-execute asserter.
- [ ] Add `test/filler/evc/infra/HarnessSmoke.t.sol` — a single test that asserts all immutables are set, the two adapters bind to distinct settlers, EVC is non-zero, and calling `execute` via `evc.batch` hits the stub revert (whole batch reverts).
- [ ] `forge test --match-path "test/filler/evc/infra/*"` passes.

**Gate:** `forge build` PASS; `forge test --match-path "test/filler/evc/infra/*"` PASS (smoke); stub reverts observable; `forge fmt --check` PASS; `mise fmt-check` PASS.

---

## PR 2a: `test/evc-adapter-btt`

**Diff from parent:** `compare/feat/evc-adapter-interfaces-and-stubs...test/evc-adapter-btt`

Tree + tests for both Exact and Partial bindings. **Tests only** — the stub remains. Tests MUST fail red against the stub.

### Task 4: BTT tree for Exact binding

- [ ] Copy `plan/btt-draft/EvcRolloverAdapter_execute_Exact.tree` → `test/filler/evc/exact/EvcRolloverAdapter_execute.tree`.
- [ ] `bulloak scaffold test/filler/evc/exact/EvcRolloverAdapter_execute.tree` → `EvcRolloverAdapter_execute.t.sol`.
- [ ] Hand-extend leaves where bulloak rejects the leaf text (repo precedent: PR 3 `ERC6909Premium` hand-fixed snake_case names — same pattern acceptable here).
- [ ] Implement all 48 leaf bodies against the stub — every leaf MUST fail with the stub's `NotImplemented()` (surfaced as the whole `evc.batch` reverting). Use `_executeViaEvcBatch(evcAdapterExact, ...)` wrapper from `BaseTestEvcFillerAdapter`.
- [ ] Any leaf-level edits (re-wording, splitting a branch, dropping a defensive leaf) MUST round-trip back into `plan/btt-draft/EvcRolloverAdapter_execute_Exact.tree` in the same commit so the draft stays authoritative.

### Task 5: BTT tree for Partial binding

- [ ] Copy `plan/btt-draft/EvcRolloverAdapter_execute_Partial.tree` → `test/filler/evc/partial/EvcRolloverAdapter_execute.tree`.
- [ ] `bulloak scaffold` → `EvcRolloverAdapter_execute.t.sol`.
- [ ] Implement all 58 leaf bodies against the stub — every leaf MUST fail.
- [ ] Round-trip any edits back into `plan/btt-draft/EvcRolloverAdapter_execute_Partial.tree`.

**Gate:** `forge build` PASS; `forge test --match-path "test/filler/evc/exact/*"` — all **adapter-path** leaves FAIL red (expect 45 of 48); `forge test --match-path "test/filler/evc/partial/*"` — all **adapter-path** leaves FAIL red (expect 54 of 58); `forge fmt --check` PASS; `mise fmt-check` PASS. If any **adapter-path** leaf passes against the stub, the leaf is not testing anything — fix the leaf before merge.

**Direct-settler unreachable-branch carve-out.** Some revert branches in the `.tree` files cannot fire through `adapter.execute` — the adapter's invariants make them unreachable. Examples: `PremiumBeforeRollover` (adapter always rolls over first), `TargetFillerMismatch` (adapter always sets `targetFiller = address(this)`), `NoRolloverLegForFiller` (adapter always runs the rollover leg first in the same tx), `AlreadySettled` premium / `AlreadyFilled` premium / `InvalidOrderStatus` finalise / `PaymentNotSettled` finalise (adapter rolls back or runs the full sequence atomically). The landed `test/filler/exact/RolloverFiller_execute.t.sol` frames these branches as direct-settler calls — the leaf body invokes `exactSettler.fill(...)` / `partialSettler.fill(...)` / `finaliseAsSettled(...)` directly and asserts the settler bubbles the expected error, proving the revert surface exists even though `adapter.execute` cannot reach it. These leaves PASS today (they don't touch the stub) AND pass in PR 2b (unchanged). They are **exempt** from the fail-red count. Expected totals: 3 of 48 Exact leaves are direct-settler; 4 of 58 Partial leaves are direct-settler. Any future leaf classification change (reachable ↔ unreachable) must update the expected gate counts above and the PR 2a description.

---

## PR 2b: `impl/evc-adapter`

**Diff from parent:** `compare/test/evc-adapter-btt...impl/evc-adapter`

Implementation only. Flips PR 2a's 106 failing tests green without regressing the landed `RolloverFiller` suite.

### Task 6: Implement `EvcRolloverAdapter.execute` parameterised for Exact + Partial

**File:** `contracts/fillers/EvcRolloverAdapter.sol` — replace stub body.

- [ ] `execute(bytes calldata orderData, bytes calldata signature, bytes calldata originFillerData, uint256 srcCstAmount, address debitFrom, address destination) external nonReentrant`:
  1. `address caller = IEVC(EVC).getCurrentOnBehalfOfAccount(msg.sender);` — if zero, revert `EvcRolloverAdapter__InvalidCaller()`.
  2. `if (destination == address(0)) revert EvcRolloverAdapter__ZeroDestination();`
  3. Decode `GaslessCrossChainOrder memory order = abi.decode(orderData, (GaslessCrossChainOrder));`.
  4. Decode `OrderData memory od = abi.decode(order.orderData, (OrderData));` — get `srcCstToken` + `premiumToken`.
  5. Compute `bytes32 orderId = LibSettlerHashing.computeOrderId(SETTLER, order);`.
  6. Pre-balance check:
     ```solidity
     uint256 available = IERC20(od.srcCstToken).balanceOf(address(this));
     if (available < srcCstAmount) {
         revert EvcRolloverAdapter__InsufficientTokens(od.srcCstToken, srcCstAmount, available);
     }
     ```
  7. Idempotent `openFor`:
     ```solidity
     if (IOrderStatusView(SETTLER).orderStatus(orderId) == OrderStatus.None) {
         IExactFillSettler(SETTLER).openFor(order, signature, originFillerData);
     }
     ```
  8. `IERC20(od.srcCstToken).forceApprove(SETTLER, srcCstAmount);`.
  9. `bytes memory originDataForFill = abi.encode(order);`.
  10. Build rollover / premium fillerData:
     - If `IS_PARTIAL`: use `LibRolloverOrder.extractCellarIntentFromOrderData(od, order, SETTLER, FACTORY)` to reconstruct `(intent, cellarSig)`. Build `PartialFillerData` for both legs with `targetFiller: address(this)`.
     - Else: build `RolloverFillerData{destination}` and `PremiumFillerData{debitFrom}`.
  11. `IDestinationSettler(SETTLER).fill(orderId, originDataForFill, rolloverFillerData);`.
  12. `IERC20(od.srcCstToken).forceApprove(SETTLER, 0);` — release allowance unconditionally before premium leg.
  13. `IDestinationSettler(SETTLER).fill(orderId, originDataForFill, premiumFillerData);`.
  14. Finalise:
     - If `IS_PARTIAL`: `IPartialFillSettler(SETTLER).finaliseAsSettled(orderDigest, [address(this)]);`.
     - Else: `IExactFillSettler(SETTLER).finaliseAsSettled(orderId);`.
  15. **No leftover return.** Adapter retains any excess srcCST per RFC §7.3 ("doesn't return leftovers"). Curators sweep via sibling batch items.
- [ ] Constructor body: match `RolloverFiller.sol`'s Exact-probe + factory cross-check pattern, using the adapter's own error types. Add `if (evc_ == address(0)) revert EvcRolloverAdapter__ZeroEvc();`.
- [ ] Persistent-state invariant: the contract MUST end every `execute` call holding zero dstCST and zero non-zero approvals. The srcCST balance MAY be non-zero (pre-balance excess + underfill leftover); this is enforced by `_adapterSnapshot` with a tracked `expectedSrcCstLeftover` argument.
- [ ] `forge test --match-path "test/filler/evc/*"` — all pass (48 + 58 + infra smoke).
- [ ] `forge test --match-path "test/filler/*"` — landed `RolloverFiller` suite still all pass (no regression).

**Gate:** All EVC + landed `RolloverFiller` + infra tests green; `forge fmt --check` PASS; `mise fmt-check` PASS.

---

## PR 3a: `test/evc-adapter-invariants-and-integration`

**Diff from parent:** `compare/impl/evc-adapter...test/evc-adapter-invariants-and-integration`

Invariant handler + invariant tests + integration scenarios. Tests only. Most should pass; a subset may fail where invariants expose edge-case impl gaps — those failures are resolved in PR 3b.

### Task 7: Invariant handler + test contract

- [ ] `test/filler/evc/invariant/EvcAdapterInvariantHandler.sol`:
  - Actions: `actionExecuteExactHappy`, `actionExecutePartialHappy`, `actionExecuteZeroDestination`, `actionExecuteInsufficientBalance`, `actionExecuteDirectCall` (outside batch), `actionExecuteOverFunded`.
  - Every happy-path action wraps the adapter call in `evc.batch([seedItem, executeItem])`.
  - Ghost state: `ghost_callerPreBalance`, `ghost_adapterSrcCstExcess[adapter]`, `ghost_adapterDstCstSeen`, `ghost_adapterAllowanceSeen[token][spender]`, `ghost_fillerFinalised[digest][adapter]`.
- [ ] `test/filler/evc/invariant/EvcAdapterInvariant.t.sol`:
  - `invariant_F1_adapterHoldsNoUnexpectedTokens()` — balance ≤ tracked excess; dstCST always 0.
  - `invariant_F2_noDanglingApprovals()`.
  - `invariant_F4_adapterHoldsNo6909()`.
  - `invariant_F5_adapterNotOperator()`.
  - `invariant_F6_evcCallerResolutionHolds()` — when a `batch` item with `onBehalfOfAccount == subaccount` calls the adapter, the subaccount is the ERC-6909 debit source whenever `debitFrom == resolvedCaller`.
  - `invariant_F7_atomicRevertParity()`.
  - `invariant_F8_noEventsFromAdapter()`.
  - INV-F3 intentionally absent (dropped).
- [ ] Handler routes through both `evcAdapterExact` and `evcAdapterPartial` in weighted fashion. Ghost state separates per-adapter ledgers.

### Task 8: Integration tests

Seven files per `plan/evc-adapter-test-spec.md` §7:

- [ ] `EvcRolloverAdapter_ExactHappyPath.t.sol`
- [ ] `EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests.t.sol`
- [ ] `EvcRolloverAdapter_PartialSameDigestTerminal.t.sol`
- [ ] `EvcRolloverAdapter_DirectCallRejected.t.sol`
- [ ] `EvcRolloverAdapter_InsufficientPreBalance.t.sol`
- [ ] `EvcRolloverAdapter_RefundPath.t.sol`
- [ ] `EvcRolloverAdapter_CallPath.t.sol`

Each test:
- uses `_authoriseAdapterOperator` + `_prepareAdapterErc6909` in a realistic subaccount setup;
- wraps adapter calls in `evc.batch([seedItem, executeItem, optionalSweepItem])`;
- asserts end-state per the scenario description.

Any failure MUST be documented in the PR body with a link to the PR 3b task that resolves it.

**Gate:** `forge build` PASS; invariant + integration suites run; up to 3 documented failures allowed; `forge fmt --check` PASS; `mise fmt-check` PASS.

---

## PR 3b: `impl/evc-adapter-integration-and-deploy`

**Diff from parent:** `compare/test/evc-adapter-invariants-and-integration...impl/evc-adapter-integration-and-deploy`

Any impl fixes surfaced by PR 3a + deploy script.

### Task 9: Impl fixes from PR 3a findings

- [ ] Read every failing test in PR 3a's PR body; triage each. Fix in `contracts/fillers/EvcRolloverAdapter.sol`.
- [ ] `forge test --match-path "test/filler/*"` — ALL pass (EVC + landed filler + infra).

### Task 10: Deploy script

- [ ] `script/foundry-scripts/DeployEvcAdapters.s.sol`:
  ```solidity
  function run() external returns (address exactAdapter, address partialAdapter) {
      address exactSettler = _resolveSettlerAddress("ExactFillSettler");
      address partialSettler = _resolveSettlerAddress("PartialFillSettler");
      address factory = _resolveFactoryAddress();
      address evc = _resolveEvcAddress();
      vm.startBroadcast();
      exactAdapter = address(new EvcRolloverAdapter(exactSettler, false, address(0), evc));
      partialAdapter = address(new EvcRolloverAdapter(partialSettler, true, factory, evc));
      vm.stopBroadcast();
  }
  ```
  Resolution order: env override → on-chain `networks.json` if landed → fail with a clear revert if neither resolves. The Partial adapter this script produces is a **canonical reference deployment**, not a shared instance for all curators — per DP-EVC-A, production Partial adapters are deployed per subaccount.
- [ ] `test/script/DeployEvcAdapters.t.sol` — assert the script deploys two adapters, each bound to the correct settler + EVC.
- [ ] `forge script DeployEvcAdapters --fork-url <anvil>` — dry-runs green.

**Gate:** `forge test --match-path "test/filler/*"` — ALL pass; `forge script DeployEvcAdapters` dry-runs green; `forge fmt --check` PASS; `mise fmt-check` PASS.

---

## execute-cork Execution Schedule

| Run | PR | Tasks | Agents | Gate |
|---|---|---|---|---|
| 1 | PR 1 | 1–3 | 2 | `forge build` PASS; infra smoke PASS |
| 2 | PR 2a | 4–5 | 2 | `forge build` PASS; 48 exact + 58 partial FAIL red |
| 3 | PR 2b | 6 | 1 | 106 EVC PASS; landed `RolloverFiller` suite still PASS |
| 4 | PR 3a | 7–8 | 2 | Invariant + integration runs; ≤3 failures documented |
| 5 | PR 3b | 9–10 | 2 | ALL filler tests PASS; deploy script dry-run PASS |

**Total: 5 runs, 9 agents.**

Strictly sequential. Each test-only branch is gated by "fails visibly against stub"; each impl branch is gated by "turns parent branch's failing tests green with no regressions elsewhere."

---

## Risks + unknowns

- **EVC submodule licence (GPL-2.0).** The repo currently ships under MIT (see contract SPDX headers). Introducing a GPL-2.0 dependency as a build-time submodule does not relicense the repo, but it means the combined binary is GPL-2.0 if distributed. Call this out in the PR 1 body for explicit reviewer sign-off; add an `ACKNOWLEDGEMENTS` entry per repo convention. If reviewers reject GPL inclusion, Option C from Q2 (minimal in-repo `IEVC` interface + real-contract fixture compiled from a vendored snapshot or a mock) is the fallback — would require a separate plan revision.
- **EVC version drift.** EVC is active upstream; pin to a commit hash in `.gitmodules` at PR 1 time and document the choice. Pre-emptive verification: run `forge build` after install to catch any API drift from what RFC §7.3 assumes (`getCurrentOnBehalfOfAccount`, `BatchItem`, `batch`).
- **`getCurrentOnBehalfOfAccount` outside a batch.** If `msg.sender != address(EVC)` or no active batch/call frame is set, EVC returns `address(0)` — the adapter treats this as "direct call" and reverts `__InvalidCaller`. Exercised by `EvcRolloverAdapter_DirectCallRejected.t.sol` and by the two EVC-caller-resolution leaves in both trees. A subtle case: if a bot calls `evc.call(adapter, onBehalfOfAccount=subaccount, ...)` (single-item batch equivalent), `getCurrentOnBehalfOfAccount` resolves correctly — the adapter does not distinguish `call` from `batch`.
- **No sweep of adapter leftovers.** INV-F1 is relaxed to allow non-zero srcCST on the adapter after `execute`. Curators MUST compose a sibling sweep step if they want leftover routing. Document in the integrator README. Failure mode: a curator that skips the sweep leaves srcCST stranded on the adapter — a helper `sweepTo(address token, address to)` with `onlyOperator` gating could be added in a follow-up, but is out of scope for v1 (RFC §7.3 is silent on this).
- **Back-to-back `execute` calls inside the same batch.** `ReentrancyGuardTransient` clears at tx end and releases the lock *between* `BatchItem` top-level calls because each item is a new outer call frame. The guard protects against nested `execute → destination.hook → execute` reentry within a single item. Tested by both trees' "back-to-back in same batch" leaf.
- **Partial identity collision under EVC.** `PartialFillSettler` keys per-filler state on `msg.sender` — which is the adapter address, not the subaccount. A shared `EvcRolloverAdapter(partial, ...)` reused across subaccounts would collapse every subaccount into one slot at the settler. DP-EVC-A addresses this: curators deploy per-subaccount. Integration test #2 (`EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests.t.sol`) deploys two separate adapter instances.
- **`debitFrom` semantics drift.** The settler-side authorisation check (`isOperator(debitFrom, settler) && isOperator(debitFrom, adapter)`) is the authoritative gate. If a curator passes a `debitFrom` that does not authorise both, the premium leg reverts and the whole `evc.batch` rolls back. The EVC does not change this behaviour; `getCurrentOnBehalfOfAccount` is informational for the adapter's own logic only.
- **`LibRolloverOrder.encode*FillerData` helpers are settler-incompatible (landed-code drift).** Already flagged in the landed `plan/filler-implementation-plan.md` — the encoders use `abi.encode(uint8, struct)` which left-pads uint8. The EVC adapter MUST use `abi.encodePacked(uint8(...), abi.encode(...))` just like the landed filler. Do NOT call the library encoders.
- **Fee-on-transfer / rebasing / ERC-777 tokens.** RFC 003 §6.6 declares these unsupported; enforcement is at the Cork API. Adapter inherits this — if an unsupported token is wired into an order, behaviour is undefined.
- **Transient reentrancy guard semantics.** Clears at tx end. If `execute` reverts mid-way inside a batch, the whole batch reverts and the guard releases. Called out for clarity; not a risk.
- **ERC-6909 preflight helper.** Deferred with the same rationale as the landed filler. On-chain preflight would only trade revert selectors at a 3-SLOAD cost per successful fill. Document in the integrator README.
- **Multi-tx advanced profile.** Out of scope. Reference adapter enforces the atomic profile only (the whole `evc.batch` is one tx).
- **Curator-side sibling batch items.** The reference integrator recipe (`docs/integrations/euler-curator-evc.md` — optional follow-up) should show a canonical 3-item batch: `[EVault.withdraw → adapter.execute → EVault.deposit]`. Not required for adapter correctness but valuable for integrators. Decide at PR 3b time whether to ship this doc here or defer.
