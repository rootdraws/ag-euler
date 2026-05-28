# Rollover Settlers Implementation Plan

> **Execution method:** `execute-cork` skill — one Opus agent run per PR, sequential across PRs. Each PR is one execute-cork run; within a run, multiple agents may dispatch in parallel for file-level work on one task, but never across tasks.
>
> **Discipline:** TDD per chunk — each sub-PR writes failing tests first, then implementation to make them pass. Test and implementation ship together in one reviewable unit.
>
> **Test details:** See `plan/test-spec.md` for the full BTT tree inventory, leaf counts, invariant matrix, mock policy, and infrastructure design. This plan covers only execution steps, source-side changes, and dependency ordering.

**Goal:** Deliver the three settler contracts specified in RFC 003 (`003-underwriter-rollover-intent.md`) and the dual-settler extension (`003-partial-fill-dual-settler.md`) — `BaseSettler` (abstract), `ExactFillSettler`, `PartialFillSettler` — plus the standalone `ERC6909Premium` prepaid-balance contract. All four deploy against the existing `CorkCellar` / `CorkCellarFactory` in `lib/cellar`. No changes to cellar-private; all new code lives in `rollover-phoenix-private/contracts/`.

**Architecture:** Shared `BaseSettler` abstract holds the primitives that do not branch on fill semantics (EIP-712 domain construction, `_recover` for ECDSA + ERC-1271, `_forwardToFactory` for the `settler → factory → cellar` hop, `_settlePremium` for ERC-6909 debit). Two concrete settlers inherit `BaseSettler`: `ExactFillSettler` for the one-fill-per-order RFC 003 baseline and `PartialFillSettler` for cumulative multi-filler orders with per-filler state. Both ERC-7683-compatible via `IOriginSettler` + `IDestinationSettler`. `ERC6909Premium` is ownerless, immutable, no pause — fillers deposit payment tokens ahead of fill, settlers debit via `settle()` under dual authorization.

**Tech stack:** Solidity 0.8.30 (matches cellar-private), Foundry, OpenZeppelin (SafeERC20, ECDSA via SignatureChecker, Ownable2Step where applicable), solady (LibClone not used here but inherited through cellar), bulloak for BTT scaffolding. Real rhinestone `Registry` and Cork Phoenix pool manager via cellar's `BaseTestCorkCellar`.

**Source of truth:** RFC `003-underwriter-rollover-intent.md`, RFC `003-partial-fill-dual-settler.md`, BTT `.tree` files (co-located in `test/{base,exact,partial,erc6909,libs}`), and `plan/test-spec.md`.

---

## Coding conventions (hard rules)

Apply to every contract, test, and script in this plan. These override any looser interpretation that could be inferred from the surrounding code.

- **No `unchecked` blocks** unless an inline comment explicitly justifies the bound (e.g., a loop counter with a compile-time ceiling).
- **Custom errors only.** No string reverts, no `require(..., "msg")`. Every revert carries a typed error.
- **OpenZeppelin first.** Prefer `SafeERC20`, `ECDSA`, `SignatureChecker`, `Math`, `ReentrancyGuard`, `Ownable2Step`, `TimelockController`. Do not reimplement anything OZ already ships.
- **No bespoke timelocks.** If any function needs timelock gating, use `TimelockController` and mark the function with a NatSpec `@dev` line identifying it as timelock-gated.
- **One interface per file.** Events and custom errors live on the interface, not the implementation. Implementations import the interface and re-use its error/event types.
- **Detailed NatSpec on every interface.** `@notice`, `@param`, `@return`, and `@dev` where state transitions or revert conditions are non-obvious. **The agent drafts NatSpec and confirms with the user before committing it.** Interface NatSpec does not land without explicit approval.
- **Immutables at contract scope.** Anything set once in the constructor is `immutable` and declared as a top-level state variable. Do not inline constants into function bodies — lift them to contract-scope `constant` / `immutable` fields.
- **No mocks for protocol integrations.** Deploy real contracts as test fixtures. Phoenix + cellar flow through `BaseTestCorkCellar`. The one allowed mock is `MockBaseSettler` — a minimal concrete used to exercise the abstract base's internal primitives. If any other external protocol needs a test double, stop and ask before writing it.
- **Compact, readable code layout.** Group by responsibility; separate groups with a single blank line used as a logical section break. Delete dead code; never leave commented-out blocks. No trailing whitespace.
- **Solidity 0.8.30**; pragma line matches cellar-private.

## Execution conventions (hard rules)

- **Sequential tasks, not parallel.** One task completes before the next starts. Parallel agents can dispatch **within a single task** (e.g., multiple files under one task) but never across tasks — agents step on shared state. This overrides any `4c ∥ 4d` directive that may appear elsewhere in this plan; flip to `4c → 4d`.
- **Post-task compliance re-check.** After every task's `forge build` + scoped `forge test` pass, re-read the task body, diff against the produced code and tests, and re-verify cited RFC / test-spec sections. Report any divergence before dispatching the next task. If the plan is wrong, stop and raise it — do not silently deviate.
- **State the goal before acting.** Every agent dispatch begins with a one-sentence statement of the task and its success criteria. No speculative changes outside the stated goal.
- **TDD per chunk.** Scaffold `.t.sol` from the `.tree` file first, fail visibly, then write implementation. Tests and implementation ship in one reviewable commit.

---

## Stacked PR Strategy

4 top-level stacked PRs. **PR 4 is split into 5 sub-PRs** ordered by dependency. Each sub-PR contains both tests and implementation for its domain — one reviewable unit per chunk.

| PR | Name | Base | Description |
|---|---|---|---|
| **PR 1** | `chore/bump-solc-and-add-cellar-submodule` | `main` | Bump Solc → 0.8.30, EVM → prague. Add `lib/cellar` submodule. Update `remappings.txt`. Pragma-bump all files that already exist (currently only test/helpers stubs if any; `contracts/` is empty). |
| **PR 2** | `feat/settler-interfaces-and-libs` | PR 1 | ERC-7683 interfaces, Cork-specific interfaces, `LibRolloverOrder` (encode/decode), `LibSettlerHashing` (orderId, orderDigest, outputHash). Reverting stubs only for `BaseSettler`, `ExactFillSettler`, `PartialFillSettler`, `ERC6909Premium`. **Zero protocol logic.** Tests for both libraries ship in this PR. |
| **PR 3** | `feat/erc6909-premium` | PR 2 | Standalone `ERC6909Premium` — tests + implementation. Ownerless, immutable, no pause. Dual-auth `settle()`. Independent of settler contracts. |
| **PR 4** | `feat/settlers` | PR 3 | **Tests + implementation for the three settlers.** Integration branch with 5 sub-PRs ordered by dependency (see below). |

### PR 4 sub-PR structure

PR 4 has an **integration branch** (`feat/settlers`). Sub-PRs merge into it sequentially, ordered by dependency. Each sub-PR ships tests + implementation together.

```
main
 └── PR 1: chore/bump-solc-and-add-cellar-submodule
      └── PR 2: feat/settler-interfaces-and-libs
           └── PR 3: feat/erc6909-premium
                └── PR 4: feat/settlers                      ← integration branch
                     ├── PR 4a: feat/settler-test-infra       ← merge first (test infra only)
                     ├── PR 4b: feat/settler-base             ← depends on 4a
                     ├── PR 4c: feat/settler-exact            ← depends on 4a, 4b
                     ├── PR 4d: feat/settler-partial          ← depends on 4a, 4b, 4c (sequential)
                     └── PR 4e: feat/settler-integration      ← depends on 4c, 4d (last)
```

**Dependency graph:**
```
4a (test infra, BaseTestSettler + lib test harness)
 └── 4b (BaseSettler abstract + MockBaseSettler harness + 26 leaves)
      ├── 4c (ExactFillSettler: 71 leaves + impl)
      │    └────────────────┐
      ├── 4d (PartialFillSettler: 94 leaves + impl)  ← depends on 4c (sequential)
      │    └────────────────┤
      └─────────────────── 4e (15 integration + 29 invariant + deploy script)
```

**Merge order:** 4a → 4b → 4c → 4d → 4e

### PR description templates

**PR 4 integration branch description:**
```markdown
## Stack Position: 4/4 `feat/settlers`
**Base:** `feat/erc6909-premium` (PR 3)
**Diff from parent:** [compare](../../compare/feat/erc6909-premium...feat/settlers)

## Sub-PRs (review individually, merge in dependency order)
| # | Sub-PR | Depends On | Tests | Implementation | Status |
|---|---|---|---|---|---|
| 4a | `feat/settler-test-infra` | — | `BaseTestSettler` + 22 library leaves | — (infra + libs) | ... |
| 4b | `feat/settler-base` | 4a | 26 BaseSettler leaves | `BaseSettler.sol` + `MockBaseSettler.sol` | ... |
| 4c | `feat/settler-exact` | 4a, 4b | 71 ExactFillSettler BTT | `ExactFillSettler.sol` | ... |
| 4d | `feat/settler-partial` | 4a, 4b | 94 PartialFillSettler BTT | `PartialFillSettler.sol` | ... |
| 4e | `feat/settler-integration` | 4c, 4d | 15 integration + 29 invariant | `script/foundry-scripts/DeploySettlers.s.sol` | ... |

Merge order: 4a → 4b → 4c → 4d → 4e
```

