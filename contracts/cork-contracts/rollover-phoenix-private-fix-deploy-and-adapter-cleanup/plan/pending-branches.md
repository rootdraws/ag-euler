# Pending Branches — Offline Push Deferral Log

Branches that have been committed locally but could not be pushed due to auth/network failure during the execute-cork run. Append-only — never delete rows, even after push succeeds.

## PR 1 — `chore/bump-solc-and-add-cellar-submodule`

| Field | Value |
|---|---|
| Branch | `chore/bump-solc-and-add-cellar-submodule` |
| Parent | `main` |
| HEAD SHA | `f2acb56` |
| Commits | `82931f5` (core bump + cellar submodule), `b078e1e` (foundry.lock), `f2acb56` (.vscode Solc pin) |
| Gate | `forge build` PASS (contracts/ empty, nothing to compile); `forge fmt --check` PASS (nothing to format) |
| Failure reason | `git push` — `Permission denied (publickey)`; SSH key not loaded in agent environment |
| Title | `PR 1: chore: bump Solc to 0.8.30, add lib/cellar submodule` |

### Body

```markdown
## Stack Position: 1/4

## Changes
- Solc 0.8.30, EVM prague, via_ir, optimizer_runs=1_000_000 (matches cellar-private).
- Add `lib/cellar` submodule pinned at `e194384b5be5f045d89f99d9de87f800d21457c3`.
- Remove unused `openzeppelin-contracts-upgradeable` (rollover ships no upgradeable contracts).
- Rewrite `remappings.txt` to resolve cellar-owned deps under `lib/cellar/`. Note `cellar/=lib/cellar/src/` — the pinned cellar SHA uses `src/` not `contracts/` at its source root.
- Add `docs/submodules.md` documenting pin policy.
- Commit `foundry.lock` with the pinned `lib/cellar` rev (forge install wrote the remote `develop` tip — manually corrected to match the gitlink).
- Bump `.vscode/settings.json` Solidity remote version to `v0.8.30+commit.73712a01`.

## Submodule pins
- `lib/cellar` = `e194384b5be5f045d89f99d9de87f800d21457c3`
- `lib/openzeppelin-contracts` = `5fd1781b1454fd1ef8e722282f86f9293cacf256` (v5.6.1, rollover-owned)
- `lib/forge-std` = `0844d7e1fc5e60d77b68e469bff60265f236c398` (v1.15.0, rollover-owned)
- OZ pin invariant: **OK** — root OZ v5.6.1 ≥ cellar-transitive OZ v5.0.2.

## Gate
- `forge build` passes (contracts/ empty — trivial).
- `forge fmt --check` passes.
- `git submodule status`: lib/cellar at pinned SHA, root OZ + forge-std present, openzeppelin-contracts-upgradeable absent.

## Deviations from plan
- Remap `cellar/=lib/cellar/src/` instead of plan default `lib/cellar/contracts/` — pinned cellar SHA uses `src/` layout.
- `.vscode/settings.json` bumped (plan mentioned CI/Hardhat/README only; this was an additional stale pin discovered during compliance re-check).
```

### Push command (to run when credentials are available)

```bash
git push -u origin chore/bump-solc-and-add-cellar-submodule
gh pr create --base main \
  --title "PR 1: chore: bump Solc to 0.8.30, add lib/cellar submodule" \
  --body-file <(sed -n '/^## Stack Position: 1\/4$/,/^### Push command/p' plan/pending-branches.md | head -n -2)
```

---

## PR 2 — `feat/settler-interfaces-and-libs`

| Field | Value |
|---|---|
| Branch | `feat/settler-interfaces-and-libs` |
| Parent | `chore/bump-solc-and-add-cellar-submodule` (PR 1) |
| HEAD SHA | `27a3432` |
| Commits | `891c07a` (Phase A — interfaces + LICENSE), `c3e1be5` (Phase B — libs + 22 tests + lint config), `27a3432` (Phase C — stubs + warning suppression) |
| Gate | `forge build` PASS; `forge test --match-path "test/libs/*"` 22/22 PASS; `forge fmt --check` PASS |
| Failure reason | `git push` — SSH auth blocked (same as PR 1) |
| Title | `PR 2: feat: settler interfaces + libs + reverting stubs` |

### Body

