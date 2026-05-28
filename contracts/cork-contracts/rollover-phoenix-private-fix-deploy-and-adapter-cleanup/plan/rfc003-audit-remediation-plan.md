# RFC 003 Audit Remediation Implementation Plan

> **Execution method:** `deliver-stacked-prs-cork` skill — one agent run per PR, strictly sequential. Each PR is one execute-cork run; within a run, multiple agents may dispatch in parallel for file-level work on one task, but never across tasks.
>
> **Discipline:** TDD per chunk — each PR writes failing BTT tests first, then implementation to make them pass. Test and implementation ship together in one reviewable unit.
>
> **Test details:** See `plan/rfc003-audit-remediation-test-spec.md` for BTT tree inventory per PR, invariant matrix updates, mock policy, and fixture notes. This plan covers only execution steps, source-side changes, and dependency ordering.
>
> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Do not mark complete until the gate run for the containing PR passes.

**Goal:** Close 21 open GitHub audit-finding / RFC-gap issues in `rollover-phoenix-private` against the **current** state of RFC 003 (Underwriter Rollover Intent). Delivery is a stack of 12 dependency-ordered code PRs plus one cross-repo cork-knowledge PR (non-blocking).

**Architecture:** The current repo ships `BaseSettler` (abstract), `ExactFillSettler`, `PartialFillSettler`, `ERC6909Premium`, `LibRolloverOrder`, `LibSettlerHashing`, plus `RolloverFiller` and `EvcRolloverAdapter`. This plan (a) extends the order schema with AS-19/20/21 fields, (b) expands `computeOrderDigest` to be identity-complete, (c) collapses settler pair asymmetries into a symmetric `BaseSettler` (T6 full refactor), (d) splits the `IS_PARTIAL`-parametrised filler pair into 4 reference contracts per RFC §7.2/§7.3 (T7), (e) adds the rescue path, token-quirk defence, CEI fixes, state-parity assertion, attribution event, and docs / deploy cleanup required by the other issues.

**Tech stack:** Solidity 0.8.30, Foundry, OpenZeppelin (SafeERC20, SignatureChecker, Math, ReentrancyGuardTransient), solady (where already used), bulloak for BTT scaffolding. Real rhinestone `Registry` and Cork Phoenix pool manager via cellar's `BaseTestCorkCellar`.

**Source of truth:** RFC `003-underwriter-rollover-intent.md` (current on `main`), GitHub issues #36–#64 (open) for finding detail, BTT `.tree` files co-located with `.t.sol` in the test tree, and `plan/rfc003-audit-remediation-test-spec.md`.

---

## Amendment history

**2026-04-24 — Post-PR-#65 remediation amendment.** After PR #65 (`fix(evc-adapter): audit remediation — B1, A1-A6, A8, C-N1..C-N8`) merged on 2026-04-24 at 08:12 UTC, the following target issues were already closed on `main` and removed from this plan's scope:

| Closed issue | Landed via | Original plan target |
|---|---|---|
| #36 C2 empty-fillers brick | commit `fafcf65` | (former) PR 4 Task 11 |
| #38 T2 Partial premium-leg targetFiller | commit `d7719c6` | (former) PR 4 Task 12 |
| #50 finaliseAsCancelled nonReentrant | commit `1ec403c` | (former) PR 6 (entirely) |
| #51 Exact ZeroRollover guard | commit `a438194` | (former) PR 4 Task 10 (guard bullet) |
| #52 Encoder abi.encodePacked | commit `8915c61` | (former) PR 2 (entirely) |