**Sub-PR description template (e.g., PR 4c):**
```markdown
## Sub-PR: `feat/settler-exact`
**Base:** `feat/settlers` (PR 4 integration branch)
**Diff from base:** [compare](../../compare/feat/settlers...feat/settler-exact)
**Depends on:** PR 4a `feat/settler-test-infra`, PR 4b `feat/settler-base`
**Tests:** 71 ExactFillSettler BTT tests (see test spec §5)
**Implementation:** `contracts/settlers/ExactFillSettler.sol`
**Gate:** `forge test --match-path "test/exact/*"` — all pass
```

### Stacked PR Workflow

```bash
# Top-level stack
gh pr create --base <parent-branch> --title "PR N: ..."

# Sub-PRs: each targets the integration branch
gh pr create --base feat/settlers --title "PR 4c: feat/settler-exact"

# After merging a top-level parent:
git checkout <child-branch> && git rebase main
gh pr edit <child-PR> --base main
```

### Offline push deferral (fallback)

If `git push` or `gh pr create` fails for any reason — SSH key not loaded in the agent environment, `gh auth` missing, network unreachable, 2FA prompt, rate limit — **do NOT block or try destructive workarounds**. Continue locally:

1. **Keep branching and committing against local tips.** `git checkout -b <next-branch>` off the local parent tip works identically whether the parent has been pushed or not. The stack remains coherent on the local clone.
2. **Run all gates locally** (`forge build`, `forge test --match-path ...`, compliance re-check). They are authoritative regardless of push state.
3. **Append a row to `plan/pending-branches.md` after every affected commit.** Columns: branch name, parent branch (PR target), last commit SHA, gate status, suggested PR title, suggested PR body. Treat the file as an append-only log — never delete rows, even after a later push succeeds (keeps audit trail).
4. **At the end of the run, surface `plan/pending-branches.md`** and tell the user: "N branches ready to push; credentials failed on attempt — see file." Then stop. Do not retry credentials; do not open a second terminal; do not alter remotes.

The user (or a session with credentials) will run:
```bash
git push -u origin <branch>
gh pr create --base <parent> --title "<from file>" --body "<from file>"
```