```markdown
## Stack Position: 2/4
**Base:** `chore/bump-solc-and-add-cellar-submodule` (PR 1)

## Changes

### Phase A — Interfaces + shared types (commit 891c07a)
- `contracts/interfaces/IOriginSettler.sol` + `IDestinationSettler.sol`: ERC-7683 verbatim.
- `contracts/interfaces/IRolloverTypes.sol`: shared `OrderStatus` enum + 13 shared errors at file scope.
- `contracts/interfaces/IExactFillSettler.sol`: extends ERC-7683 + `finaliseAsSettled/Refunded/Cancelled(orderId)` + 7 Exact-specific errors + `Fill`/`OrderFinalised` events.
- `contracts/interfaces/IPartialFillSettler.sol`: extends ERC-7683 + `finaliseAsSettled/Refunded(orderDigest, fillers[])` + `finaliseAsCancelled(orderId, …)` + `FillerRollover` struct + 7 Partial-specific errors + 3 events + `fillerRollovers`/`totalDstCstEscrowed` view getters.
- `contracts/interfaces/IERC6909Premium.sol`: deposit/withdraw/settle/setOperator + 3 dual-auth errors + `Settled` event.
- `LICENSE` (MIT) added at repo root.

### Phase B — Libraries + tests (commit c3e1be5)
- `contracts/libs/LibRolloverOrder.sol`: `OrderData` struct (17 Solidity fields, 16 hashed), 4 FillerData variants, encode/decode helpers, `extractCellarIntentFromOrderData` Exact-path helper.
- `contracts/libs/LibSettlerHashing.sol`: `ORDER_DATA_TYPE_HASH` + `CORK_ROLLOVER_ORDER_TYPE` constants, `computeOutputHash`/`OrderId`/`OrderDigest`. Settler passed as explicit arg (libraries cannot rely on `address(this)`).
- Schema overrides from partial-fill extension §5.2: `allowPartialFills` (plural), `allowUnderfill`, `cellarIntentHash` added; `minFillRatio` removed; `orderDigest` is 18 fields (not 19).
- Tests (22 total, all passing): `test/libs/LibRolloverOrder.t.sol` (10 leaves) + `test/libs/LibSettlerHashing.t.sol` (12 leaves).
- `foundry.toml`: `[lint] lint_on_build = false` — phoenix has a self-import that trips `forge lint`.

### Phase C — Reverting stubs (commit 27a3432)
- `contracts/settlers/BaseSettlerErrors.sol`: shared `NotImplemented()` error.
- `contracts/settlers/BaseSettler.sol`: abstract base with frozen constructor `(factory_, erc6909Premium_)`, `orderStatus` mapping (declared once), 5 internal virtuals (empty defaults), reverting external template methods. `ReentrancyGuard` deferred to PR 4b.
- `contracts/settlers/ExactFillSettler.sol`: reverts finalise entries.
- `contracts/settlers/PartialFillSettler.sol`: reverts finalise + view getters.
- `contracts/erc6909/ERC6909Premium.sol`: reverts all externals.
- `foundry.toml`: `ignored_error_codes = [2018]` — "state mutability can be restricted to pure" fires on every stub body because they all revert; real impls touch state. Revisit after PR 4e.

## Gate
- `forge build` PASS (37 files, zero warnings with suppressions active).
- `forge test --match-path "test/libs/*"` → 22/22 PASS.
- `forge fmt --check` PASS.

## Deviations from plan
- Tasks 5+6 shipped as one commit — the libraries mutually import (`LibRolloverOrder` → `LibSettlerHashing` for `computeOrderDigest`; `LibSettlerHashing` → `LibRolloverOrder` for `OrderData`). Separating them would require stubbing `extractCellarIntentFromOrderData` mid-commit.
- `settler` parameter added to `computeOrderId` and `computeOrderDigest`. Plan didn't specify the signature; libraries can't use `address(this)` meaningfully, so caller-passes is the only correct shape.
- `BaseSettlerErrors.sol` added as a shared-error file — plan didn't list it, but the `NotImplemented()` error had to live somewhere reachable by both `BaseSettler` and `ERC6909Premium`.
- `LICENSE` file added at repo root (MIT) — plan didn't list it; SPDX identifiers without a LICENSE file would be incoherent.
- `foundry.toml` touched three times (PR 1 added the Solc bump; PR 2's Phase B added `lint_on_build = false`; PR 2's Phase C added `ignored_error_codes = [2018]`). Each diff documents its reason inline.
```