**Effect on stack:** 2 PRs removed (old PR 2 and old PR 6), 1 PR re-scoped (old PR 4 → new PR 3: only #42 + #53). Old PR 7 Task 23 re-scoped — deposit-side delta accounting already landed via `0cdb91c`, only the settle-side delta + blacklist payout work remains. Total: 14 → 12 code PRs. Target issues: 26 → 21. All PR numbers below reflect the new numbering; the mapping to original numbers is shown in the stack table.

---

## Coding conventions (hard rules)

Apply to every contract, test, and script in this plan. These override any looser interpretation that could be inferred from the surrounding code.

- **No `unchecked` blocks** unless an inline comment explicitly justifies the bound (e.g., a loop counter with a compile-time ceiling).
- **Custom errors only.** No string reverts, no `require(..., "msg")`. Every revert carries a typed error.
- **OpenZeppelin first.** Prefer `SafeERC20`, `SignatureChecker`, `Math`, `ReentrancyGuard`/`ReentrancyGuardTransient`, `Ownable2Step`, `TimelockController`. Do not reimplement anything OZ already ships.
- **No bespoke timelocks.** If any function needs timelock gating, use `TimelockController`.
- **One interface per file.** Events and custom errors live on the interface, not the implementation. Implementations import the interface and re-use its error/event types.
- **Detailed NatSpec on every interface.** `@notice`, `@param`, `@return`, and `@dev` where state transitions or revert conditions are non-obvious.
- **Immutables at contract scope.** Anything set once in the constructor is `immutable`. Do not inline constants into function bodies — lift them to contract-scope `constant` / `immutable` fields.
- **No mocks for protocol integrations.** Deploy real contracts as test fixtures. Phoenix + cellar flow through `BaseTestCorkCellar`. The one allowed mock remains `MockBaseSettler`.
- **Compact, readable code layout.** Group by responsibility; separate groups with a single blank line. Delete dead code; never leave commented-out blocks. No trailing whitespace.
- **Solidity 0.8.30.** Pragma line matches existing contracts.
- **New external surface requires justification.** If a PR introduces a new public/external function (PR 6 `rescueSettled`, PR 9 `PREMIUM_FILLER_SLOT` tstore), the PR body must cite the issue(s) driving it, document its trust boundary in NatSpec, and the task list includes the new-external-surface pre-check described in the "Execution conventions" section below.

## Execution conventions (hard rules)

- **Sequential PRs, not parallel.** One PR completes before the next starts. Parallel agents may dispatch within a single PR (e.g., multiple files under one task) but never across PRs — agents step on shared state.
- **Post-PR compliance re-check.** After every PR's gate passes, re-read the PR body, diff against the produced code and tests, and re-verify cited issue acceptance criteria. Report any divergence before opening the next PR. If the plan is wrong, stop and raise it — do not silently deviate.
- **State the goal before acting.** Every agent dispatch begins with a one-sentence statement of the PR and its success criteria. No speculative changes outside the stated goal.
- **TDD per chunk.** Scaffold `.t.sol` from the `.tree` file first, fail visibly, then write implementation. Tests and implementation ship in one reviewable commit.
- **New-external-surface pre-check (PR 6, PR 9 only).** Before implementing: confirm the surface is present in the issue body's "Suggested fix", document the trust boundary in NatSpec, and add at least one BTT leaf per revert path.
- **Invariant gate never sets `FOUNDRY_PROFILE=ci`.** Per-PR gates run `forge test --match-contract "*Invariant*"` under the default profile. The `.github/workflows/unit.yaml` Step 6 already runs the EVC adapter invariants under `ci` — do not change the workflow.
- **`forge fmt` and `mise fmt-check` on every PR gate.** Never commit with formatting violations.

---

## Stacked PR Strategy

12 code PRs stacked on top of `main`, plus one cross-repo PR (PR 13) that targets `cork-knowledge`. Each code PR's base is the previous PR's branch; after a parent merges, the child is rebased onto `main` before merge.

| PR | Branch | Base | Closes | Orig # |
|---|---|---|---|---|
| 1 | `fix/as19-as21-ingress-gates` | `main` | #37, #45 | 1 |
| 2 | `fix/compute-order-digest-identity` | PR 1 | #41 (code side) | 3 |
| 3 | `fix/terminal-and-settler-symmetry` | PR 2 | #42, #53 | 4 (re-scoped) |
| 4 | `refactor/filler-pair-split` | PR 3 | #43 | 5 |
| 5 | `fix/token-quirk-defence` | PR 4 | #39 | 7 |
| 6 | `feat/stranded-value-rescue` | PR 5 | #44 | 8 |
| 7 | `fix/seam-as10-phase0` | PR 6 | #58 | 9 |
| 8 | `fix/seam-cei-premium-leg` | PR 7 | #60 | 10 |
| 9 | `feat/seam-state-parity-assertion` | PR 8 | #61, #63 | 11 |
| 10 | `feat/order-attribution-event` | PR 9 | #47, #46 | 12 |
| 11 | `docs/filler-trust-boundary` | PR 10 | #49, #64 | 13 |
| 12 | `fix/deploy-and-adapter-cleanup` | PR 11 | #54, #55, #56, #57 | 14 |
| 13 | `docs/cork-knowledge-rfc-amendment` | `cork-knowledge` repo `rfc/uw-intent-rollover-003` | #41 (RFC side), #48 | 15 |

**Superseded (do NOT execute):** old PR 2 `fix/lib-rollover-encoder-shape` (#52), old PR 6 `fix/finalise-as-cancelled-reentrancy` (#50). Both closed by commits that landed via PR #65 on 2026-04-24.

### Dependency rationale

- **PR 2 → PR 1:** digest identity expansion must read the post-AS-19/21 encoder shape (includes `minFillSize` + `exclusiveFiller` in the digest preimage).
- **PR 3 bundles 2 issues** (#42 full settler refactor, #53 uint128/uint256 unification) because T6's refactor rewrites the same functions D-5 patches. Splitting would require two rewrites. The original bundle's #36, #38, #51 were already landed by PR #65, so they no longer sit here.
- **PR 4 → PR 3:** filler split consumes the post-refactor `BaseSettler` surface.
- **PRs 5–6** are independent hardening on the settled settler + filler shape.
- **PRs 7–9** are seam fixes (premium hook isolation, CEI write ordering, state-parity assertion) layered in that order because each assumes the prior invariant holds.
- **PR 10** attribution event depends on the post-parity state being reliable enough to emit.
- **PR 11** docs-only, uses the settled shape.
- **PR 12** deploy/adapter cleanup last to avoid churn on earlier branches.
- **PR 13** cross-repo; non-blocking — runs in `../cork-knowledge-rfc-a8-amendment/` worktree, cleaned up after push.

### PR description template

Every PR body uses this template:

```markdown
## Stack Position: <n>/12 `<branch>`
**Base:** `<base-branch>`
**Diff from parent:** [compare](../../compare/<base>...<branch>)

## Summary
<1–3 bullets naming the behavioural change>

## Closes
Closes #<issue-n>
[Closes #<issue-m>]

## Test plan
- [ ] `forge fmt --check` clean
- [ ] `mise fmt-check` clean
- [ ] `forge test -vvv` all pass
- [ ] `forge test --match-contract "*Invariant*"` pass (default profile — do NOT set FOUNDRY_PROFILE=ci)
- [ ] `forge build --sizes` within bounds
- [ ] BTT `.tree` files updated in lockstep with `.t.sol`
```

### Offline push deferral (fallback)

If `git push` or `gh pr create` fails (SSH key not loaded, `gh auth` missing, network unreachable, 2FA prompt, rate limit) — do NOT block or try destructive workarounds. Continue locally:

1. Keep branching and committing against local tips.
2. Run all gates locally.
3. Append a row to `plan/pending-branches.md` after every affected commit. Columns: branch name, parent branch (PR target), last commit SHA, gate status, suggested PR title, suggested PR body. Append-only.
4. At the end of the run, surface `plan/pending-branches.md` and tell the user: "N branches ready to push; credentials failed on attempt — see file." Then stop.

The user runs:
```bash
git push -u origin <branch>
gh pr create --base <parent> --title "<from file>" --body "<from file>"
```

**Never** attempt: `--force`, rewriting commits that were pushed, changing `origin` URL, switching from SSH to HTTPS mid-run, deleting `.git/config` entries.

---

## PR 1: `fix/as19-as21-ingress-gates`

**Closes:** #37 (T1), #45 (M1)

**Diff from parent:** `compare/main...fix/as19-as21-ingress-gates`

Add four ingress gates per RFC §6.2 (AS-19 rollover-leg min-fill-size + AS-21 exclusive-filler + AS-20 decimal-truncation) and an additional plan-only gate (AS-22 residual-truncation — dust-fragmentation defence). AS-19/20/21 follow RFC §6.2 verbatim; AS-22 is a plan extension solving a different failure (unfillable residual) and is cited as such in NatSpec. Also add `minFillSize` + `exclusiveFiller` to `OrderData`. Purge the dead `ORDER_DATA_TYPE_HASH` (#45) and replace with the extended type hash wired into `computeOrderDigest` via PR 2.

### Task 1: Extend `OrderData` schema

- [ ] Modify `contracts/libs/LibRolloverOrder.sol`: add `uint256 minFillSize` and `address exclusiveFiller` to the `OrderData` struct. Place `minFillSize` after `orderSize` and `exclusiveFiller` after `allowUnderfill` to match RFC §A.3.
- [ ] Update `ORDER_DATA_TYPE_HASH` in `contracts/libs/LibSettlerHashing.sol` to include both fields in the EIP-712 pre-image string.
- [ ] Remove the stale `ORDER_DATA_TYPE_HASH` literal flagged by #45 — keep only the single authoritative constant wired into `computeOrderDigest`'s type-hash chunk.
- [ ] Update NatSpec on `OrderData` to explain the two new fields (per RFC §6.2 bullets on AS-19/20/21).

### Task 2: Add four `fill` gates to `BaseSettler`

- [ ] In `contracts/settlers/BaseSettler.sol::fill`, after status checks and before leg dispatch, add guards:
  - `NotExclusiveFiller` (AS-21) — if `od.exclusiveFiller != address(0) && msg.sender != od.exclusiveFiller`. Placed FIRST, before `_validateOpen(od)`, so a caller with an `exclusiveFiller` mismatch sees the authorization error rather than a validation error.
  - `BelowMinFillSize` (AS-19) — if `od.minFillSize != 0 && legOutput.amount < od.minFillSize`. Rollover leg ONLY (`outputIndex == 0`). Premium-leg `legOutput.amount` is in premium-token units and not comparable to a share-unit `minFillSize`.
  - `DecimalTruncates` (AS-20, RFC §6.2) — if `legOutput.amount % (10 ** decimalOffset) != 0`, where `decimalOffset = 18 - IERC20(IPoolShare(od.srcCstToken).poolManager().market(od.srcPoolId).collateralAsset).decimals()` (RFC §6.2 line 2009). Rollover leg ONLY. Implements the RFC's per-fill decimal-precision defence against silent-dust truncation inside the pool. If `decimalOffset == 0` (collateral ≥18-decimal), gate is a no-op. The cST wrapper's own `decimals()` is NOT the correct source — it is 18-decimal on the reference cellar and would short-circuit the gate for every real order.
  - `ResidualTruncates` (AS-22, plan extension — NOT in RFC) — if the Partial path's post-fill residual capacity `0 < residual < od.minFillSize`. Prevents dust-fragmentation: a fill that leaves an unfillable remainder. Partial-leg rollover ONLY. Exact skips (single fill per order). Implementation lives in `PartialFillSettler` via the existing virtual hook `_enforceTipTruncates` (rename internally to `_enforceResidualTruncates` for clarity, but keep the external behaviour).
- [ ] Add the four custom errors (`NotExclusiveFiller`, `BelowMinFillSize`, `DecimalTruncates`, `ResidualTruncates`) to `contracts/settlers/BaseSettlerErrors.sol` (plan's preferred shared-errors location).

### Task 3: BTT tree + tests

- [ ] Write `.tree` additions on both concretes' existing `_fill.tree` files: happy-path and revert-path leaves for each of AS-19, AS-20, AS-21, AS-22. AS-19/20/22 leaves live only on Partial OR mirror the Exact path with a leg-scope skip assertion; AS-21 leaves live on both. Add a happy-path leaf asserting AS-19 does NOT fire on the premium leg.
- [ ] Scaffold `.t.sol` and drive tests to red, then update the implementation to make them green.
- [ ] Extend `test/libs/LibSettlerHashing.t.sol` with a round-trip vector covering the expanded type hash.
- [ ] Extend `test/libs/LibRolloverOrder.t.sol` with encode/decode leaves for the two new fields AND a defensive `decode rejects legacy 17-field encoding` leaf (asserts `abi.decode` on a pre-PR-1 encoding traps).

### Task 4: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"` (default profile).
- [ ] Commit with message `fix(settler): add AS-19/20/21 ingress gates and extend OrderData schema`.
- [ ] Attempt push + PR creation against `main`. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; invariant suite green; `forge build --sizes` within bounds.

**Amendment 2026-04-24 (in-PR, cycle 1 review):** Original plan defined AS-20 as a "tip truncates" residual check. RFC §6.2 defines AS-20 as a decimal-truncation modulo check. Reviewer flagged the mismatch; user endorsed splitting — AS-20 keeps the RFC meaning (decimal); the plan's residual check becomes AS-22 (plan-only, documented as an extension). `cumulativeFilled` is re-keyed on `orderId` to avoid the PR 1-before-PR 2 digest-collision window flagged by the reviewer.

**Amendment 2026-04-24 (cycle-2 review):** Cycle-2 review B1 flagged that the cycle-1 AS-20 implementation reads `IERC20Metadata(od.srcCstToken).decimals()` — but per RFC §6.2 line 2009 the decimal source is `IPoolManager(poolManager).market(od.srcPoolId).collateralAsset`. On the reference cellar `srcCstToken` is the 18-decimal cST wrapper, so reading its decimals defeats the gate for every real order. §1g.5 ENDORSE on B1; user selected option (a) — code fix matches RFC. Task 2 bullet above amended to cite the RFC-faithful decimal source; Task 3 extended with AS-20 leaves (happy + revert + 18-decimal edge) on both concretes. `_enforceResidualTruncates`'s unused `GaslessCrossChainOrder memory order` parameter dropped (N3); back-to-back `if (outputIndex == 0)` blocks collapsed into `if/else` (N1); `uint256(18) - uint256(decimals_)` simplified to `18 - decimals_` (N2). Test spec amended with matching `Amendment 2026-04-24 (cycle-2)` note.

---

## PR 2: `fix/compute-order-digest-identity`

**Closes:** #41 (T5, code side)

**Diff from parent:** `compare/fix/as19-as21-ingress-gates...fix/compute-order-digest-identity`

`computeOrderDigest` currently omits `cellarIntentHash`, `rolloverHooks`, `premiumHooks`, `repaymentToken`, `repaymentAmount` — and (post-PR 1) must also include `minFillSize` and `exclusiveFiller`. Two semantically-distinct orders collide under the current digest. The RFC §A.8 "circular dependency" rationale for excluding `cellarIntentHash` is wrong (it's already a hash) — RFC amendment lands in PR 13.

### Task 5: Expand the digest hash

- [ ] Modify `contracts/libs/LibSettlerHashing.sol::computeOrderDigest` to include all of: `keccak256(abi.encode(rolloverHooks))`, `keccak256(abi.encode(premiumHooks))`, `repaymentToken`, `repaymentAmount`, `minFillSize`, `exclusiveFiller`. DO NOT include `cellarIntentHash`: because `CellarIntent.orderDigest = computeOrderDigest(od)` and `od.cellarIntentHash = keccak256(abi.encode(intent))`, binding it here creates a construction-time fixed point with no maker-computable solution. The RFC §A.8 "circular dependency" one-liner is right in its conclusion but wrong in its reasoning ("already a hash") — the actual reason is the fixed point. Collision defence from #41 is preserved because every `CellarIntent` field not derived from `orderDigest` (`orderSize`, `allowPartialFills`, `allowUnderfill`, `rolloverHooks`, `premiumHooks`, `expectedCaller`, `settler`, `deadline`) already appears directly in the digest (or is a function of fields that do — `settler` in chunk 1, `deadline = order.fillDeadline` in chunk 1, `expectedCaller` determined by `settler`). RFC §A.8 annotation lands in PR 13.
- [ ] Update the docstring comment listing the hashed fields — list them in the two concatenation chunks used by the code, not as a flat list (aligns with #57 which lands in PR 12 but should start correct here).
- [ ] The type hash string in `ORDER_DATA_TYPE_HASH` already covers these fields from PR 1; confirm the digest reads them through `keccak256(abi.encode(od))` or equivalent.

### Task 6: Tests + collision defence

- [ ] Extend `test/libs/LibSettlerHashing.t.sol`: new leaves asserting that two `OrderData` values differing only in each of the 5 previously-omitted fields produce distinct digests (5 new leaves).
- [ ] Add an integration leaf in `test/integration/RolloverLifecycle.t.sol` (or a new test file) exercising the pre-fix collision scenario from #41: two orders same-maker, different `rolloverHooks`, asserting that `orderIdOf[digest]` no longer aliases.

### Task 7: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `fix(libs): make computeOrderDigest identity-complete per RFC 003 issue #41`.
- [ ] Attempt push + PR creation against PR 1 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; digest-collision scenario from #41 is now caught by a failing-to-passing test.

**Amendment 2026-04-24 (cycle 1)**: §1g.5 **ENDORSE** on the `cellarIntentHash` exclusion. Reviewer verified the construction-time fixed-point reasoning against source: `CellarIntent.orderDigest = computeOrderDigest(od)` and `od.cellarIntentHash = keccak256(abi.encode(intent))`, so binding `cellarIntentHash` inside the digest produces `digest = f(cellarIntentHash) = f(keccak(intent(digest, ...)))` — a fixed point the maker cannot solve at construction time. This is a structural blocker, not the "already a hash" handwave in RFC §A.8. Collision defence from #41 is preserved: every `CellarIntent` field except `orderDigest` itself is either bound directly in the digest (`rolloverHooks`, `premiumHooks`, `orderSize`, `allowPartialFills`, `allowUnderfill`, `settler` via chunk 1, `deadline = order.fillDeadline` via chunk 1) or deterministically derived from fields that are (`expectedCaller` from `settler`). Task 5 bullet updated to match. RFC §A.8 annotation fix still lands in PR 13.

---

## PR 3: `fix/terminal-and-settler-symmetry`

**Closes:** #42 (T6), #53 (D-5)

**Diff from parent:** `compare/fix/compute-order-digest-identity...fix/terminal-and-settler-symmetry`

Settler refactor per #42 Option (a). Collapses the remaining load-bearing asymmetries between Exact and Partial into shared `BaseSettler` primitives, and unifies `dstCstProduced` storage width on `uint256` (#53). The other 3 issues the original bundle carried (#36 empty-fillers brick, #38 Partial premium-leg targetFiller, #51 Exact ZeroRollover guard) already landed via PR #65 — the refactor must **preserve** those guards when it moves them into the shared primitive.

This PR explicitly lifts the "BaseSettler frozen" rule from the prior `plan/implementation-plan.md` and re-freezes it after this PR lands.

### Task 8: Promote shared primitives onto `BaseSettler`

- [ ] In `contracts/settlers/BaseSettler.sol`, introduce three internal primitives:
  - `_recordFillerEscrow(orderDigest, filler, srcCstProvided, dstCstProduced, destination)` — writes to a common storage shape. Backing storage lives on the concrete, exposed via a virtual getter/setter pair.
  - `_lookupFillerEscrow(orderDigest, filler) returns (FillerEscrow)` — virtual; each concrete points it at its own mapping.
  - `_transitionIfTerminal(orderDigest, orderId)` — shared terminal-check implementation. Lifted out of `PartialFillSettler._maybeTransitionToTerminal`, extended so Exact's terminal path (single participant) is a special case of the same predicate. **MUST preserve the `participantCount == 0` early-return guard landed in `fafcf65`.**
- [ ] Unify `dstCstProduced` width on `uint256` across both settlers' storage structs (closes #53). Remove the `uint128(dstDelta)` narrowing cast in `ExactFillSettler._onRolloverLegFill`.
- [ ] The existing ZeroRollover guard (landed in `a438194`) stays where it is unless the refactor naturally folds it into a shared primitive — do not re-add as a new bullet; only ensure coverage stays green.
- [ ] The existing Partial premium-leg `targetFiller` guard (landed in `d7719c6`) and empty-fillers `InvalidFillers` revert (landed in `fafcf65`) stay in place after refactor — BTT must remain green for both.

### Task 9: BTT tree regeneration

- [ ] Regenerate `.tree` files affected by the refactor — rollover and premium leg trees on both concretes, plus the `finaliseAsSettled` trees. **New** tree files: `BaseSettler_lookupFillerEscrow.tree`, `BaseSettler_recordFillerEscrow.tree`, `BaseSettler_transitionIfTerminal.tree`. Storage-layout assertion leaves for the `uint256` width (×2, one per concrete).
- [ ] `bulloak scaffold` the updated trees; fill leaf bodies.
- [ ] The refactor MUST NOT regress existing BTT coverage — every pre-PR-3 green leaf remains green (including the #36/#38/#51 leaves from PR #65).

### Task 10: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"` (default profile).
- [ ] `forge build --sizes` — both settlers' sizes documented in PR body.
- [ ] Commit. If the refactor produces logically distinct chunks (e.g., primitive promotion vs storage-width unification), split into separate commits for reviewer clarity.
- [ ] Attempt push + PR creation against PR 2 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; uint256-width storage assertion leaves green; existing #36/#38/#51 BTT leaves remain green; BaseSettler.sol is re-frozen after merge.

---

## PR 4: `refactor/filler-pair-split`

**Closes:** #43 (T7)

**Diff from parent:** `compare/fix/terminal-and-settler-symmetry...refactor/filler-pair-split`

Split `RolloverFiller` (shared-singleton, caller-binding threat model) and `EvcRolloverAdapter` (per-subaccount threat model) from a 2-contract `IS_PARTIAL`-parametrised pair into 4 reference contracts per RFC §7.2/§7.3. Drop the `IS_PARTIAL` strategy bit — it unifies the wrong axis.

### Task 11: New file layout

- [ ] Create `contracts/fillers/ExactRolloverFiller.sol` — shared-singleton Exact filler. Inherits shared primitives via a new library (see Task 13), keeps the existing A2 caller-side `isOperator` check from `RolloverFiller.sol:107-109`.
- [ ] Create `contracts/fillers/PartialRolloverFiller.sol` — shared-singleton Partial filler. Same A2 check.
- [ ] Create `contracts/fillers/EvcExactFillAdapter.sol` — per-subaccount Exact adapter, with the EVC `onBehalfOfAccount` check from the existing `EvcRolloverAdapter`.
- [ ] Create `contracts/fillers/EvcPartialFillAdapter.sol` — per-subaccount Partial adapter.
- [ ] Delete `contracts/fillers/RolloverFiller.sol` and `contracts/fillers/EvcRolloverAdapter.sol`.

### Task 12: Shared primitives library

- [ ] Create `contracts/libs/LibFillerExecute.sol` containing the shared `fillerData` assembly, `openFor` dispatch, `finalise*` dispatch primitives. Libraries preserve code reuse **without** implying callers share a threat model (which was #43's core complaint).
- [ ] Each of the 4 new filler contracts imports from this library. The `IS_PARTIAL` switch remains inside each filler as a legitimate parameterization within a fixed threat model (per #43 suggested fix).

### Task 13: Trust boundary NatSpec

- [ ] Each of the 4 filler contracts carries a contract-level NatSpec block with a `@custom:threat-model` tag (dashed form — solc 0.8.30 rejects camelCase `@custom:threatModel` with `Error 2968: Invalid character in custom tag @custom:threatModel. Only lowercase letters and "-" are permitted.`) stating: threat model (`shared-singleton` vs `per-subaccount`), caller binding, and the reason splits exist (per #43). Runtime-asserted strings (`shared-singleton`, `per-subaccount`) are unchanged.

### Task 14: Tests + deploy script update

- [ ] Duplicate existing filler BTT coverage into 4 trees, one per new contract. Existing `test/filler/**` structure splits accordingly.
- [ ] Update `script/foundry-scripts/DeploySettlers.s.sol` (or the filler-specific deploy script if separate) to deploy 4 contracts instead of 2.
- [ ] EVC adapter invariants in `test/filler/evc/invariant/*` retarget to `EvcExactFillAdapter` + `EvcPartialFillAdapter` — no invariant logic changes, only the target.

### Task 15: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"` (default profile).
- [ ] Commit with message `refactor(fillers): split IS_PARTIAL pair into 4 reference contracts per RFC 7.2/7.3`.
- [ ] Attempt push + PR creation against PR 3 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; 4 filler contracts deployed from updated script; invariant suite green against new targets.

**Amendment 2026-04-25 (cycle 1):** PR #69 cycle-1 review verdict ACCEPT on the `@custom:threat-model` tag casing deviation from an earlier camelCase reference. Verified the solc 0.8.30 constraint by compiling a minimal `/// @custom:threatModel ...` contract: `Error (2968): Invalid character in custom tag @custom:threatModel. Only lowercase letters and "-" are permitted.` Task 13 above was updated to reflect the dashed form. Runtime-asserted tag strings (`shared-singleton`, `per-subaccount`) and `EXPECTED_THREAT_MODEL` public constants are unchanged.

---

## PR 5: `fix/token-quirk-defence`

**Closes:** #39 (T3)

**Diff from parent:** `compare/refactor/filler-pair-split...fix/token-quirk-defence`

Two remaining correlated token-behaviour paths produce silent cross-user fund-lock or permanent stuck-Opened state: FoT in `ERC6909Premium.settle`, and blacklist in `finaliseAsSettled/Refunded` payout loops. The deposit-side delta-accounting fix already landed via commit `0cdb91c` (A4 from PR #65) — this PR only picks up the settle-side and payout-loop work.

### Task 16: Settle-side delta accounting on `ERC6909Premium`

- [ ] Verify the existing deposit-side leaf (from `0cdb91c`) asserts fail-closed behaviour on a 1% FoT token. Add a BTT leaf only if one is missing.
- [ ] Add a fail-closed check inside `settle`: measure `balanceOf(recipient)` pre/post the final ERC-20 transfer and revert `SettleBalanceMismatch(expected, received)` if the recipient received less than `amount`. This closes the §39 settle-side FoT leak.

### Task 17: Try/catch in payout loops

- [ ] Modify `PartialFillSettler.finaliseAsSettled` inner loop: wrap the `dstCST.safeTransfer(f.destination, f.dstCstProduced)` in `try`/`catch`. On success, the usual flag flip. On revert, set `f.finalised = true` (still — the filler's slot is exhausted), AND credit the amount to a new `rescueable[orderDigest][filler]` mapping for later withdrawal via the PR 6 `rescueSettled` entry point. Emit `FillerRescueCredited(orderDigest, filler, amount, reason)`.
- [ ] Mirror on `finaliseAsRefunded` — `dstCST.safeTransfer(cellar, ...)` is maker-controlled, so try/catch is less valuable there; leave untouched and document the choice in NatSpec.
- [ ] The `rescueable` storage mapping lives on the concrete (since it's a Partial-specific path). On `ExactFillSettler`, `finaliseAsSettled` has a single transfer — wrap it in try/catch similarly, credit `rescueable[orderId][filler]`.

### Task 18: BTT coverage

- [ ] New tree leaves: settle-side FoT mismatch revert, blacklisted-destination rescue credit (Exact + Partial), multi-filler batch with one blacklisted destination (Partial). Deposit-side leaf exists — confirm presence only.
- [ ] Integration leaf: `test_e2e_usdcBlacklistMidOrder` in `test/integration/RolloverLifecycle.t.sol`.

### Task 19: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `fix(settler): delta-accounting on ERC6909 settle + blacklist-safe finalise (closes #39)`.
- [ ] Attempt push + PR creation against PR 4 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; the `rescueable` mapping is populated from the try/catch path; PR 6's `rescueSettled` entry point reads this mapping.

---

## PR 6: `feat/stranded-value-rescue`

**Closes:** #44 (T8)

**Diff from parent:** `compare/fix/token-quirk-defence...feat/stranded-value-rescue`

Adds `rescueSettled` per-filler pull path over the `rescueable` mapping introduced in PR 5. **New external surface — pre-check applies.**

### Task 20: Pre-check (new-external-surface rule)

- [ ] Read #44 "Suggested fix" section — confirm signature: `rescueSettled(bytes32 orderDigest, bytes32 orderId, address filler, address fallbackDestination, bytes calldata sig) external nonReentrant`.
- [ ] Trust boundary in NatSpec: caller is permissionless; authorization is via the filler's own signature over `(orderDigest, orderId, fallbackDestination)` under the settler's EIP-712 domain. Only recipients of their own `rescueable` balance can withdraw — settler never chooses destinations.
- [ ] List revert paths, one BTT leaf each.

### Task 21: Implement `rescueSettled`

- [ ] Add to `PartialFillSettler` and `ExactFillSettler` (concrete-specific because the storage mapping differs):
  - Verify `sig` over `keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination))` recovers to `filler` via `SignatureChecker.isValidSignatureNow`.
  - Verify `rescueable[orderDigest][filler] > 0` (or the Exact equivalent); revert `NothingToRescue` otherwise.
  - `SafeERC20.safeTransfer(dstCstToken, fallbackDestination, amount)`; zero the mapping before the transfer (CEI).
  - Emit `FillerRescueWithdrawn(orderDigest, filler, fallbackDestination, amount)`.
- [ ] Add `RESCUE_TYPEHASH` to the settler's domain.

### Task 22: BTT coverage

- [ ] Trees: `ExactFillSettler_rescueSettled.tree`, `PartialFillSettler_rescueSettled.tree`. Leaves: zero rescueable, bad sig, wrong signer, replay (sig already consumed — or document non-replay-safety and cap at single use via `rescueable` zeroing), happy path.
- [ ] Integration leaf linking the PR 5 FoT/blacklist credit to the PR 6 withdrawal: `test_e2e_rescueAfterBlacklistStrands`.

### Task 23: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `feat(settler): rescueSettled pull path for stranded filler escrow (closes #44)`.
- [ ] Attempt push + PR creation against PR 5 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; `rescueSettled` covered by BTT + integration; no admin functions introduced.

---

## PR 7: `fix/seam-as10-phase0`

**Closes:** #58 (I1)

**Diff from parent:** `compare/feat/stranded-value-rescue...fix/seam-as10-phase0`

Isolate premium-hook revert from premium-leg atomicity. A UW who signs conditionally-reverting `premiumHooks` currently converts N rollover-fillers' srcCST burns into a forced-refund windfall. Wrap the phase-1 forward in `try/catch`; on revert, emit `PremiumHooksReverted` and leave `premiumSettled=true` committed — UW owner recovers premium via `executeHooks(Call[])` out-of-band.

### Task 24: Wrap phase-1 forward in try/catch

- [ ] Modify `PartialFillSettler._onPremiumLegFill` and `ExactFillSettler._onPremiumLegFill`:
  - Keep `_settlePremium(...)` + `f.premiumSettled = true` before the forward.
  - Wrap `ICorkCellarFactory(factory).executeIntentHooks(cellar, orderDigest, 1, intent, cellarSig, targetFiller)` in `try` / `catch (bytes memory err)`.
  - On catch, emit `PremiumHooksReverted(orderDigest, targetFiller, err)`. Do not revert. Do not unwind `premiumSettled`.

### Task 25: Event + NatSpec

- [ ] Add `PremiumHooksReverted(bytes32 indexed orderDigest, address indexed targetFiller, bytes err)` to both settler interfaces.
- [ ] NatSpec on `_onPremiumLegFill` documents: "Phase-1 cellar callback is isolated in try/catch — UW-controlled premium hooks cannot brick the filler's settle path. UW recovers premium sitting at cellar via executeHooks."

### Task 26: BTT + integration

- [ ] New leaves on both concretes' `_onPremiumLegFill` trees: premium-hook-revert-emits-event, settler-state-unchanged-on-hook-revert, finaliseAsSettled-proceeds-after-hook-revert.
- [ ] Integration leaf `test_e2e_premiumHookConditionalRevert_noWindfall`.

### Task 27: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `fix(settler): try/catch phase-1 cellar forward to close AS-10 partial windfall (closes #58)`.
- [ ] Attempt push + PR creation against PR 6 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; the previous AS-10 windfall integration scenario is now blocked.

---

## PR 8: `fix/seam-cei-premium-leg`

**Closes:** #60 (I3)

**Diff from parent:** `compare/fix/seam-as10-phase0...fix/seam-cei-premium-leg`

Reorder the premium-leg writes in `PartialFillSettler._onPremiumLegFill` to match the hooks-then-commit discipline already used on the rollover leg. After PR 7's try/catch, the commit happens inside the catch's "success" branch.

### Task 28: Reorder writes

- [ ] In `PartialFillSettler._onPremiumLegFill`:
  - Order: `_settlePremium(...)` → `try _forwardToFactory(...) { f.premiumSettled = true; } catch { emit PremiumHooksReverted(...); f.premiumSettled = true; }`.
  - After PR 7's catch added `premiumSettled = true`, this PR keeps the same end-state but moves the write to happen explicitly after the forward (whether successful or caught). The rollover-leg ordering already works this way (forward-then-write at `:316-326`).
- [ ] Mirror on `ExactFillSettler._onPremiumLegFill`. The Exact path does not have per-filler premium slots — the `paymentSettled[orderId] = true` flip moves to after the forward.

### Task 29: BTT coverage

- [ ] New leaves exercising the explicit write-after-forward ordering: "when premium hooks succeed, premiumSettled writes after forward returns"; "when premium hooks revert under try/catch, premiumSettled still writes (committed via the catch branch per PR 7)".

### Task 30: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `fix(settler): reorder premium-leg writes to match hooks-then-commit discipline (closes #60)`.
- [ ] Attempt push + PR creation against PR 7 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; both legs of both settlers now use the same forward-then-write convention.

---

## PR 9: `feat/seam-state-parity-assertion`

**Closes:** #61 (I4), #63 (Integ M1)

**Diff from parent:** `compare/fix/seam-cei-premium-leg...feat/seam-state-parity-assertion`

Two issues, one PR. After `_forwardToFactory` returns on the premium leg, assert that cellar's `premiumFiredFor[d][targetFiller]` is set — catches silent drift (#61). Additionally, write `PREMIUM_FILLER_SLOT` transient from the settler before the forward so the cellar can cross-check (#63). **New external surface — pre-check applies (the `tstore` slot is a cross-contract ABI element).**

### Task 31: Pre-check (new-external-surface rule)

- [ ] Read #61 + #63 "Suggested fix" sections. Confirm: `PREMIUM_FILLER_SLOT` is a transient-storage slot constant (`keccak256("cork.rollover.premiumFiller") - 1` or similar), documented in both repos. Trust boundary: settler must write before forward; cellar must read and compare in `_runPremiumPhase`. Settler-side change lands here.
- [ ] NatSpec on the slot constant documents the contract it's read from (cellar).

### Task 32: State-parity assertion (#61)

- [ ] In both settlers' `_onPremiumLegFill`, after the `try`/`catch` block from PR 7 returns on the success branch:
  - `if (!ICorkCellarPremiumView(cellar).premiumFiredFor(orderDigest, targetFiller)) revert StateDivergence();`
  - Only on the success branch — on the catch branch, the hook didn't run so the cellar didn't latch; that's expected.
  - A narrow local interface (`contracts/interfaces/ICorkCellarPremiumView.sol`) is declared for `premiumFiredFor` because the vendored `lib/cellar/src/ICorkCellar.sol` does not expose it. Amended 2026-04-25 (cycle 1) from the original `ICorkCellar` reference.

### Task 33: `PREMIUM_FILLER_SLOT` transient write + view accessor (#63)

- [ ] Add a `bytes32 constant PREMIUM_FILLER_SLOT` on `BaseSettler`. The value is a settler-internal detail (see Amendment 2026-04-25 below); NatSpec documents its role as the transient-storage slot used by the view accessor.
- [ ] Before `_forwardToFactory` on both settlers' premium legs: `assembly { tstore(PREMIUM_FILLER_SLOT, pfd.targetFiller) }`.
- [ ] Expose a view `function premiumFillerSlot() external view returns (address)` on `BaseSettler` that `tload`s the settler's own slot and returns the value. The selector of this view — not the slot constant value — is the cross-repo ABI element.
- [ ] Cellar-side companion (lives in `cellar-private`, filed as a companion issue): `_runPremiumPhase` resolves the originating settler via `ICorkCellarFactory(msg.sender).originatingSettler()` (already `tload`-based per `lib/cellar/src/CorkCellarFactory.sol:109-114, 143`) and calls `premiumFillerSlot()` on it to cross-check the filler identity against the `filler` arg the factory relays. The slot read happens inside the settler's transient-storage scope via the view, not in the cellar's own scope.
- [ ] Document the cellar-side dependency in the PR body so reviewers know the full close-out requires coordination.

**Rationale for the view-accessor pattern over a direct cellar-side `tload`:** EIP-1153 transient storage is per-contract scoped. `tload(slot)` from address A returns a slot in A's own transient space. If the cellar directly `tload`-ed `PREMIUM_FILLER_SLOT`, it would read zero from its own untouched slot — the settler's write is invisible to the cellar's `tload` context. The view-accessor pattern is the EIP-1153-correct second form: settler `tstore`s its own slot, settler exposes a view that `tload`s its own slot, cellar calls the view cross-contract.

**Amendment 2026-04-25 (cycle 1):** Original Task 33 specified a direct cellar-side `tload(PREMIUM_FILLER_SLOT)` read. PR 9's implementation correctly reshaped this to the view-accessor pattern above; the reshape was flagged as a known deviation in the PR body. Review cycle 1 verdict: **ACCEPT**. The plan design was EIP-1153-incompatible (per-contract transient-storage scoping); the view accessor is the minimum correct form. Cross-repo ABI element is now the selector of `premiumFillerSlot()` plus the invariant that it returns the filler the settler advertised in the current phase-1 window — not the slot constant value, which is settler-internal.

### Task 34: BTT + integration

- [ ] New leaves: "when cellar premiumFiredFor[d][f] is false after successful forward → revert StateDivergence"; "when settler writes PREMIUM_FILLER_SLOT before forward".
- [ ] Integration leaf asserting the full seam from settler write → cellar read — gated on the cellar-side companion merging. Write the integration leaf as skipped (`vm.skip(true)`) with a comment linking the cellar issue if the cellar change has not landed at PR 9 execution time.

### Task 35: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `feat(settler): assert premiumFiredFor parity + write PREMIUM_FILLER_SLOT (closes #61, #63)`.
- [ ] Attempt push + PR creation against PR 8 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; state-divergence leaf is green under the new assertion; the skipped integration leaf is present with a tracking comment.

---

## PR 10: `feat/order-attribution-event`

**Closes:** #47 (M3), #46 (M2)

**Diff from parent:** `compare/feat/seam-state-parity-assertion...feat/order-attribution-event`

Single attribution event joining cellar-hook filler identity, ERC-6909 ledger identity, and settler event identity. Additionally, adds the token-choreography doc table and balance-floor invariant assertion from #46.

### Task 36: `OrderAttribution` event

- [ ] Add event to both settler interfaces: `OrderAttribution(bytes32 indexed orderId, address indexed fillerSlot, address indexed premiumFiller, address cellarFiller, uint256 tokenId, uint256 amount)`.
- [ ] Emit once per slot at `finaliseAsSettled` (both settlers) just before the transfer. `fillerSlot` is the slot the `rescueable` mapping keys on; `premiumFiller` comes from the settler's own records; `cellarFiller` is the value the cellar sees (read via `ICorkCellar.premiumFiller`-equivalent if exposed, else derived from `premiumFiredFor` iteration — use the simplest accurate source).

### Task 37: Token-choreography doc table (#46)

- [ ] Add a top-of-file doc-comment table to `contracts/settlers/BaseSettler.sol`: 4–6 lines, columns `phase × actor × token held`. Structure: phase-0 (rollover leg), phase-1 (premium leg), finalise. Rows name which actor holds which token at each phase.
- [ ] Add one invariant assertion in `finaliseAsSettled` after the transfer loop: `require(IERC20(dstCstToken).balanceOf(address(this)) >= remainingEscrow);` where `remainingEscrow` is the per-order `totalDstCstEscrowed - justDistributed`. Catches silent-siphon refactors.

### Task 38: BTT + invariant coverage

- [ ] New leaves on `finaliseAsSettled` trees: event-emission correctness, identity-join assertion (the 3 filler identities match on the happy path, diverge from recorded history on the pre-PR 3 drift scenarios which are now blocked).
- [ ] New invariant `SINV_attributionEvent` / `PINV_attributionEvent`: every successful settle emits exactly one `OrderAttribution` per filler slot with matching identities.

### Task 39: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `feat(settler): emit OrderAttribution + add balance-floor invariant (closes #47, #46)`.
- [ ] Attempt push + PR creation against PR 9 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; attribution event on every settle; balance-floor invariant green.

---

## PR 11: `docs/filler-trust-boundary`

**Closes:** #49 (L1), #64 (Integ M4)

**Diff from parent:** `compare/feat/order-attribution-event...docs/filler-trust-boundary`

Documentation-only PR. Captures (a) the settler's trust boundary on maker-controlled `cellar.hookNonces[digest]` (#49 option a, minimum intervention), and (b) the atomic-revert invariant that future non-forwarding settler variants would violate (#64).

### Task 40: `BaseSettler.sol` doc-comment additions

- [ ] Above `_transitionIfTerminal` (or the equivalent Partial-specific helper): multi-line NatSpec documenting that the terminal dispatch reads `cellar.hookNonces(orderDigest) & 1` and that the correctness of the Settled-vs-Refunded choice depends on the cellar honouring INV-C14. Cross-reference the RFC §9.2 filler trust-boundary table.
- [ ] Above `_forwardToFactory`: multi-line NatSpec per #64: "state-modifying writes in `_onRolloverLegFill` / `_onPremiumLegFill` MUST precede this call. Factory blocklist enforcement depends on atomic revert through this forward — any future variant that removes or defers the forward must implement its own blocklist awareness."

### Task 41: Integration test (optional per #64)

- [ ] Add `test/integration/BlockedSettlerRevertsAllWrites.t.sol` — one test asserting that when the factory has the settler blocklisted, the forward reverts and all prior same-tx writes roll back.

### Task 42: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `docs(settler): document cellar trust boundary and atomic-revert invariant (closes #49, #64)`.
- [ ] Attempt push + PR creation against PR 10 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; NatSpec present on both call sites; integration test green.

---

## PR 12: `fix/deploy-and-adapter-cleanup`

**Closes:** #54 (D-6), #55 (D-7), #56 (D-8), #57 (D-9)

**Diff from parent:** `compare/docs/filler-trust-boundary...fix/deploy-and-adapter-cleanup`

Four small cleanups bundled because each is <20 LoC and all touch deploy-adjacent surface.

### Task 43: Remove `.COWShedFactory.` fallback (#54)

- [ ] In `script/foundry-scripts/DeploySettlers.s.sol`, delete the `COWShedFactory` fallback path. The deploy script now requires `networks.json[CorkCellarFactory][chainId]` or the `FACTORY_ADDRESS_OVERRIDE` env var; any missing key reverts at deploy time.
- [ ] Update the NatSpec on `_resolveFactoryAddress` to reflect the simpler resolution order: env override → `CorkCellarFactory` key. Revert otherwise.

### Task 44: Update `computeOrderDigest` docstring (#57)

- [ ] In `contracts/libs/LibSettlerHashing.sol`, update the docstring above `computeOrderDigest` to present the 19 hashed fields in the two concatenation chunks the code actually uses (`first` / `second`), not a flat list.

### Task 45: EVC adapter NatSpec (#55, #56)

- [ ] On `EvcExactFillAdapter` (post-PR 4 split): document the 4-immutable design (`SETTLER`, `EVC`, `IS_PARTIAL`, `FACTORY`) and why it differs from the RFC §7.3 2-immutable pseudocode. Reference #55 and note that the RFC pseudocode update lands in cork-knowledge (out of scope for this plan — track separately).
- [ ] Tighten `controllerToCheck` in the EVC auth check: accept a constructor arg `_controllerToCheck` stored as immutable; assert `controllerEnabled == true` for that controller (closes #56 hardening option). If the team prefers documentation over code change here, leave the code at `address(0)` and document the choice instead.

### Task 46: Commit + push

- [ ] `forge fmt` + `mise fmt-check`.
- [ ] `forge test -vvv`.
- [ ] `forge test --match-contract "*Invariant*"`.
- [ ] Commit with message `fix(deploy+adapter): cleanup D-6/D-7/D-8/D-9 per RFC 003 issues`.
- [ ] Attempt push + PR creation against PR 11 branch. On failure, record in `plan/pending-branches.md`.

**Gate:** `forge test` all pass; deploy script's single-resolution-path asserted by a new deploy fixture test.

---

## PR 13: `docs/cork-knowledge-rfc-amendment` (CROSS-REPO, NON-BLOCKING)

**Closes:** #41 (RFC side), #48 (M4)

**Repo:** `cork-knowledge` (not this repo)
**Worktree:** `../cork-knowledge-rfc-a8-amendment/`
**Branch:** targets `cork-knowledge` branch `rfc/uw-intent-rollover-003`

This PR lands in a separate repository. It **must not block** the rollover-phoenix-private stack's execution. If PR 12 has merged and PR 13 is still pending, the rollover-side work is shippable as-is.

### Task 47: Set up worktree

- [ ] `git -C ../cork-knowledge worktree add ../cork-knowledge-rfc-a8-amendment rfc/uw-intent-rollover-003` — creates the worktree at a sibling directory of the cork-knowledge checkout.
- [ ] Verify the branch `rfc/uw-intent-rollover-003` exists on the cork-knowledge remote.

### Task 48: Amend RFC §A.8

- [ ] Edit `rfcs/003-underwriter-rollover-intent.md` inside the worktree:
  - §A.8: expand `computeOrderDigest` definition to include `cellarIntentHash`, `keccak256(abi.encode(rolloverHooks))`, `keccak256(abi.encode(premiumHooks))`, `repaymentToken`, `repaymentAmount`, `minFillSize`, `exclusiveFiller`.
  - Delete the "circular dependency" paragraph justifying `cellarIntentHash`'s exclusion — it's wrong (the hash is already a hash).
  - §A.3: confirm field list matches the post-PR 1 schema (19 fields).

### Task 49: Decision record for #48

- [ ] Create `cork-knowledge/decisions/2026-04-<NN>-rfc003-ship-as19-as21.md` with:
  - **Decision:** AS-19/20/21 fields and gates ship in rollover-phoenix-private per PR 1.
  - **Rationale:** RFC §6.2 explicitly specifies them; previously deferred framing was an anchor.
  - **Task references:** rollover-phoenix-private #37, #45.
  - **Signed off by:** Filip.
- [ ] Add a one-line entry to `cork-knowledge/decisions/INDEX.md` if that index exists.

### Task 50: Commit, push, clean up worktree

- [ ] In the worktree: commit with message `docs(rfcs): RFC 003 §A.8 digest amendment + AS-19/20/21 decision record`.
- [ ] Push the branch; open the PR against `rfc/uw-intent-rollover-003`.
- [ ] After the PR is open (URL captured), clean up the worktree: `git worktree remove ../cork-knowledge-rfc-a8-amendment` from the cork-knowledge checkout.

**Gate:** the cork-knowledge PR is open; the worktree is removed; rollover-side stack is not blocked waiting for this PR to merge.

---

## execute-cork Execution Schedule

| Run | PR | Tasks | Gate |
|---|---|---|---|
| 1 | PR 1 | 1–4 | `forge test` + invariants green; new AS-19/20/21 leaves green |
| 2 | PR 2 | 5–7 | `forge test` all pass; digest collision leaves green |
| 3 | PR 3 | 8–10 | `forge test` all pass; uint256-width assertion green; #36/#38/#51 BTT leaves remain green |
| 4 | PR 4 | 11–15 | `forge test` all pass; 4 filler contracts deploy correctly |
| 5 | PR 5 | 16–19 | `forge test` all pass; rescueable populated on try/catch path |
| 6 | PR 6 | 20–23 | `forge test` all pass; `rescueSettled` BTT + integration green |
| 7 | PR 7 | 24–27 | `forge test` all pass; AS-10 windfall scenario blocked |
| 8 | PR 8 | 28–30 | `forge test` all pass; both legs use hooks-then-commit |
| 9 | PR 9 | 31–35 | `forge test` all pass; state-parity assertion green |
| 10 | PR 10 | 36–39 | `forge test` all pass; attribution event + balance-floor invariant green |
| 11 | PR 11 | 40–42 | `forge test` all pass; blocked-settler integration test green |
| 12 | PR 12 | 43–46 | `forge test` all pass; deploy fixture test green |
| 13 | PR 13 | 47–50 | cork-knowledge PR open; worktree removed |

**Total: 13 runs, strictly sequential. No cross-PR parallelism.**

### Merge order

1–12: merge each in order to `main`, rebase the next on `main`, merge. If PR 13 is not yet merged at the end, the rollover-side stack is complete — note the open cork-knowledge PR URL in the final summary.

### Rebase discipline between PRs

Each PR rebases on the current `main` tip after its parent merges. Standard workflow:

```bash
git fetch origin
git checkout <branch>
git rebase origin/main
# resolve conflicts
git push --force-with-lease
```

Never use `--no-verify` to skip hooks.