If a failure trips mid-stack (say, PR 2 pushes fine but PR 3 doesn't), subsequent sub-PRs still branch off the local PR 3 tip. Stack ordering is preserved; once the user pushes PR 3, the later PRs' targets resolve on GitHub exactly as planned.

**Never** attempt: `--force`, rewriting commits that were pushed, changing `origin` URL, switching from SSH to HTTPS mid-run, or deleting `.git/config` entries. These are destructive workarounds and out of scope.

### Branch names
```
# Top-level stack
chore/bump-solc-and-add-cellar-submodule  (PR 1, base: main)
feat/settler-interfaces-and-libs          (PR 2, base: PR 1)
feat/erc6909-premium                      (PR 3, base: PR 2)
feat/settlers                             (PR 4, base: PR 3)

# PR 4 sub-branches (all target feat/settlers)
feat/settler-test-infra                   (PR 4a, merge first)
feat/settler-base                         (PR 4b, after 4a)
feat/settler-exact                        (PR 4c, after 4a+4b)
feat/settler-partial                      (PR 4d, after 4c)
feat/settler-integration                  (PR 4e, after 4c+4d, last)
```

---

## Source files changed per PR

### Added (PR 2)
- `contracts/interfaces/IOriginSettler.sol` (ERC-7683 verbatim)
- `contracts/interfaces/IDestinationSettler.sol` (ERC-7683 verbatim)
- `contracts/interfaces/IExactFillSettler.sol`
- `contracts/interfaces/IPartialFillSettler.sol`
- `contracts/interfaces/IERC6909Premium.sol`
- `contracts/libs/LibRolloverOrder.sol`
- `contracts/libs/LibSettlerHashing.sol`
- `contracts/settlers/BaseSettler.sol` (stub — abstract, revert-on-external)
- `contracts/settlers/ExactFillSettler.sol` (stub — revert)
- `contracts/settlers/PartialFillSettler.sol` (stub — revert)
- `contracts/erc6909/ERC6909Premium.sol` (stub — revert)

### Populated (PR 3)
- `contracts/erc6909/ERC6909Premium.sol` (full implementation)

### Populated (PR 4 sub-PRs)
- `contracts/settlers/BaseSettler.sol` (PR 4b)
- `contracts/settlers/ExactFillSettler.sol` (PR 4c)
- `contracts/settlers/PartialFillSettler.sol` (PR 4d)
- `script/foundry-scripts/DeploySettlers.s.sol` (PR 4e)

### Test files (by PR)
See test-spec §13 for the full file layout.

- **PR 2:** `test/libs/LibRolloverOrder.t.sol`, `test/libs/LibSettlerHashing.t.sol` — scaffolded against stubs, green once libs land.
- **PR 3:** `test/erc6909/*.t.sol` + `.tree` files.
- **PR 4a:** `test/BaseTestSettler.sol` (harness) + any test helpers this needs.
- **PR 4b:** `test/base/*.t.sol` + `.tree` files + `test/base/MockBaseSettler.sol`.
- **PR 4c:** `test/exact/*.t.sol` + `.tree` files.
- **PR 4d:** `test/partial/*.t.sol` + `.tree` files.
- **PR 4e:** `test/integration/RolloverLifecycle.t.sol`, `test/invariant/*.t.sol` + handlers.

---

## PR 1: `chore/bump-solc-and-add-cellar-submodule`

### Task 1: Bump pragma and EVM

- [ ] Update `foundry.toml`: `solc = "0.8.30"`, `evm_version = "prague"`, `via_ir = true`, `optimizer_runs = 1_000_000` (match cellar-private).
- [ ] Remove any references to Solc 0.8.26 / cancun in CI scripts, Hardhat config, README.
- [ ] `forge build` on the empty `contracts/` — succeeds trivially.
- [ ] Update `package.json` scripts if they pin a compiler version.

### Task 2: Add `lib/cellar` submodule

- [ ] `forge install Cork-Technology/cellar-private@<pinned-SHA>` — pin to the latest reviewed `develop` SHA (resolve before dispatch and record in the PR body).
- [ ] `forge install` places the submodule at `lib/cellar-private`. Rename to the canonical path used throughout this plan: `git mv lib/cellar-private lib/cellar && git submodule sync -- lib/cellar`. Update the `.gitmodules` entry's `path =` line if `git mv` did not.
- [ ] `git submodule update --init --recursive` — fetch cellar's transitive submodules (`forge-std`, `openzeppelin-contracts`, `phoenix`, `registry`, `solady`) under `lib/cellar/lib/...`. `forge install` is shallow by default; this step is still required for the nested fetch.
- [ ] **Keep `lib/openzeppelin-contracts` and `lib/forge-std` as rollover-side root submodules.** Rollover contracts import OZ directly (`SafeERC20`, `ReentrancyGuard`, `SignatureChecker`, `ECDSA`, `Math`, `Ownable2Step`, `TimelockController`); the rollover repo owns its OZ pin independently so cellar-internal OZ bumps don't force rollover upgrades. Same argument for `forge-std`. The only root submodule to drop is `openzeppelin-contracts-upgradeable`, which is unused (this repo ships no upgradeable contracts):
  ```
  forge remove openzeppelin-contracts-upgradeable
  ```
- [ ] Ensure rollover's `lib/openzeppelin-contracts` pin is >= cellar's transitive OZ pin (or identical). If cellar pins a newer OZ major than rollover carries, bump rollover's root OZ before merging PR 1 — otherwise cellar test helpers compiled against the newer OZ will fail to link against rollover's older types. Record both pins in the PR body.
- [ ] Rewrite `remappings.txt` per test-spec §2.2. Rollover-owned deps resolve at the repo root; cellar-owned deps resolve under `lib/cellar/`. Minimum set:
  ```
  forge-std/=lib/forge-std/src/
  @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
  cellar/=lib/cellar/contracts/
  cellar-test/=lib/cellar/test/
  phoenix/=lib/cellar/lib/phoenix/contracts/
  solady/=lib/cellar/lib/solady/src/
  ```
  Verify the exact subpath names (`phoenix/contracts`, `solady/src`, etc.) against the pinned cellar SHA's actual `lib/` layout before finalising. If cellar exposes additional helpers (e.g. `rhinestone-registry/`), add them here.
- [ ] `forge build` — still succeeds with the rewritten remap set.
- [ ] Add a `docs/submodules.md` (or README section) documenting the submodule pinning policy from test-spec §2.2: cellar bumps ship as standalone PRs titled `chore(deps): bump lib/cellar to <short-SHA>`, CI caches keyed on the pinned SHA. Note that rollover's root `lib/openzeppelin-contracts` and `lib/forge-std` pins are separate and bumped independently.
- [ ] Commit all. Attempt push + PR creation against `main`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge build` passes; `git submodule status` shows `lib/cellar` at the pinned SHA plus `lib/openzeppelin-contracts` and `lib/forge-std` still present at the rollover-repo root; `openzeppelin-contracts-upgradeable` is gone.

---

## PR 2: `feat/settler-interfaces-and-libs`

**Diff from parent:** `compare/chore/bump-solc-and-add-cellar-submodule...feat/settler-interfaces-and-libs`

Creates the compilation surface for tests. **Zero settler logic** — only interfaces, types, libraries, and reverting stubs. Library tests are part of this PR because the libraries are self-contained and have no external dependencies.

### Task 3: ERC-7683 interfaces

- [ ] Add `contracts/interfaces/IOriginSettler.sol` — verbatim from EIP-7683 spec: `open`, `openFor`, `resolve`, `resolveFor`, `Open` event, `ResolvedCrossChainOrder` / `Output` / `FillInstruction` structs.
- [ ] Add `contracts/interfaces/IDestinationSettler.sol` — `fill(bytes32 orderId, bytes originData, bytes fillerData)` verbatim.
- [ ] Re-export ERC-7683 structs (`OnchainCrossChainOrder`, `GaslessCrossChainOrder`) inside a shared types file (`contracts/interfaces/IRolloverTypes.sol`) so settlers can import one path.

### Task 4: Cork-specific interfaces

- [ ] `contracts/interfaces/IExactFillSettler.sol` — extends `IOriginSettler` + `IDestinationSettler` + declares `finaliseAsSettled(orderId)`, `finaliseAsRefunded(orderId, order)`, `finaliseAsCancelled(orderId, order, cancelSig)`, custom errors, events.
- [ ] `contracts/interfaces/IPartialFillSettler.sol` — same ERC-7683 surface plus `finaliseAsSettled(orderDigest, fillers[])`, `finaliseAsRefunded(orderDigest, order, fillers[])`, `finaliseAsCancelled(orderId, order, cancelSig)`, view getters `fillerRollovers(orderDigest, filler)` and `totalDstCstEscrowed(orderDigest)`, `FillerRollover` struct, custom errors, events.
- [ ] `contracts/interfaces/IERC6909Premium.sol` — `deposit`, `withdraw`, `settle`, `setOperator`, `balanceOf`, `isOperator`, `supportsInterface`, `Settled` event, custom errors.

### Task 5: `LibRolloverOrder`

- [ ] Add `contracts/libs/LibRolloverOrder.sol`:
  - `OrderData` struct matching test-spec §2.5 (no `minFillRatio`; includes `cellarIntentHash`). `OrderData` carries `Output[] outputs`, `Call[] rolloverHooks`, `Call[] premiumHooks`, `bytes cellarSignature` nested per RFC 003 §A.3 — the CellarIntent is reconstructed from these fields + the cellar-signed deadline/orderDigest/expectedCaller/settler on the Exact path.
  - `RolloverFillerData { address destination; }` — Exact rollover leg (RFC 003 §A.10). `outputIndex` prefix stripped at call site.
  - `PremiumFillerData { address debitFrom; }` — Exact premium leg (RFC 003 §A.10).
  - `PartialFillerData { address destination; address debitFrom; address targetFiller; CellarIntent intent; bytes cellarSig; }` — Partial both legs (extension §5.4). The Partial path carries `intent`+`cellarSig` in `fillerData` per extension rationale; the Exact path does NOT — it reconstructs them from `OrderData`.
  - `OriginFillerData { uint256 outputAmount; address repaymentTo; }` — `openFor` hook (RFC 003 §A.11).
  - `encode*` / `decode*` helpers for each.
  - `extractCellarIntentFromOrderData(OrderData od, GaslessCrossChainOrder order) returns (CellarIntent intent, bytes cellarSig)` — Exact-path helper that constructs the `CellarIntent` struct from `od.rolloverHooks`, `od.premiumHooks`, `od.cellarSignature`, `order.fillDeadline`, plus `expectedCaller=factory` and `settler=address(this)` known to the settler, and the orderDigest computed via `LibSettlerHashing.computeOrderDigest`.
- [ ] `test/libs/LibRolloverOrder.t.sol` — round-trip fuzz tests + differential against reference encoders + the Exact `extractCellarIntentFromOrderData` → `keccak256(abi.encode(intent)) == od.cellarIntentHash` equality check (10 leaves per test-spec §8).

### Task 6: `LibSettlerHashing`

- [ ] Add `contracts/libs/LibSettlerHashing.sol`:
  - `computeOrderId(GaslessCrossChainOrder)` — RFC 003 §A.7 (9-field hash with `keccak256(orderData)`).
  - `computeOrderDigest(GaslessCrossChainOrder, OrderData)` — RFC 003 §A.8 (19-field non-recursive hash).
  - `computeOutputHash(Output)` — RFC 003 §A.6.
  - `ORDER_DATA_TYPE_HASH` constant matching test-spec §2.5.
  - `CORK_ROLLOVER_ORDER_TYPE = keccak256("CorkRolloverOrder_v1")` per RFC 003 §A.2.
- [ ] `test/libs/LibSettlerHashing.t.sol` — 12 leaves: each hash independently, differential against hand-computed vectors, stability across semantically-equivalent inputs.

### Task 7: Stub BaseSettler + concretes + ERC-6909

These stubs are **frozen for PR 2 only**. The canonical BaseSettler interface is defined in PR 4b Task 13; PR 2 publishes a thin shape that compiles but reverts on every entry point. Sub-PRs 4c and 4d MAY NOT modify `BaseSettler.sol`.

- [ ] `contracts/settlers/BaseSettler.sol` — abstract:
  - Constructor: `(address factory_, address erc6909Premium_)` — exactly two immutables. Cellar is **not** stored at the base; it's derived per-order at fill time via `ICorkCellarFactory(factory).cellarOf(order.user)`.
  - Public state: `mapping(bytes32 orderId => OrderStatus) public orderStatus` (single declaration; concretes do NOT redeclare).
  - Public views: `domainSeparator() view returns (bytes32)` (revert `"NOT_IMPLEMENTED"`).
  - Internal virtuals (override surface for concretes — 5 total): `_validateOpen(OrderData)`, `_onRolloverLegFill(...)`, `_onPremiumLegFill(...)`, `_onOpenForDecoded(orderId, originFillerData)` (default empty — concretes hook in to store `repaymentTo`), `_onOpenTransitionToOpened(orderId, orderDigest, user)` (default empty — concretes hook in to populate `orderIdOf` / `cellarOf`).
  - `finaliseAsSettled`, `finaliseAsRefunded`, `finaliseAsCancelled` are NOT on the base — their signatures differ between Exact (orderId) and Partial (orderDigest + fillers[]) so each concrete declares them directly.
- [ ] `contracts/settlers/ExactFillSettler.sol` — extends `BaseSettler`; all external functions revert `"NOT_IMPLEMENTED"`. Does NOT redeclare `orderStatus`.
- [ ] `contracts/settlers/PartialFillSettler.sol` — same shape.
- [ ] `contracts/erc6909/ERC6909Premium.sol` — all functions revert `"NOT_IMPLEMENTED"`.
- [ ] `forge build`.
- [ ] Commit all. Attempt push + PR creation against PR 1 branch. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge build` passes; `forge test --match-path "test/libs/*"` — all 22 library tests pass (library implementations are complete in this PR; stubs are only on settler/ERC-6909 contracts).

---

## PR 3: `feat/erc6909-premium`

**Diff from parent:** `compare/feat/settler-interfaces-and-libs...feat/erc6909-premium`

ERC-6909 prepaid-balance contract — tests + implementation together. Standalone, no settler coupling.

### Task 8: ERC-6909 BTT tests

- [ ] Scaffold from `.tree` files under `test/erc6909/` (see test-spec §7). Tree files:
  - `ERC6909Premium_deposit.tree` (6 leaves + 3 inline `supportsInterface`)
  - `ERC6909Premium_withdraw.tree` (5)
  - `ERC6909Premium_settle.tree` (11)
  - `ERC6909Premium_setOperator.tree` (4)
  - `ERC6909Premium_balanceOf.tree` (2)
  - `ERC6909Premium_isOperator.tree` (3)
- [ ] `bulloak scaffold` each tree into its `.t.sol` sibling.
- [ ] Implement all 31 leaf bodies. Use a fresh `MockERC20` per token ID where needed (Phoenix's `DummyERC20` is reachable via `lib/cellar`).

### Task 9: Implement `ERC6909Premium`

**File:** `contracts/erc6909/ERC6909Premium.sol` — replace stub bodies.

- [ ] `deposit(token, to, amount)` — pull ERC-20 via `SafeERC20.safeTransferFrom`, credit `balances[to][tokenId]` where `tokenId = uint256(uint160(token))`.
- [ ] `withdraw(tokenId, to, amount)` — decrement sender balance, `SafeERC20.safeTransfer` out.
- [ ] `settle(debitFrom, premiumFiller, tokenId, amount, recipient)`:
  - Dual-auth check: `_isAuthorized(debitFrom, msg.sender) && _isAuthorized(debitFrom, premiumFiller)`; revert `UnauthorizedSettler` / `UnauthorizedPremiumFiller` on mismatch.
  - Balance check (revert `InsufficientBalance`).
  - `amount == 0` short-circuits (INV-S10).
  - Decrement, then `SafeERC20.safeTransfer(recipient, amount)`. `nonReentrant` guard prevents reentry from tokens with recipient callbacks.
  - Emit `Settled(debitFrom, premiumFiller, tokenId, amount, recipient)`.
- [ ] `setOperator` / `isOperator` / `balanceOf` — standard ERC-6909 mechanics, no surprises.
- [ ] `supportsInterface` — returns true for ERC-165 + ERC-6909 interface IDs + `IERC6909Premium`.
- [ ] `forge test --match-path "test/erc6909/*"` — **all 31 leaves pass**.
- [ ] Commit. Attempt push + PR creation against PR 2 branch. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge test --match-path "test/erc6909/*"` — all pass.

---

## PR 4: `feat/settlers` (5 sub-PRs)

**Diff from parent:** `compare/feat/erc6909-premium...feat/settlers`

Tests + implementation for the three settlers, shipped together per domain chunk. Sub-PRs merge in dependency order.

See `plan/test-spec.md` for complete tree inventory, leaf counts, and infrastructure design.

> **Note:** This PR is an integration branch. Review the 5 sub-PRs individually. Merge in order: 4a → 4b → 4c → 4d → 4e.

---

### PR 4a: `feat/settler-test-infra`

**Base:** `feat/settlers`
**Diff from base:** `compare/feat/settlers...feat/settler-test-infra`
**Depends on:** nothing (merge first)

Test infrastructure only — no settler implementation.

#### Task 10: `BaseTestSettler` harness

- [ ] Verify cellar's `BaseTestCorkCellar` is reachable via the `cellar-test/` remap (sanity check from PR 1's submodule + remappings work).
- [ ] Create `test/BaseTestSettler.sol` inheriting `cellar-test/BaseTestCorkCellar`. Override `setUp()`:
  - `super.setUp()` deploys factory, registry, cellars, modules, tokens.
  - Deploy `ERC6909Premium premium = new ERC6909Premium()`.
  - Deploy `ExactFillSettler exactSettler = new ExactFillSettler(address(factory), address(premium))`.
  - Deploy `PartialFillSettler partialSettler = new PartialFillSettler(address(factory), address(premium))`.
  - (Factory is not required to approve settlers — factory uses blocklist + transient-slot binding per extension §4.2.)
- [ ] Add all signing helpers per test-spec §2.4:
  - `_signOrder(order, wallet, settler)` — EOA EIP-712 over the **settler** domain.
  - `_signOrderWithSmartWallet(order, sw, settler)` — ERC-1271 path.
  - `_signCancel(orderId, cancelDeadline, wallet, settler)` — maker cancel sig over `Cancel(bytes32 orderId,uint256 cancelDeadline)` (see §5.7 note in test-spec). Note `cancelDeadline` is a separate parameter, not `fillDeadline`.
- [ ] Add order-building helpers:
  - `_createRolloverOrder(uw, orderSize, allowPartialFills, allowUnderfill, settler)` — returns `(GaslessCrossChainOrder order, OrderData od, CellarIntent intent)` tuple; consistent `cellarIntentHash` between `od` and `intent`.
  - `_buildExactRolloverFillerData(destination)` — returns ABI-encoded `bytes fillerData = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData{destination}))`.
  - `_buildExactPremiumFillerData(debitFrom)` — returns ABI-encoded `bytes fillerData = abi.encodePacked(uint8(1), abi.encode(PremiumFillerData{debitFrom}))`.
  - `_buildPartialFillerData(outputIndex, destination, debitFrom, targetFiller, intent, cellarSig)` — returns ABI-encoded `bytes fillerData` per extension §5.4 wire format.
  - `_depositPremium(filler, token, amount)` — ERC-6909 deposit helper.
  - `_advanceTo(fillDeadline + delta)` — `vm.warp` wrapper.
- [ ] State snapshot helpers:
  - `struct SettlerSnapshot { uint256 erc6909; uint256 settlerDstCst; uint256 cellarDstCst; ... }`
  - `_snapshot(orderDigest, filler)` / `_assertSnapshotDelta(before, after, expected)`.
- [ ] `forge build` — harness compiles against stubs.
- [ ] Commit. Attempt push + sub-PR creation against `feat/settlers`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge build` passes with `BaseTestSettler` compiled.