### Push command

```bash
git push -u origin feat/settler-interfaces-and-libs
gh pr create --base chore/bump-solc-and-add-cellar-submodule \
  --title "PR 2: feat: settler interfaces + libs + reverting stubs" \
  --body-file <(sed -n '/^## Stack Position: 2\/4$/,/^### Push command$/p' plan/pending-branches.md | sed '$d' | sed '$d')
```

---

## PR 3 — `feat/erc6909-premium`

| Field | Value |
|---|---|
| Branch | `feat/erc6909-premium` |
| Parent | `feat/settler-interfaces-and-libs` (PR 2) |
| HEAD SHA | `15d4d12` |
| Commits | `15d4d12` (ERC6909Premium impl + 31 BTT tests) |
| Gate | `forge build` PASS; `forge test --match-path "test/erc6909/*"` 31/31 PASS; `forge test --match-path "test/libs/*"` 22/22 PASS (regression clean); `forge fmt --check` PASS |
| Failure reason | `git push` — SSH auth blocked |
| Title | `PR 3: feat: ERC6909Premium implementation + 31 BTT tests` |

### Body

```markdown
## Stack Position: 3/4
**Base:** `feat/settler-interfaces-and-libs` (PR 2)

## Changes

Standalone ownerless/immutable/no-pause premium escrow:
- `deposit` / `withdraw` / `settle` / `setOperator` + views / `supportsInterface`
- Dual-auth `settle()` per RFC 003 §A.5 (INV-E2): both `msg.sender` and `premiumFiller` must be authorised by `debitFrom`
- INV-S10 zero-amount short-circuit in `settle` (still emits `Settled`)
- CEI ordering on `withdraw` and `settle` (decrement before `safeTransfer`)
- `nonReentrant` on `withdraw` and `settle`; `deposit` needs no guard (CEI before credit)
- `supportsInterface` returns true for `IERC6909Premium` + EIP-6909 (0x0f632fb3) + EIP-165

## Interface amendments (IERC6909Premium)
- `event Transfer` (EIP-6909 standard — deposit/withdraw/internal moves)
- `event OperatorSet` (EIP-6909 standard — every `setOperator` call)
- `error InvalidRecipient` (withdraw to zero address)

These fill gaps in the Phase A interface draft — both events are mandated by EIP-6909 and the third error is mandated by the tree spec.

## Tests (31 leaves / 6 files)
- `ERC6909Premium_deposit.t.sol` (6) — transferFrom revert, zero no-op, happy path, supportsInterface x3
- `ERC6909Premium_withdraw.t.sol` (5) — insufficient, to==0, happy, token revert, reentrancy
- `ERC6909Premium_settle.t.sol` (11) — dual-auth x2, insufficient, zero no-op, happy x4, token revert, SafeERC20FailedOperation, reentrancy
- `ERC6909Premium_setOperator.t.sol` (4) — approved true/false, self, idempotent
- `ERC6909Premium_balanceOf.t.sol` (2) — zero default, net balance
- `ERC6909Premium_isOperator.t.sol` (3) — unset, true, true→false
- `test/erc6909/MockERC20.sol` — local test helper with toggles (revertOnTransfer / returnFalseOnTransfer / transferHook / revertOnTransferFrom)

## Gate
- `forge build` PASS (56 files, zero warnings)
- `forge test --match-path "test/erc6909/*"` → 31/31 PASS
- `forge test --match-path "test/libs/*"` → 22/22 PASS (regression clean)
- `forge fmt --check` PASS

## Deviations from plan
- bulloak v0.9.2 rejected the `.tree` leaf text (dots/commas). Tests written by hand with bulloak-compatible snake_case names so future regeneration produces compatible shapes.
- Interface extension (3 additions) rather than pure implementation — see "Interface amendments" above. Gaps in Phase A caught at PR 3 test scaffolding.
```

### Push command

```bash
git push -u origin feat/erc6909-premium
gh pr create --base feat/settler-interfaces-and-libs \
  --title "PR 3: feat: ERC6909Premium implementation + 31 BTT tests" \
  --body-file <(sed -n '/^## Stack Position: 3\/4$/,/^### Push command$/p' plan/pending-branches.md | sed '$d' | sed '$d')
```