> **Note:** Task 10 absorbs the previous Task 11 (cellar-remap verification + final build/commit). One agent dispatch.

---

### PR 4b: `feat/settler-base`

**Base:** `feat/settlers`
**Diff from base:** `compare/feat/settlers...feat/settler-base`
**Depends on:** PR 4a
**Tests:** 26 BaseSettler leaves (see test-spec §4)
**Implementation:** `contracts/settlers/BaseSettler.sol` + `test/base/MockBaseSettler.sol`

#### Task 12: BaseSettler BTT tests

- [ ] Scaffold from `.tree` files in `test/base/` — 4 trees per test-spec §4:
  - `BaseSettler_domainSeparator.tree` (3)
  - `BaseSettler_recover.tree` (11)
  - `BaseSettler_forwardToFactory.tree` (6)
  - `BaseSettler_settlePremium.tree` (6)
- [ ] Write `test/base/MockBaseSettler.sol` — minimal concrete extension of `BaseSettler` that surfaces internal primitives for direct testing (`mockForwardToFactory`, `mockSettlePremium`, `mockRecover`). Use only for internal-primitive coverage — the concrete settlers exercise the same paths end-to-end in 4c/4d.
- [ ] Implement all 26 test bodies.

#### Task 13: Implement `BaseSettler` (canonical, frozen at end of 4b)

**File:** `contracts/settlers/BaseSettler.sol` — replace stub. After this task lands, the BaseSettler contract surface is **frozen** for the remainder of PR 4 — sub-PRs 4c and 4d MAY NOT modify this file. If a concrete needs an internal helper, it goes on the concrete, not the base. Any change to BaseSettler after 4b ships requires a follow-up amendment PR that re-runs both 4c and 4d gates.

**Frozen interface** (this is the canonical surface that 4c and 4d build against):

```solidity
abstract contract BaseSettler is IOriginSettler, IDestinationSettler, ReentrancyGuard {
    // ─── Immutables ───────────────────────────────────────────────
    address public immutable factory;          // CorkCellarFactory
    address public immutable erc6909Premium;   // ERC6909Premium

    // ─── State (declared HERE, not in concretes) ─────────────────
    mapping(bytes32 orderId => OrderStatus) public orderStatus;

    // ─── EIP-712 ──────────────────────────────────────────────────
    function domainSeparator() public view returns (bytes32);

    // ─── Public surface (template methods) ───────────────────────
    function open(OnchainCrossChainOrder calldata order) external;
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata sig, bytes calldata originFillerData) external;
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory);
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData) external view returns (ResolvedCrossChainOrder memory);
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;

    // ─── Internal primitives ─────────────────────────────────────
    function _recover(bytes32 digest, address user, bytes calldata signature) internal view returns (bool);
    function _forwardToFactory(address cellar, uint8 phase, CellarIntent calldata intent, bytes calldata cellarSig, uint256 fillAmount, address filler) internal returns (uint256 actualRolled);
    function _settlePremium(uint256 tokenId, uint256 amount, address debitFrom, address premiumFiller, address cellar) internal;
    function _hashOrder(GaslessCrossChainOrder calldata order) internal view returns (bytes32);
    function _resolveSharedShape(GaslessCrossChainOrder calldata order, uint256 outputAmountOverride) internal view returns (ResolvedCrossChainOrder memory);

    // ─── Virtual hooks (5 — concretes implement; defaults are empty no-ops where safe) ─
    function _validateOpen(OrderData calldata od) internal view virtual;
    function _onRolloverLegFill(GaslessCrossChainOrder calldata order, OrderData calldata od, Output calldata output, bytes calldata fillerData) internal virtual;
    function _onPremiumLegFill(GaslessCrossChainOrder calldata order, OrderData calldata od, Output calldata output, bytes calldata fillerData) internal virtual;

    // Extension points on the open/openFor template methods — default empty.
    // _onOpenForDecoded: called once per openFor() invocation, AFTER signature recovery but
    //                    BEFORE the idempotent-on-Opened early return, so concretes can
    //                    store originFillerData-derived state on the terminal None → Opened
    //                    transition only. Concretes MUST guard on status inside the hook
    //                    if they want once-only semantics.
    // _onOpenTransitionToOpened: called exactly once, at the moment the status flips
    //                    None → Opened (inside both open() and openFor()). Receives
    //                    orderId, orderDigest, and order.user so concretes can populate
    //                    digest-keyed mappings (orderIdOf, cellarOf).
    function _onOpenForDecoded(bytes32 orderId, OriginFillerData memory originFillerData) internal virtual {}
    function _onOpenTransitionToOpened(bytes32 orderId, bytes32 orderDigest, address user) internal virtual {}

    // finaliseAsSettled / finaliseAsRefunded are external on the concretes with
    // different signatures (Exact takes orderId; Partial takes orderDigest + fillers[]).
    // Base does NOT declare them to avoid forcing a uniform signature. Concretes
    // implement them directly, not as overrides of a base virtual.
    // finaliseAsCancelled is likewise concrete-specific.
}
```

Implementation notes:

- [ ] Constructor: `(address factory_, address erc6909Premium_)` — store as immutables. Cellar is derived **per-order** at fill time via `ICorkCellarFactory(factory).cellarOf(order.user)`.
- [ ] `_DOMAIN_SEPARATOR` cached in constructor; re-computed on chainId change.
- [ ] `_recover` uses OZ `SignatureChecker.isValidSignatureNow(user, digest, signature)` for EOA + ERC-1271 dispatch.
- [ ] `_forwardToFactory` wraps `ICorkCellarFactory(factory).executeIntentHooks(...)`. Does not suppress reverts.
- [ ] `_settlePremium` wraps `IERC6909Premium(erc6909Premium).settle(debitFrom, premiumFiller, tokenId, amount, cellar)`.
- [ ] `open(OnchainCrossChainOrder)` — template method:
  1. Decode `OrderData od = LibRolloverOrder.decode(order.orderData)`.
  2. Call `_validateOpen(od)` (token-distinctness + partial-flag check; concrete override).
  3. Require `msg.sender == order.user` → else `NotMaker`.
  4. Compute `orderId = LibSettlerHashing.computeOrderId(order); orderDigest = LibSettlerHashing.computeOrderDigest(order, od)`.
  5. Read `orderStatus[orderId]`; if terminal → `InvalidOrderStatus`; if `Opened` → return (idempotent, no event).
  6. **Call `_onOpenTransitionToOpened(orderId, orderDigest, order.user)`** — concretes populate `orderIdOf` / `cellarOf` here.
  7. Transition `orderStatus[orderId] = Opened`; emit `Open(orderId, _resolve(order))`.
- [ ] `openFor(GaslessCrossChainOrder, sig, originFillerData)` — template method:
  1. Decode `OriginFillerData { outputAmount, repaymentTo } = LibRolloverOrder.decodeOriginFillerData(originFillerData)`; revert on empty bytes.
  2. Decode `OrderData od`.
  3. Call `_validateOpen(od)`.
  4. **No `openDeadline` check** — RFC 003 line 671: "Cork's order logic uses only `fillDeadline` as the operational deadline."
  5. Compute `orderId`, `orderDigest`.
  6. EIP-712 verify `sig` over `orderDigest` via `_recover(..., order.user, sig)` → else `InvalidSignature`.
  7. **Call `_onOpenForDecoded(orderId, originFillerDataDecoded)`** — concretes store `repaymentTo[orderId]` here.
  8. Read `orderStatus[orderId]`; if terminal → `InvalidOrderStatus`; if `Opened` → return (idempotent, no event).
  9. **Call `_onOpenTransitionToOpened(orderId, orderDigest, order.user)`** — concretes populate `orderIdOf` / `cellarOf`.
  10. Transition `orderStatus[orderId] = Opened`; emit `Open(orderId, _resolve(order))`.
- [ ] `fill` — template method:
  - Decode `order` from `originData`; verify `_hashOrder(order) == orderId` → `OrderIdMismatch`.
  - Decode `od`.
  - `block.timestamp <= order.fillDeadline` → `FillAfterDeadline`.
  - Status not terminal → `OrderInTerminalState`.
  - `_validateOpen(od)` enforced at fill time too (INV-S15 + partial-flag fill-time check; required because of fill-before-open).
  - `uint8 outputIndex = uint8(fillerData[0]); bytes calldata legData = fillerData[1:];`
  - `outputIndex == 0` → `_onRolloverLegFill(order, od, output, legData)`.
  - `outputIndex == 1` → `_onPremiumLegFill(order, od, output, legData)`.
  - Else revert `InvalidOutputIndex`.
  - `nonReentrant` guard on the external entry.
- [ ] Custom errors + events per test-spec §4.
- [ ] `forge test --match-path "test/base/*"` — **all 26 leaves pass**.
- [ ] Commit. Attempt push + sub-PR creation against `feat/settlers`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge test --match-path "test/base/*"` — all pass. After this gate, BaseSettler.sol is frozen.

---

### PR 4c: `feat/settler-exact`

**Base:** `feat/settlers`
**Diff from base:** `compare/feat/settlers...feat/settler-exact`
**Depends on:** PR 4a, PR 4b
**Tests:** 71 ExactFillSettler BTT tests (see test-spec §5)
**Implementation:** `contracts/settlers/ExactFillSettler.sol`

#### Task 14: ExactFillSettler BTT tests

- [ ] Scaffold from co-located `.tree` files in `test/exact/` — 8 trees per test-spec §5:
  - `ExactFillSettler_open.tree` (6), `ExactFillSettler_openFor.tree` (10), `ExactFillSettler_resolve.tree` (4), `ExactFillSettler_resolveFor.tree` (5), `ExactFillSettler_fill.tree` (22), `ExactFillSettler_finaliseAsSettled.tree` (7), `ExactFillSettler_finaliseAsRefunded.tree` (9), `ExactFillSettler_finaliseAsCancelled.tree` (8).
- [ ] Implement all 71 leaf bodies.

#### Task 15: Implement `ExactFillSettler`

**File:** `contracts/settlers/ExactFillSettler.sol` — replace stub. Does NOT modify `BaseSettler.sol` (frozen per Task 13). `orderStatus` is inherited from Base, not redeclared.

- [ ] Storage (concrete-side only — Base holds `orderStatus`):
  ```solidity
  mapping(bytes32 orderId => mapping(bytes32 outputHash => FillRecord)) public fillRecords;
  mapping(bytes32 orderId => bool) public paymentSettled;
  mapping(bytes32 orderId => address) public repaymentTo;   // from openFor
  mapping(bytes32 orderId => address) public dstCstToken;   // written at rollover fill; read at finalise paths
  mapping(bytes32 orderId => address) public cellarOf;      // written once at open/openFor; read at finalise paths
  ```
  `dstCstToken` and `cellarOf` are populated so the finalise functions can accept only `bytes32 orderId` without re-decoding `order.orderData` (RFC 003 §6.5 permissionless finalise). `cellarOf` is written from `_onOpenTransitionToOpened` via an override; `dstCstToken` is written once inside the rollover-leg branch of `_onRolloverLegFill`.
  ```solidity
  struct FillRecord {
      address filler;           // rollover leg: the rolloverFiller. premium leg: unused sentinel (msg.sender of premium fill).
      address destination;      // rollover leg: filler's chosen dstCST destination. premium leg: unused.
      uint128 dstCstProduced;   // rollover leg only (premium leg zero). uint128 fits any reasonable share amount.
      uint64  filledAt;         // 0 ⇒ unfilled.
  }
  ```
  `destination` lives in `FillRecord` so `finaliseAsSettled` can route dstCST to `fillRecord.destination` without a separate `rolloverState` mapping (RFC 003 §6.5's packed struct is decomposed here; the destination field preserves the read path).
- [ ] `_validateOpen(OrderData od)` override:
  - `od.srcCstToken != od.premiumToken` → else `InvalidOrderTokenPair` (INV-S15).
  - `od.allowPartialFills == false` → else `InconsistentIntent`.
- [ ] `open` and `openFor` are inherited template methods on Base — no concrete override needed. Exact overrides two Base hooks:
  - `_onOpenForDecoded(bytes32 orderId, OriginFillerData memory fd)` — writes `repaymentTo[orderId] = fd.repaymentTo` once per `openFor`.
  - `_onOpenTransitionToOpened(bytes32 orderId, bytes32 orderDigest, address user)` — writes `cellarOf[orderId] = ICorkCellarFactory(factory).cellarOf(user)` on the None → Opened transition.
- [ ] `resolve` / `resolveFor` — inherited via Base's `_resolveSharedShape`.
- [ ] `_onRolloverLegFill(order, od, output, legData)` override:
  - `output.amount == od.orderSize` → else `PartialFillNotAllowed`.
  - Compute `orderId = _hashOrder(order); rolloverOutputHash = LibSettlerHashing.computeOutputHash(output);`.
  - `fillRecords[orderId][rolloverOutputHash].filledAt == 0` → else `AlreadyFilled`.
  - Decode `RolloverFillerData { destination } = LibRolloverOrder.decodeRollover(legData)`; require `destination != address(0)`.
  - **Reconstruct CellarIntent from orderData** (Exact path — NOT from `fillerData`):
    `(CellarIntent intent, bytes cellarSig) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order)`.
    Require `keccak256(abi.encode(intent)) == od.cellarIntentHash` → else `IntentNotBoundToOrder`.
  - `address cellar = cellarOf[orderId];` (populated at open/openFor via `_onOpenTransitionToOpened`; non-zero iff status is `Opened`).
  - `IERC20 dstCst = ICorkCellar(cellar).dstCstToken(); IERC20 srcCst = ICorkCellar(cellar).srcCstToken();` — read once from the cellar; mirror into `dstCstToken[orderId] = address(dstCst);` so finalise paths can route transfers without re-reading the cellar.
  - Balance deltas: `uint256 dstBefore = dstCst.balanceOf(address(this)); uint256 srcBefore = srcCst.balanceOf(address(this));`.
  - `uint256 actualRolled = _forwardToFactory(cellar, 0, intent, cellarSig, output.amount, msg.sender);` (filler = msg.sender).
  - `uint256 dstDelta = dstCst.balanceOf(address(this)) - dstBefore; uint256 srcLeftover = srcCst.balanceOf(address(this)) - srcBefore;`.
  - **Leftover srcCST return (explicit sequence — no approval dance needed).** The cellar's `RolloverModule` sends leftover srcCST directly to the settler's `address(this)` balance during `executeIntentHooks`. The settler already holds it; route it to the original filler:
    ```solidity
    if (srcLeftover > 0) {
        SafeERC20.safeTransfer(srcCst, msg.sender, srcLeftover);
    }
    ```
    No `approve` + `safeTransferFrom`. This assumes the cellar's phase-0 hook pays leftover to `msg.sender` of `executeIntentHooks` — which is the factory, which forwards to the settler. Verify against cellar's `RolloverModule` at the pinned SHA before PR 4c opens; if the cellar instead holds leftover or sends it elsewhere, update this step to match.
  - Require `dstDelta + 1 >= Math.mulDiv(output.amount - srcLeftover, ICorkCellar(cellar).previewRollover(output.amount - srcLeftover), 1e18)` → else `DisproportionateOutput` (INV-S9 1-wei tolerance over dstCST units). If the cellar exposes a simpler preview, use it — the invariant is that the dstCST produced matches the cellar's own exchange-rate computation for the amount of srcCST consumed, within 1 wei. **Confirm the exchange formula with Filip before PR 4c merges** — the plan does not specify it authoritatively.
  - Write `fillRecords[orderId][rolloverOutputHash] = FillRecord({ filler: msg.sender, destination: destination, dstCstProduced: uint128(dstDelta), filledAt: uint64(block.timestamp) });`.
  - Emit `Fill(orderId, rolloverOutputHash, msg.sender)`.
  - **No status transition** (stays Opened per RFC 003 line 2932).
- [ ] `_onPremiumLegFill(order, od, output, legData)` override:
  - Compute `orderId`; compute `rolloverOutputHash = computeOutputHash(order.outputs[0])`, `premiumOutputHash = computeOutputHash(order.outputs[1])`.
  - Rollover-first: `fillRecords[orderId][rolloverOutputHash].filledAt != 0` → else `PremiumBeforeRollover`.
  - `fillRecords[orderId][premiumOutputHash].filledAt == 0` → else `AlreadyFilled`.
  - Decode `PremiumFillerData { debitFrom } = LibRolloverOrder.decodePremium(legData)`.
  - Read `FillRecord memory rolloverRec = fillRecords[orderId][rolloverOutputHash]`; `address rolloverFiller = rolloverRec.filler; uint256 dstCstProduced = rolloverRec.dstCstProduced`.
  - `uint256 premium = Math.mulDiv(dstCstProduced, od.minPremiumPerShare, 1e18, Math.Rounding.Ceil)`.
  - `address cellar = ICorkCellarFactory(factory).cellarOf(order.user)`.
  - `uint256 tokenId = uint256(uint160(od.premiumToken))`.
  - `_settlePremium(tokenId, premium, debitFrom, msg.sender, cellar)`.
  - Reconstruct `(intent, cellarSig)` from orderData as in the rollover path.
  - `_forwardToFactory(cellar, 1, intent, cellarSig, 0, rolloverFiller)` — filler is the **recorded rollover filler**, NOT msg.sender.
  - `paymentSettled[orderId] = true`.
  - Write `fillRecords[orderId][premiumOutputHash] = FillRecord({ filler: msg.sender, destination: address(0), dstCstProduced: 0, filledAt: uint64(block.timestamp) });`.
  - Emit `Fill(orderId, premiumOutputHash, msg.sender)`.
  - **No status transition.**
- [ ] `finaliseAsSettled(bytes32 orderId)`:
  - `orderStatus[orderId] == OrderStatus.Opened` → else `InvalidOrderStatus`.
  - `paymentSettled[orderId] == true` → else `PaymentNotSettled`.
  - Read `FillRecord memory rolloverRec = fillRecords[orderId][rolloverOutputHash]`; `rolloverRec.filledAt != 0` → else `InvalidFillRecord`.
  - Transition `orderStatus[orderId] = OrderStatus.Settled`. Emit `OrderFinalised(orderId, Settled)`.
  - `SafeERC20.safeTransfer(IERC20(dstCstToken[orderId]), rolloverRec.destination, rolloverRec.dstCstProduced)` — `dstCstToken[orderId]` is the storage mapping populated at rollover fill time so finalise paths accept only `orderId` without re-decoding `order`.
  - Permissionless per RFC 003 line 2320.
  - `nonReentrant`.
- [ ] `finaliseAsRefunded(bytes32 orderId, GaslessCrossChainOrder order)`:
  - `_hashOrder(order) == orderId` → else `DigestMismatch`.
  - `block.timestamp > order.fillDeadline` → else `NotExpired`.
  - `orderStatus[orderId] == Opened` → else `InvalidOrderStatus` (INV-S5, RFC 003 line 612).
  - `paymentSettled[orderId] == false` → else `OrderComplete`.
  - Decode `od` from `order.orderData`.
  - If `fillRecords[orderId][rolloverOutputHash].filledAt != 0`: `SafeERC20.safeTransfer(IERC20(dstCstToken[orderId]), cellarOf[orderId], rolloverRec.dstCstProduced)` (windfall).
  - Transition Opened → Refunded. Emit `OrderFinalised`.
  - `nonReentrant`.
- [ ] `finaliseAsCancelled(bytes32 orderId, GaslessCrossChainOrder order, bytes cancelSig)`:
  - `_hashOrder(order) == orderId` → else `DigestMismatch`.
  - `orderStatus[orderId] == Opened` → else `InvalidOrderStatus` (RFC 003 line 293).
  - No fills check: both `fillRecords[orderId][rolloverOutputHash].filledAt == 0` AND `fillRecords[orderId][premiumOutputHash].filledAt == 0` → else `OrderHasFills`.
  - Maker auth: `msg.sender == order.user` OR `_recover(cancelDigest, order.user, cancelSig)` where `cancelDigest` is derived from the schema documented in test-spec §5.7 note (this implementation: `Cancel(bytes32 orderId,uint256 cancelDeadline)` — a **separate** `cancelDeadline` field, NOT reused from `fillDeadline`; the sig schema is extracted to a named constant `CANCEL_TYPEHASH`).
  - Transition Opened → Cancelled. Emit `OrderFinalised`.
- [ ] `forge test --match-path "test/exact/*"` — **all 71 leaves pass**.
- [ ] Commit. Attempt push + sub-PR creation against `feat/settlers`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge test --match-path "test/exact/*"` — all pass. No changes to `BaseSettler.sol`.

---

### PR 4d: `feat/settler-partial`

**Base:** `feat/settlers`
**Diff from base:** `compare/feat/settlers...feat/settler-partial`
**Depends on:** PR 4a, PR 4b, PR 4c (sequential — runs after 4c merges, not in parallel)
**Tests:** 94 PartialFillSettler BTT tests (see test-spec §6)
**Implementation:** `contracts/settlers/PartialFillSettler.sol`

#### Task 16: PartialFillSettler BTT tests

- [ ] Scaffold from co-located `.tree` files in `test/partial/` — 10 trees per test-spec §6. Full filenames (exact, for `bulloak scaffold`):
  - `PartialFillSettler_open.tree` (6 leaves)
  - `PartialFillSettler_openFor.tree` (10)
  - `PartialFillSettler_resolve.tree` (4)
  - `PartialFillSettler_resolveFor.tree` (5)
  - `PartialFillSettler_fill.tree` (31)
  - `PartialFillSettler_finaliseAsSettled.tree` (10)
  - `PartialFillSettler_finaliseAsRefunded.tree` (13)
  - `PartialFillSettler_finaliseAsCancelled.tree` (9)
  - `PartialFillSettler_fillerRollovers.tree` (3)
  - `PartialFillSettler_totalDstCstEscrowed.tree` (3)
- [ ] Implement all 94 leaf bodies. Pay attention to the cellar-bubble leaves (`OverfillCeiling`, `UnderfillNotAllowed`, `SettlerMismatch`, `PremiumAlreadyFiredForFiller`) — they revert from inside the cellar and propagate.

#### Task 17: Implement `PartialFillSettler`

**File:** `contracts/settlers/PartialFillSettler.sol` — replace stub. Does NOT modify `BaseSettler.sol` (frozen). `orderStatus` is inherited from Base.

- [ ] Storage (concrete-side only; `orderStatus` inherited from Base):
  ```solidity
  mapping(bytes32 orderDigest => mapping(address filler => FillerRollover)) public fillerRollovers;
  mapping(bytes32 orderDigest => uint256) public totalDstCstEscrowed;
  mapping(bytes32 orderDigest => bytes32) public orderIdOf;        // populated at open/openFor
  mapping(bytes32 orderDigest => address) public cellarOf;         // populated at open/openFor; read at finalise paths
  mapping(bytes32 orderDigest => address) public dstCstToken;      // populated on first rollover fill; read at finalise paths
  mapping(bytes32 orderDigest => uint256) public participantCount; // incremented once per filler whose srcCstProvided transitions 0 → non-zero
  mapping(bytes32 orderDigest => uint256) public finalisedCount;   // incremented on each f.finalised = true
  mapping(bytes32 orderDigest => uint256) public refundedCount;    // incremented on each f.refunded  = true
  mapping(bytes32 orderId      => address) public repaymentTo;
  ```
  `FillerRollover` per extension §5.4: `{ uint256 srcCstProvided; uint256 dstCstProduced; address destination; bool premiumSettled; bool finalised; bool refunded; }`.
  The three counters track exactly the cardinality information needed by INV-P16's `∀a: f.finalised` clause, replacing the unenumerable on-chain set with three uint256 reads. `cellarOf[orderDigest]` is populated inside the `_onOpenTransitionToOpened` override (see below) so finalise paths can read the cellar address without requiring a full `order` parameter.
- [ ] `_validateOpen(OrderData od)` override:
  - `od.srcCstToken != od.premiumToken` → else `InvalidOrderTokenPair` (INV-S15).
  - `od.allowPartialFills == true` → else `InconsistentIntent`.
- [ ] `open` / `openFor` inherited from Base; override `_onOpenTransitionToOpened(bytes32 orderId, bytes32 orderDigest, address user)` to populate `orderIdOf[orderDigest] = orderId` AND `cellarOf[orderDigest] = ICorkCellarFactory(factory).cellarOf(user)` once per order. The `user` parameter is forwarded by the Base template method from `order.user` — see Task 13 line 399 for the frozen hook signature. Re-assigning on idempotent openFor re-entry writes the same values (same `user` → same derived cellar), so the write is safely repeated.
- [ ] `resolve` / `resolveFor` — inherited via Base; `minReceived.amount = orderSize * minPremiumPerShare / 1e18` encoded in `_resolveSharedShape` with a concrete-specified override (aggregate-premium reporting).
- [ ] `_onRolloverLegFill(order, od, output, legData)` override:
  - Compute `orderDigest = LibSettlerHashing.computeOrderDigest(order, od)`.
  - Decode `PartialFillerData { destination, debitFrom, targetFiller, intent, cellarSig } = LibRolloverOrder.decodePartial(legData)`.
  - `targetFiller == msg.sender` → else `TargetFillerMismatch` (phase-0 self-deal guard).
  - `destination != address(0)` → else `InvalidDestination`.
  - `keccak256(abi.encode(intent)) == od.cellarIntentHash` → else `IntentNotBoundToOrder` (INV-P18).
  - `fillerRollovers[orderDigest][msg.sender].srcCstProvided == 0` → else `AlreadyFilledByFiller` (INV-P1).
  - `address cellar = cellarOf[orderDigest];` (populated at open/openFor via `_onOpenTransitionToOpened`; non-zero iff the order is Opened).
  - `IERC20 dstCst = ICorkCellar(cellar).dstCstToken(); IERC20 srcCst = ICorkCellar(cellar).srcCstToken();` — read once; if `dstCstToken[orderDigest] == address(0)` write `dstCstToken[orderDigest] = address(dstCst)` (idempotent across participants).
  - Balance deltas: `uint256 dstBefore = dstCst.balanceOf(address(this)); uint256 srcBefore = srcCst.balanceOf(address(this));`.
  - `uint256 actualRolled = _forwardToFactory(cellar, 0, intent, cellarSig, output.amount, msg.sender);` (bubbles `OverfillCeiling`, `UnderfillNotAllowed`, `ZeroRollover`).
  - Require `actualRolled > 0` → else `ZeroRollover` (settler-side defense in depth, INV-C17 redundancy).
  - `uint256 dstDelta = dstCst.balanceOf(address(this)) - dstBefore; uint256 srcLeftover = srcCst.balanceOf(address(this)) - srcBefore;`.
  - Write `fillerRollovers[orderDigest][msg.sender] = FillerRollover({ srcCstProvided: actualRolled, dstCstProduced: dstDelta, destination: destination, premiumSettled: false, finalised: false, refunded: false });`.
  - `totalDstCstEscrowed[orderDigest] += dstDelta;`.
  - `participantCount[orderDigest] += 1;` (0 → non-zero transition for this filler; invariant: equals the number of distinct addresses with `srcCstProvided > 0`).
  - **Leftover srcCST return — same explicit sequence as Exact**: `if (srcLeftover > 0) SafeERC20.safeTransfer(srcCst, msg.sender, srcLeftover);`. No `approve` + `safeTransferFrom` dance. Verify the cellar's `RolloverModule` behaviour at the pinned SHA matches this assumption before PR 4d merges.
  - Emit `Fill`.
  - **No status transition.**
- [ ] `_onPremiumLegFill(order, od, output, legData)` override:
  - Compute `orderDigest`.
  - Decode `PartialFillerData`.
  - `FillerRollover storage f = fillerRollovers[orderDigest][targetFiller]`.
  - `f.srcCstProvided != 0` → else `NoRolloverLegForFiller` (INV-P3).
  - `!f.premiumSettled` → else `AlreadySettled`.
  - `keccak256(abi.encode(intent)) == od.cellarIntentHash` → else `IntentNotBoundToOrder`.
  - Dual-auth: `debitFrom == msg.sender || IERC6909Premium(erc6909Premium).isOperator(debitFrom, msg.sender)` → else `UnauthorizedDebitFrom`. Note `msg.sender` need not equal `targetFiller` (anyone may settle another's premium).
  - `uint256 premium = Math.mulDiv(f.dstCstProduced, od.minPremiumPerShare, 1e18, Math.Rounding.Ceil)`.
  - `address cellar = ICorkCellarFactory(factory).cellarOf(order.user)`.
  - `_settlePremium(tokenId, premium, debitFrom, msg.sender, cellar)`.
  - `f.premiumSettled = true`.
  - `_forwardToFactory(cellar, 1, intent, cellarSig, 0, targetFiller)` — filler is `targetFiller`, not msg.sender (bubbles `PremiumAlreadyFiredForFiller` on duplicate, `SettlerMismatch` on identity failure).
  - Emit `Fill`.
- [ ] `finaliseAsSettled(bytes32 orderDigest, address[] calldata fillers)`:
  - `bytes32 orderId = orderIdOf[orderDigest];` require `orderId != bytes32(0)` → else `InvalidOrderStatus` (order was never opened, so no finalise path).
  - `orderStatus[orderId] == Opened` → else `InvalidOrderStatus`.
  - For each filler:
    - Read `FillerRollover storage f = fillerRollovers[orderDigest][fillers[i]]`.
    - Skip if `!f.premiumSettled` OR `f.finalised` OR `f.refunded`.
    - CEI: `f.finalised = true; finalisedCount[orderDigest] += 1; totalDstCstEscrowed[orderDigest] -= f.dstCstProduced;` THEN `SafeERC20.safeTransfer(IERC20(dstCstToken[orderDigest]), f.destination, f.dstCstProduced);`.
    - Emit `FillerFinalised(orderDigest, fillers[i], f.dstCstProduced)`.
  - **Terminal transition rule (on-chain, matches INV-P16 exactly):**
    After the loop, resolve the cellar for the `hookNonces` read: `address cellar = cellarOf[orderDigest];` (populated at open/openFor; non-zero when orderId is non-zero, so the earlier `orderId != bytes32(0)` guard implicitly covers this). Transition `orderStatus[orderId] = Settled` iff ALL three conditions hold:
    1. `(ICorkCellar(cellar).hookNonces(orderDigest) & 1) != 0` — phase-0 terminal bit set (equivalent to `Σ srcCstProvided == orderSize`, INV-P7).
    2. `totalDstCstEscrowed[orderDigest] == 0`.
    3. `finalisedCount[orderDigest] == participantCount[orderDigest]` — every filler who ever rolled has been finalised (implies `refundedCount == 0` for those fillers since participants with `refunded == true` would contribute to `refundedCount` instead).
    Emit `OrderFinalised(orderId, Settled)`.
    If any of the three fails, the order stays `Opened` — this is the documented "mixed state" path (some fillers refunded, some settled) which does not qualify for Settled per INV-P16. A follow-up `finaliseAsSettled` call (or a separate `finaliseAsRefunded` call on the remaining refunded path) may complete the terminalization later.
  - `nonReentrant`.
- [ ] `finaliseAsRefunded(bytes32 orderDigest, GaslessCrossChainOrder calldata order, address[] calldata fillers)`:
  - `LibSettlerHashing.computeOrderDigest(order, LibRolloverOrder.decode(order.orderData)) == orderDigest` → else `DigestMismatch`.
  - Compute `orderId = LibSettlerHashing.computeOrderId(order)`.
  - `block.timestamp > order.fillDeadline` → else `NotExpired` (INV-P5).
  - `orderStatus[orderId] == Opened` → else `InvalidOrderStatus` (RFC 003 line 612).
  - For each filler: skip branches per test-spec §6.6; CEI happy path transfers `f.dstCstProduced` of `IERC20(dstCstToken[orderDigest])` to `cellarOf[orderDigest]` (UW windfall). Increment `refundedCount[orderDigest]` on each `f.refunded = true`.
  - **Terminal transition rule (on-chain):**
    After the loop, transition `orderStatus[orderId] = Refunded` iff:
    1. `totalDstCstEscrowed[orderDigest] == 0` — all participating fillers' escrow has been routed (either refunded or settled earlier pre-deadline).
    2. `refundedCount[orderDigest] == participantCount[orderDigest]` — every participant was refunded (no finalised fillers; this is the pure-refund terminal condition).
    Emit `OrderFinalised(orderId, Refunded)`.
    Mixed-state (some settled pre-deadline, rest refunded post-deadline) does not qualify — status stays Opened, observable via the counter reads.
  - `nonReentrant`.
- [ ] `finaliseAsCancelled(bytes32 orderId, GaslessCrossChainOrder calldata order, bytes calldata cancelSig)`:
  - `_hashOrder(order) == orderId` → else `DigestMismatch`.
  - Compute `orderDigest = LibSettlerHashing.computeOrderDigest(order, od)`.
  - `orderStatus[orderId] == Opened` → else `InvalidOrderStatus` (RFC 003 line 293).
  - `cellar.rolled(orderDigest) == 0 && totalDstCstEscrowed[orderDigest] == 0` → else `OrderHasFills` (INV-P15).
  - Maker auth: same as Exact — `msg.sender == order.user` OR `_recover(cancelDigest, order.user, cancelSig)` using the `Cancel(bytes32 orderId,uint256 cancelDeadline)` schema with a **separate** `cancelDeadline` (not `fillDeadline`).
  - Transition Opened → Cancelled. Emit `OrderFinalised`.
- [ ] View getters: `fillerRollovers(orderDigest, filler)`, `totalDstCstEscrowed(orderDigest)` — direct mapping reads.
- [ ] `forge test --match-path "test/partial/*"` — **all 94 leaves pass**.
- [ ] Commit. Attempt push + sub-PR creation against `feat/settlers`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge test --match-path "test/partial/*"` — all pass. No changes to `BaseSettler.sol`.

---

### PR 4e: `feat/settler-integration`

**Base:** `feat/settlers`
**Diff from base:** `compare/feat/settlers...feat/settler-integration`
**Depends on:** PR 4c, PR 4d (merge last)

#### Task 18: Integration tests (15 net-new)

- [ ] Write `test/integration/RolloverLifecycle.t.sol` — 15 end-to-end tests per test-spec §9:
  - INT-1 exact full lifecycle, INT-2 refund-after-dodge, INT-3 cancel-before-fill, INT-3b fill-before-open.
  - INT-4a scenario A baseline (terminal + post-terminal revert), INT-4b alternate three-sequential.
  - INT-5 scenario B underfill, INT-6 scenario C expiration-mid-fill.
  - INT-7a scenario D both-revert, INT-7b alternate one-wins.
  - INT-8 scenario E underfill-disallowed, INT-9 mixed settle+refund.
  - INT-10 griefing defense, INT-11 cross-settler sig replay, INT-12 factory blocklist.
  - INT-13 premium-hook-revert ERC-6909 rollback (Exact AND Partial).

#### Task 19: Invariant tests (29 properties)

- [ ] `test/invariant/SettlerInvariantHandler.sol` — 17 handler actions per test-spec §10.1. Ghost variables per test-spec §10.1.
- [ ] `test/invariant/ExactFillInvariantTest.t.sol` — 10 SINV functions per test-spec §10.2.
- [ ] `test/invariant/PartialFillInvariantTest.t.sol` — 16 PINV functions per test-spec §10.3 (P2 gap, P9 no function).
- [ ] `test/invariant/ERC6909PremiumInvariantHandler.sol` + `ERC6909PremiumInvariantTest.t.sol` — 3 EINV functions per test-spec §10.4.

#### Task 20: Deploy script + final merge gate

- [ ] `script/foundry-scripts/DeploySettlers.s.sol`:
  ```solidity
  function run() external returns (address erc6909, address exactSettler, address partialSettler) {
      address factory = _resolveFactoryAddress();
      vm.startBroadcast();
      erc6909 = address(new ERC6909Premium());
      exactSettler = address(new ExactFillSettler(factory, erc6909));
      partialSettler = address(new PartialFillSettler(factory, erc6909));
      vm.stopBroadcast();
  }

  function _resolveFactoryAddress() internal view returns (address) {
      // Override path for local/dev (anvil, forks): explicit env var wins
      try vm.envAddress("FACTORY_ADDRESS_OVERRIDE") returns (address override) {
          return override;
      } catch {}
      // Production path: read from cellar-private's networks.json keyed by chainId.
      // Try the post-rename key `CorkCellarFactory` first, fall back to the
      // pre-rename `COWShedFactory` if the pinned lib/cellar SHA predates the
      // rename merge. The fallback is defensive — this repo pins lib/cellar, so
      // the key is known at deploy time, but the fallback lets the deploy script
      // run on older pins without editing.
      string memory networksJson = vm.readFile("lib/cellar/networks.json");
      string memory chain = vm.toString(block.chainid);
      string memory keyNew = string.concat(".CorkCellarFactory.", chain, ".address");
      try vm.parseJsonAddress(networksJson, keyNew) returns (address factory) {
          return factory;
      } catch {
          string memory keyOld = string.concat(".COWShedFactory.", chain, ".address");
          return vm.parseJsonAddress(networksJson, keyOld); // reverts if neither key exists for this chain
      }
  }
  ```
  Resolution order: env override → `networks.json[CorkCellarFactory][chainId]` → `networks.json[COWShedFactory][chainId]`. Reverts if none of the three resolve. The dual-key fallback removes the timing dependency on cellar-private's rename merge — deploy gate runs on any pinned SHA.
- [ ] `test/script/DeploySettlers.t.sol` — single test asserting the deploy script:
  - Resolves a factory address from a stubbed `networks.json` (write a test fixture json under `test/fixtures/`).
  - Deploys all three contracts.
  - Wires constructor args correctly (`exactSettler.factory() == factory`, etc.).

##### Final merge gate

- [ ] `forge test` — **ALL TESTS PASS** (22 lib + 31 ERC-6909 + 26 base + 71 exact + 94 partial + 15 integration + 29 invariant = 288 tests).
- [ ] `forge test --fail-fast` sanity re-run.
- [ ] Commit. Attempt push + sub-PR creation against `feat/settlers`. On credential/push failure, record in `plan/pending-branches.md` per the offline deferral rule and proceed.

**Gate:** `forge test` — all 288 pass.

> **Note:** Task 20 absorbs the previous Task 21 (final gate run + commit). One agent dispatch covers deploy script + gate. Tasks 18, 19, 20 = three agents for PR 4e.

---

### PR 4 merge gate

After all 5 sub-PRs are merged into `feat/settlers`:

- [ ] `forge test` — **ALL 288 TESTS PASS**
- [ ] `forge coverage --report summary` — no regressions from baseline (empty repo baseline, so any coverage is gain).
- [ ] Integration-test-only run: `forge test --match-path "test/integration/*"` — 15 pass.
- [ ] Invariant-only run: `forge test --match-contract "*Invariant*"` — 29 pass under default `invariantRuns=256` / `invariantDepth=100`.

---

## execute-cork Execution Schedule

| Run | PR | Tasks | Agents | Gate |
|---|---|---|---|---|
| 1 | PR 1 | 1–2 | 1 | `forge build` passes; submodule pinned |
| 2 | PR 2 | 3–7 | 4 | `forge build`; `forge test --match-path "test/libs/*"` (22 pass) — library tests ship co-located with library impl per test-spec §14 (revised) |
| 3 | PR 3 | 8–9 | 2 | `forge test --match-path "test/erc6909/*"` (31 pass) |
| 4a | PR 4a | 10 | 1 | `forge build` on `BaseTestSettler` |
| 4b | PR 4b | 12–13 | 2 | `forge test --match-path "test/base/*"` (26 pass); BaseSettler.sol frozen after this gate |
| 4c | PR 4c | 14–15 | 2 | `forge test --match-path "test/exact/*"` (71 pass); MUST NOT modify `BaseSettler.sol` |
| 4d | PR 4d | 16–17 | 2 | `forge test --match-path "test/partial/*"` (94 pass); MUST NOT modify `BaseSettler.sol` |
| 4e | PR 4e | 18–20 | 3 | `forge test` — 288 all pass |

**Total: 8 runs, 17 agents.**

Run 4a → 4b → 4c → 4d → 4e, strictly sequential. BaseSettler is frozen after 4b, so neither 4c nor 4d modifies shared source, but the conventions in this plan forbid cross-task parallelism regardless — agents step on shared state (remappings, harness, test snapshots, CI). If a future run has tighter time constraints, the freeze discipline in Task 13 is what makes parallelism *safe*; this plan still forbids it as *policy*.

If during 4c or 4d a real need to modify BaseSettler emerges (e.g., a missed virtual hook), the chain breaks: pause both, open an amendment PR off `feat/settler-base`, re-merge into `feat/settlers`, re-run 4c and 4d gates. This is the cost of the freeze rule and the reason 4b's interface design (Task 13) carries the "canonical, frozen" discipline.

### Merge order

1. Merge PR 1 → main, rebase PR 2.
2. Merge PR 2 → main, rebase PR 3.
3. Merge PR 3 → main, rebase PR 4.
4. Merge PR 4 sub-PRs into `feat/settlers`: 4a → 4b → 4c → 4d → 4e.
5. Merge PR 4 → main.

### Rebase discipline between sub-PRs

Each sub-PR rebases on the current `feat/settlers` tip after its parent is merged. Standard conflict-resolution workflow:

```bash
git fetch origin
git checkout feat/settler-exact
git rebase origin/feat/settlers
# resolve conflicts (most likely in test/BaseTestSettler.sol if 4a was touched)
git push --force-with-lease
```

Never use `--no-verify` to skip hooks.

### Mid-plan submodule bump procedure

Cellar-private's submodule SHA **should not** change during this plan's execution. The expected wall-clock from PR 1 to PR 4 merge is 2–4 weeks across 8 execute-cork runs; in that window the cellar may still ship bugfixes. If a mid-plan bump becomes necessary (cellar ships a security fix, bumps a transitive dep, or fixes a `BaseTestCorkCellar` helper this plan depends on), follow this procedure unconditionally. It is deterministic by design — the "does this bump affect us?" judgment call happens in step 2, not step 3.

1. **Pause all open sub-PR merges** into `feat/settlers`. Notify downstream agents to stop dispatch.
2. **Land the bump on `main`** as a standalone PR-1-class change (see `plan/test-spec.md` §2.2): `chore(deps): bump lib/cellar to <short-SHA>`. The PR body MUST classify the bump in a `Blast Radius:` line as one of:
   - **`rollover-affecting`** — bump touches any of: `CorkCellar` / `CorkCellarFactory` public ABI, `CellarIntent` / `OrderData` shapes or type hashes, `BaseTestCorkCellar` helper signatures this repo imports, module registrations, or Phoenix interfaces rollover contracts call. Diff review required.
   - **`rollover-neutral`** — everything else (internal cellar refactors, cellar-internal tests, comment-only changes, unrelated subcontracts).
3. **Apply the policy per blast radius** (deterministic — no judgment at this step):
   - **`rollover-affecting`:** rebase every open sub-PR on the new `feat/settlers` tip, resolve conflicts, re-run each sub-PR's gate from scratch, update each PR description with the gate-rerun timestamp. A passing gate before the bump does NOT carry over.
   - **`rollover-neutral`:** no rebase required. Open sub-PRs merge as-is. The next sub-PR to rebase (because its parent merged) picks up the new SHA naturally. Gate reruns are not required.
4. **For 4c ∥ 4d in flight under `rollover-affecting`:** if the bump requires `BaseSettler` changes (rare — e.g., cellar adds a new factory entry point BaseSettler must call), the freeze rule from §"Task 13" applies: the bump goes through 4b's amendment path (a new 4b-amendment PR off `feat/settler-base`), which re-triggers 4c and 4d gate reruns once the amendment merges.
