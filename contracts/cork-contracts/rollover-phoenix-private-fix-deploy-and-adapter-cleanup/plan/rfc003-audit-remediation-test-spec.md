# RFC 003 Audit Remediation — Test Specification

> Companion to `plan/rfc003-audit-remediation-plan.md`. Covers the test-side deliverables for each of the 15 code PRs closing 26 open GitHub issues against RFC 003.
>
> Tests use the **Branching Tree Technique (BTT)**: one `.tree` file per function defines the control-flow tree; each leaf (`it should ...`) becomes a test case. Trees are the source of truth.
>
> **Test organization:** Co-located — each `.tree` file lives next to its `.t.sol` in the same domain folder. Match the shape of the existing `test/base/`, `test/exact/`, `test/partial/`, `test/erc6909/`, `test/integration/`, `test/invariant/`, `test/filler/`, `test/libs/` tree.
>
> **Mocking policy:** Use the **real** `CorkCellar` + `CorkCellarFactory` via `BaseTestCorkCellar`. `MockBaseSettler` is the only allowed mock on the settler surface. The `rescueable` try/catch path in PR 7 requires a malicious-recipient mock — use a minimal `MaliciousERC20Recipient` that reverts on `transfer` to a flagged address. Do not mock cellar or factory.
>
> **Invariant discipline:** All invariants run under the default Foundry profile. Per-PR gate runs `forge test --match-contract "*Invariant*"` without `FOUNDRY_PROFILE=ci`. The `.github/workflows/unit.yaml` Step 6 (CI profile for EVC adapter invariants) is untouched by this plan.

---

## Table of Contents

1. [Test Methodology](#1-test-methodology)
2. [Test Infrastructure](#2-test-infrastructure)
3. [BTT Leaf Inventory per PR](#3-btt-leaf-inventory-per-pr)
4. [Invariant Matrix Updates](#4-invariant-matrix-updates)
5. [Fixture Notes](#5-fixture-notes)
6. [File Layout](#6-file-layout)

---

## 1. Test Methodology

BTT unchanged from `plan/test-spec.md` §1. Root node = test contract name; `when` nodes = modifiers; `it should` leaves = test functions. Scaffolding via `bulloak scaffold`; `bulloak check` in CI keeps trees and tests in sync.

**One test contract per function.** Each inherits `BaseTestSettler` and tests exactly one entry point.

### Per-PR TDD discipline

Every PR writes its new `.tree` leaves first, scaffolds `.t.sol`, confirms all new leaves fail red, then adds implementation. The PR's gate includes a "new leaves all green" check.

---

## 2. Test Infrastructure

`BaseTestSettler` is already in place from the prior plan. PR-specific fixture additions are noted inline per PR below; no structural changes to the harness.

### Known extensions introduced by this plan

| PR | Fixture addition | Location |
|---|---|---|
| 1 | Order builder accepts `minFillSize` + `exclusiveFiller` | `BaseTestSettler._createRolloverOrder` |
| 3 | `_assertTerminalPredicateMeetsP16` helper consolidated from Partial-only scope | `BaseTestSettler` |
| 4 | 4 deploy paths for the split filler set | `BaseTestSettler._deployFillers` |
| 5 | `MaliciousERC20Recipient` + FoT `DummyFoTToken` | `test/fixtures/` |
| 6 | Rescue signature helper `_signRescue(orderDigest, orderId, fallbackDest, wallet)` | `BaseTestSettler` |
| 7 | Cellar mock with conditional-revert premium hooks | `test/fixtures/ConditionalRevertCellar.sol` (only if real cellar cannot express the scenario) |
| 9 | Transient-slot probe helper `_readPremiumFillerSlot()` | `BaseTestSettler` |
| 10 | Identity-join assertion `_assertAttributionConsistent(event)` | `BaseTestSettler` |

All fixtures are additive — no pre-existing test state is invalidated.

---

## 3. BTT Leaf Inventory per PR

> **Amendment 2026-04-24.** PRs renumbered after PR #65 landed. Old PR 2 (encoder, #52) and old PR 6 (nonReentrant, #50) removed — their fixes landed on `main` via commits `8915c61` and `1ec403c`. Old PR 4 re-scoped: #36, #38, #51 landed via `fafcf65`, `d7719c6`, `a438194` and are now pre-existing BTT coverage to preserve rather than add. This spec's PR numbers below match the amended plan (12 code PRs + 1 cork-knowledge).

Per-PR new leaves. Totals are approximate (~235 new leaves across the stack) and rounded to the nearest 5.

### PR 1 — `fix/as19-as21-ingress-gates` (≈26 leaves)

> **Amendment 2026-04-24 (cycle-2).** AS-20 decimal-source reconciled with RFC §6.2. Implementation reads `IPoolManager(poolManager).market(od.srcPoolId).collateralAsset.decimals()` via `IPoolShare(od.srcCstToken).poolManager()`, not `srcCstToken.decimals()` (see cycle-2 review B1 and plan Task 2 amendment). Residual-truncation gate is now `ResidualTruncates` (AS-22 plan-extension); the pre-amendment `TipTruncates` name is removed. Leaf inventory below adds three AS-20 leaves per concrete — two revert / two happy with a 6-decimal fixture and a no-op leaf for 18-decimal collateral.

**Trees added / modified:**

- `test/base/BaseSettler_fill.tree` (if it exists — else the equivalent trees on each concrete's `fill`):
  - `when od.exclusiveFiller != address(0) AND msg.sender != od.exclusiveFiller → it should revert NotExclusiveFiller` (×2, Exact + Partial)
  - `when output.amount < od.minFillSize → it should revert BelowMinFillSize` (×2)
  - `when Partial fill leaves residual 0 < r < minFillSize → it should revert ResidualTruncates`
  - `when collateralAsset decimals are 6 AND rollover output.amount is aligned → it should accept the fill` (×2, Exact + Partial — AS-20 happy path)
  - `when collateralAsset decimals are 6 AND rollover output.amount is unaligned → it should revert DecimalTruncates` (×2, Exact + Partial — AS-20 revert path)
  - `when collateralAsset decimals are 18 or greater → gate is a no-op regardless of amount modulo` (×2, Exact + Partial — AS-20 early-return edge)
  - Happy-path leaves confirming each gate passes when its precondition is met (×5)
- `test/libs/LibRolloverOrder.t.sol`:
  - `encode OrderData with minFillSize + exclusiveFiller round-trips byte-exact`
  - `decode OrderData rejects legacy 17-field encoding with InvalidFieldCount` (defensive leaf)
- `test/libs/LibSettlerHashing.t.sol`:
  - `ORDER_DATA_TYPE_HASH includes minFillSize + exclusiveFiller in preimage`
  - `computeOrderDigest changes when minFillSize changes` (identity)
  - `computeOrderDigest changes when exclusiveFiller changes` (identity)
  - 5-field-changed-produces-different-digest matrix (×5 incremental leaves for future PR 3 coverage — leave as sketch)

**Fixtures added:**
- `DummyERC20("USDC", "USDC", 6)` — 6-decimal collateral used by AS-20 revert / happy leaves.
- AS-20 gate mock chain (`vm.mockCall` on `IPoolShare.poolManager` + `IPoolManager.market` selectors) — wired into `BaseTestSettler.setUp` as a default 18-decimal no-op, and overridden per-test via `_mockMarketForPool(srcPoolId, collateralAsset)`.

### PR 2 — `fix/compute-order-digest-identity` (≈8 leaves)

**Trees added / modified:**

- `test/libs/LibSettlerHashing.t.sol`:
  - `computeOrderDigest omits cellarIntentHash` (×1 — deliberate omission; see library NatSpec for construction-time fixed-point reasoning)
  - `computeOrderDigest changes when rolloverHooks differ` (×1)
  - `computeOrderDigest changes when premiumHooks differ` (×1)
  - `computeOrderDigest changes when repaymentToken differs` (×1)
  - `computeOrderDigest changes when repaymentAmount differs` (×1)
- `test/integration/RolloverLifecycle.t.sol`:
  - `test_e2e_digestCollisionScenario_nowBlocked`: two same-maker orders differing only in `rolloverHooks`, both open successfully, their `orderIdOf[digest]` do NOT alias.
- `test/partial/PartialFillSettler_openFor.tree`:
  - `when two orders differ only in previously-omitted field → orderIdOf[digest] stores both distinctly` (×2 — one leaf per newly-hashed field type: ref-type + value-type)

**Amendment 2026-04-24 (cycle 1)**: §1g.5 **ENDORSE** on the `cellarIntentHash` exclusion. The original "changes when cellarIntentHash differs" leaf was replaced with an `OmitsCellarIntentHash` leaf asserting the deliberate omission — rationale documented in `LibSettlerHashing.sol` NatSpec and in the matching plan Task 5 amendment. The construction-time fixed-point blocks maker-side digest computation; collision defence from #41 is preserved because every intent field except `orderDigest` itself is bound directly in the digest or deterministically derived from a bound field. `test_computeOrderDigest_vectorA` now asserts both the re-derivation path (ABI-stability regressions) AND a pinned hex literal (silent-drift detection) — see N3 in the cycle-1 review report.

### PR 3 — `fix/terminal-and-settler-symmetry` (≈20 leaves)

Settler refactor touches both concretes' leg handlers, finalise paths, and terminal predicates. Amendment: #36, #38, #51 leaves already exist on `main` from PR #65 — preserve them, do **not** re-add as new leaves. Only new work here is the shared-primitive trees and the `uint256` width unification.

**Trees added / modified:**

- `test/base/BaseSettler_lookupFillerEscrow.tree` (new, 4 leaves — virtual dispatch correctness on both concretes)
- `test/base/BaseSettler_recordFillerEscrow.tree` (new, 5 leaves)
- `test/base/BaseSettler_transitionIfTerminal.tree` (new, 8 leaves — covers both Exact single-participant and Partial multi-participant terminal predicates; **retains** `participantCount == 0 early-return` coverage landed in `fafcf65`)
- `test/exact/ExactFillSettler_onRolloverLegFill.tree` + `test/partial/PartialFillSettler_onRolloverLegFill.tree`:
  - `FillRecord.dstCstProduced uint256 width — no overflow on large rolls` (#53; ×2)
- Storage-layout assertion tests (new, one per concrete): `test_storage_dstCstProducedWidth_uint256`.
- **Pre-existing leaves to preserve (must remain green after refactor):**
  - `PartialFillSettler_finaliseAsSettled.tree` — `fillers.length == 0 → reverts InvalidFillers` (from `fafcf65`, #36)
  - `PartialFillSettler_finaliseAsSettled.tree` — `participantCount == 0 → early-return` (from `fafcf65`, #36)
  - `PartialFillSettler_onPremiumLegFill.tree` — `targetFiller mismatch without operator → reverts TargetFillerMismatch` (from `d7719c6`, #38)
  - `ExactFillSettler_onRolloverLegFill.tree` — `actualRolled == 0 → reverts ZeroRollover` (from `a438194`, #51)

### PR 4 — `refactor/filler-pair-split` (≈40 leaves)

**Trees added / modified:**

- New tree sets:
  - `test/filler/exact/ExactRolloverFiller_execute.tree` + `.t.sol`
  - `test/filler/partial/PartialRolloverFiller_execute.tree` + `.t.sol`
  - `test/filler/evc/exact/EvcExactFillAdapter_execute.tree` + `.t.sol`
  - `test/filler/evc/partial/EvcPartialFillAdapter_execute.tree` + `.t.sol`
- Each tree duplicates the branch coverage of the pre-split `RolloverFiller` / `EvcRolloverAdapter`, scoped to its threat model.
- `test/filler/evc/invariant/*` invariant suites retarget to `EvcExactFillAdapter` + `EvcPartialFillAdapter` (no leaf count change; target change only).
- Trust-boundary NatSpec assertion leaves: one leaf per contract asserting that the contract's top-level `@custom:threat-model` tag is the expected string. (Cheap, forces future refactors to update the tag.) solc 0.8.30 forces the dashed form — camelCase `@custom:threatModel` triggers `Error 2968: Invalid character in custom tag @custom:threatModel. Only lowercase letters and "-" are permitted.`

**Amendment 2026-04-25 (cycle 1):** PR #69 cycle-1 review verdict ACCEPT on the `@custom:threat-model` tag casing deviation. Verified with solc 0.8.30. Runtime-asserted strings (`shared-singleton`, `per-subaccount`) are unchanged.

### PR 5 — `fix/token-quirk-defence` (≈10 leaves)

- `test/erc6909/ERC6909Premium_deposit.tree`:
  - `when FoT token transferFrom delivers less than amount → it should revert DepositBalanceMismatch` — **already landed via `0cdb91c`**; confirm the existing leaf covers FoT; do **not** add new leaves if present.
- `test/erc6909/ERC6909Premium_settle.tree`:
  - `when FoT token transfer delivers less than amount → it should revert SettleBalanceMismatch`
  - Mirror for `transferFrom`-variant leaks if applicable
- `test/partial/PartialFillSettler_finaliseAsSettled.tree`:
  - `when dstCST.safeTransfer reverts for one filler → rescueable[orderDigest][filler] credits amount; f.finalised = true; FillerRescueCredited emitted`
  - `when dstCST.safeTransfer reverts for one of three fillers → the other two still get paid; only the third credits rescueable`
- `test/exact/ExactFillSettler_finaliseAsSettled.tree`:
  - `when dstCST.safeTransfer reverts → rescueable[orderId][filler] credits; f.finalised = true`
- `test/integration/RolloverLifecycle.t.sol`:
  - `test_e2e_usdcBlacklistMidOrder`: 3-filler Partial; mid-finalise one destination is blacklisted; other two paid, third rescueable.

### PR 6 — `feat/stranded-value-rescue` (≈14 leaves)

- `test/exact/ExactFillSettler_rescueSettled.tree` (new):
  - `when rescueable[orderId][filler] == 0 → it should revert NothingToRescue`
  - `when sig is invalid → it should revert InvalidRescueSignature`
  - `when sig recovers to non-filler → it should revert InvalidRescueSignature`
  - `when all checks pass → transfer amount to fallbackDestination; zero rescueable; emit FillerRescueWithdrawn`
  - `when called twice with same sig → second call reverts NothingToRescue` (replay blocked by zeroing)
- `test/partial/PartialFillSettler_rescueSettled.tree` (new):
  - Mirror of the above leaves for the Partial orderDigest-keyed mapping (×5)
- `test/integration/RolloverLifecycle.t.sol`:
  - `test_e2e_rescueAfterBlacklistStrands`: continuation of PR 5's integration — filler signs rescue, withdraws to a fresh non-blacklisted address.

### PR 7 — `fix/seam-as10-phase0` (≈10 leaves)

- `test/partial/PartialFillSettler_onPremiumLegFill.tree`:
  - `when phase-1 forward reverts → PremiumHooksReverted emitted with err bytes`
  - `when phase-1 forward reverts → f.premiumSettled stays true (committed)`
  - `when phase-1 forward reverts → finaliseAsSettled for this filler proceeds normally on later call`
- `test/exact/ExactFillSettler_onPremiumLegFill.tree`:
  - Mirror set (×3)
- `test/integration/RolloverLifecycle.t.sol`:
  - `test_e2e_premiumHookConditionalRevert_noWindfall`: UW signs premium hooks that revert based on `block.number & 1`; 2 fillers; after `fillDeadline`, `finaliseAsSettled` still routes dstCST to both. (Pre-fix: these dstCST would have been windfalled to cellar via `finaliseAsRefunded`.)

### PR 8 — `fix/seam-cei-premium-leg` (≈4 leaves)

- `test/partial/PartialFillSettler_onPremiumLegFill.tree`:
  - `when forward succeeds → premiumSettled writes AFTER forward returns (order-of-writes assertion)`
  - `when forward catches → premiumSettled still writes (order-of-writes assertion)`
- `test/exact/ExactFillSettler_onPremiumLegFill.tree`:
  - Mirror (×2)

Order-of-writes is asserted via an event log probe that records settler state at each external call boundary — add `_recordWriteOrder(label)` helper to `BaseTestSettler` if one isn't already present.

### PR 9 — `feat/seam-state-parity-assertion` (≈8 leaves)

- `test/partial/PartialFillSettler_onPremiumLegFill.tree`:
  - `when cellar.premiumFiredFor[d][targetFiller] == false after successful forward → it should revert StateDivergence`
  - `when cellar.premiumFiredFor[d][targetFiller] == true → accepts`
  - `settler writes PREMIUM_FILLER_SLOT before forward and premiumFillerSlot() returns it` (view-accessor probe; ×1 — asserts settler `tstore`s the slot and its own `premiumFillerSlot()` view `tload`s the same value back within the phase-1 window)
- `test/exact/ExactFillSettler_onPremiumLegFill.tree`:
  - Mirror (×3)
- `test/integration/RolloverLifecycle.t.sol`:
  - `test_e2e_premiumFillerSlotCrossChecksCellar`: integration leaf. Write as `vm.skip(true)` with a tracking comment if the cellar-side companion PR has not merged at execution time; unskip and extend coverage once cellar lands. Scenario body (for the unskip): run a full happy-path rollover end-to-end; assert the settler wrote `targetFiller` to `PREMIUM_FILLER_SLOT` and the live cellar read it back via `ICorkCellarFactory.originatingSettler()` + the `premiumFillerSlot()` view; drive the divergent-filler fixture and assert the cellar reverts with its filler-mismatch error.
- Amended 2026-04-25 (cycle 1): transient-slot probe leaf updated to match the view-accessor reshape (settler-internal `tload` via `premiumFillerSlot()`, per EIP-1153 per-contract scoping). Cellar-side companion reads the view cross-contract; it does not `tload` the slot from its own context.

### PR 10 — `feat/order-attribution-event` (≈8 leaves)

- `test/partial/PartialFillSettler_finaliseAsSettled.tree`:
  - `emits OrderAttribution per filler slot`
  - `OrderAttribution.fillerSlot == OrderAttribution.premiumFiller == OrderAttribution.cellarFiller on happy path`
  - `balance-floor assertion after transfer loop holds`
- `test/exact/ExactFillSettler_finaliseAsSettled.tree`:
  - `emits OrderAttribution once`
  - `balance-floor assertion holds`
- `test/invariant/SettlerInvariantHandler.sol` (extension):
  - Ghost variable `ghost_attributionEmitted` map.
- `test/invariant/PartialFillInvariantTest.t.sol`:
  - `invariant_P_attributionEventParity`: every filler slot that had `f.finalised = true` has exactly one `OrderAttribution` emission.
- `test/invariant/ExactFillInvariantTest.t.sol`:
  - Same invariant for Exact.

### PR 11 — `docs/filler-trust-boundary` (≈3 leaves)

- `test/integration/BlockedSettlerRevertsAllWrites.t.sol` (new):
  - `test_blockedSettler_allWritesRollBack`: block the settler on the factory; attempt `fill`; assert all storage writes revert.
- Docstring assertions: a small test parses the NatSpec from the ABI and asserts the expected marker tags (`@custom:trustBoundary`, `@custom:atomicRevertInvariant`) are present on the two documented functions. Optional — drop if the Foundry `toolchain` doesn't expose ABI NatSpec cleanly.

### PR 12 — `fix/deploy-and-adapter-cleanup` (≈5 leaves)

- `test/script/DeploySettlers.t.sol`:
  - `when networks.json has no CorkCellarFactory entry AND no env override → it should revert FactoryNotConfigured`
  - `when COWShedFactory key present but CorkCellarFactory absent → it should revert FactoryNotConfigured` (fallback removed)
- `test/filler/evc/exact/EvcExactFillAdapter.t.sol`:
  - `when controllerToCheck is configured AND controllerEnabled == true → accepts`
  - `when controllerToCheck is configured AND controllerEnabled == false → reverts ControllerNotEnabled`
- `test/libs/LibSettlerHashing.t.sol`:
  - `computeOrderDigest docstring reflects first/second concatenation chunks` (presence check via source grep if ABI NatSpec not available).

### PR 13 — cork-knowledge (no new Solidity leaves)

No code in this repo changes. The PR modifies RFC prose + adds a decision record in the cork-knowledge repo. A token smoke test that reads the RFC digest definition from docs is out of scope.

---

## 4. Invariant Matrix Updates

### Additions per PR

| PR | Invariant | Location | Description |
|---|---|---|---|
| 1 | `invariant_S_noFillBelowMinFillSize` | `ExactFillInvariantTest` + `PartialFillInvariantTest` | No successful fill has `output.amount < od.minFillSize`. |
| 1 | `invariant_S_noFillByNonExclusive` | same | If `od.exclusiveFiller != 0`, every fill has `msg.sender == od.exclusiveFiller`. |
| 2 | `invariant_S_digestUniquePerSemanticOrder` | `ExactFillInvariantTest` + `PartialFillInvariantTest` | Two orders with any distinguishable field produce distinct `orderDigest`. |
| 3 | `invariant_S_dstCstProducedUint256` | both | Storage-layout check: `FillRecord.dstCstProduced` / `FillerRollover.dstCstProduced` are `uint256`, no narrow cast in the write path. |
| 3 | `invariant_P_terminalRequiresParticipants` | `PartialFillInvariantTest` | `_transitionIfTerminal` never flips status with `participantCount == 0`. (Preserves existing guard from `fafcf65`.) |
| 5 | `invariant_S_rescueableCreditedOnPayoutRevert` | both | Every reverted `safeTransfer` in `finaliseAsSettled` corresponds to a `rescueable` credit for that `(orderDigest or orderId, filler)` pair. |
| 7 | `invariant_S_premiumHookRevertDoesNotUnwindSettled` | both | `f.premiumSettled` is never false after a successful `_settlePremium` regardless of phase-1 hook outcome. |
| 9 | `invariant_S_premiumFiredForMatchesSettled` | both | For every `f.premiumSettled == true`, cellar's `premiumFiredFor[d][f] == true` (success-branch only). |
| 10 | `invariant_S_attributionEventParity` | both | Every filler slot that reached `finaliseAsSettled` happy path emitted exactly one `OrderAttribution`. |
| 10 | `invariant_S_balanceFloor` | both | `IERC20(dstCstToken).balanceOf(settler) >= Σ remaining escrow for non-finalised slots`. |

### Profile

All invariants run under the default Foundry `[invariant]` profile (`runs=32, depth=15` as per current `foundry.toml`). Per-PR gates invoke:

```bash
forge test --match-contract "*Invariant*"
```

**Never** set `FOUNDRY_PROFILE=ci` in the per-PR gate — that profile runs the EVC adapter invariants under the deeper `runs=5000, depth=50` configuration and is reserved for CI Step 6, which is not modified by this plan.

---

## 5. Fixture Notes

### `DummyFoTToken` (PR 7)

Minimal ERC-20 with a configurable basis-point fee on every transfer. Constructor: `(uint256 feeBp)`. Transfers deduct `amount * feeBp / 10_000` from the recipient. Used to exercise the `DepositBalanceMismatch` + `SettleBalanceMismatch` reverts.

### `MaliciousERC20Recipient` (PR 7)

Contract that reverts on `onERC20Received`-style callback, or a token wrapper that reverts `safeTransfer` when the destination is flagged. Used for the blacklist simulation in `test_e2e_usdcBlacklistMidOrder`.

### `ConditionalRevertCellar` (PR 9, optional)

Only if the real cellar cannot express "premium hooks revert based on block number". Minimal subclass of `CorkCellar` with one overridden `_runPremiumPhase` that reverts when a flag is set. Scope: single test, dispose after PR 9 merges. If the real cellar supports hook injection that can revert, use that instead.

### Rescue signature helper (PR 8)

```solidity
function _signRescue(
    bytes32 orderDigest,
    bytes32 orderId,
    address fallbackDestination,
    Vm.Wallet memory wallet,
    address settler
) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(
        RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination
    ));
    bytes32 digest = _hashTypedDataV4(settler, structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
    return abi.encodePacked(r, s, v);
}
```

Lives on `BaseTestSettler`. The `RESCUE_TYPEHASH` is defined by the settler and imported into the test contract.

### Transient-slot probe (PR 11)

```solidity
function _readPremiumFillerSlot() internal view returns (address filler) {
    bytes32 slot = PREMIUM_FILLER_SLOT;
    assembly { filler := tload(slot) }
}
```

Used to assert "settler wrote the slot before the forward" without relying on cellar-side observation.

---

## 6. File Layout

Additive layout; existing paths unchanged except where PR 5 splits filler directories.

```
test/
├── base/                              (BaseSettler trees + MockBaseSettler)
│   ├── BaseSettler_domainSeparator.tree / .t.sol
│   ├── BaseSettler_recover.tree / .t.sol
│   ├── BaseSettler_forwardToFactory.tree / .t.sol
│   ├── BaseSettler_settlePremium.tree / .t.sol
│   ├── BaseSettler_fill.tree / .t.sol                      (PR 1 additions)
│   ├── BaseSettler_lookupFillerEscrow.tree / .t.sol        (PR 3 new)
│   ├── BaseSettler_recordFillerEscrow.tree / .t.sol        (PR 3 new)
│   └── BaseSettler_transitionIfTerminal.tree / .t.sol      (PR 3 new)
├── exact/
│   ├── ExactFillSettler_*.tree / .t.sol                    (PRs 1, 3, 5, 7, 8, 9, 10 modify)
│   └── ExactFillSettler_rescueSettled.tree / .t.sol        (PR 6 new)
├── partial/
│   ├── PartialFillSettler_*.tree / .t.sol                  (PRs 1, 2, 3, 5, 7, 8, 9, 10 modify)
│   └── PartialFillSettler_rescueSettled.tree / .t.sol      (PR 6 new)
├── erc6909/
│   ├── ERC6909Premium_deposit.tree / .t.sol
│   ├── ERC6909Premium_settle.tree / .t.sol                 (PR 5 modifies)
│   ├── ERC6909Premium_withdraw.tree / .t.sol
│   ├── ERC6909Premium_setOperator.tree / .t.sol
│   ├── ERC6909Premium_balanceOf.tree / .t.sol
│   └── ERC6909Premium_isOperator.tree / .t.sol
├── filler/                            (PR 4 reorganisation)
│   ├── exact/
│   │   └── ExactRolloverFiller_execute.tree / .t.sol       (PR 4 new)
│   ├── partial/
│   │   └── PartialRolloverFiller_execute.tree / .t.sol     (PR 4 new)
│   └── evc/
│       ├── exact/
│       │   └── EvcExactFillAdapter_execute.tree / .t.sol   (PR 4 new; PR 12 modifies)
│       ├── partial/
│       │   └── EvcPartialFillAdapter_execute.tree / .t.sol (PR 4 new)
│       └── invariant/                                        (PR 4 retargets)
├── libs/
│   ├── LibRolloverOrder.t.sol                              (PR 1 modifies)
│   └── LibSettlerHashing.t.sol                             (PRs 1, 2, 12 modify)
├── integration/
│   ├── RolloverLifecycle.t.sol                             (PRs 2, 5, 6, 7, 9 append)
│   └── BlockedSettlerRevertsAllWrites.t.sol                (PR 11 new)
├── invariant/
│   ├── SettlerInvariantHandler.sol                         (PRs 1, 3, 5, 7, 9, 10 extend handlers)
│   ├── ExactFillInvariantTest.t.sol                        (new invariants per §4)
│   ├── PartialFillInvariantTest.t.sol                      (new invariants per §4)
│   ├── ERC6909PremiumInvariantHandler.sol                  (PR 5 extends)
│   └── ERC6909PremiumInvariantTest.t.sol
├── fixtures/
│   ├── DummyFoTToken.sol                                   (PR 5 new)
│   ├── MaliciousERC20Recipient.sol                         (PR 5 new)
│   └── ConditionalRevertCellar.sol                         (PR 7 new, only if needed)
└── script/
    └── DeploySettlers.t.sol                                (PR 12 modifies)
```

---

## Summary

| PR | New/Modified Leaves | Key Surface |
|---|:---:|---|
| 1 | ~20 | 3 ingress gates + OrderData schema |
| 2 | ~8 | Digest identity completeness |
| 3 | ~20 | Settler symmetry refactor (preserves #36/#38/#51 leaves) |
| 4 | ~40 | Filler split into 4 reference contracts |
| 5 | ~10 | Delta-accounting (settle side only) + try/catch payouts |
| 6 | ~14 | `rescueSettled` pull path |
| 7 | ~10 | Phase-1 try/catch for AS-10 close |
| 8 | ~4 | Premium-leg write-order alignment |
| 9 | ~8 | State-parity assertion + `PREMIUM_FILLER_SLOT` |
| 10 | ~8 | Attribution event + balance-floor invariant |
| 11 | ~3 | Trust-boundary NatSpec + blocked-settler integration |
| 12 | ~5 | Deploy script cleanup + EVC controller tightening |
| 13 | — | cork-knowledge docs (no Solidity) |
| **Total** | **~150** | 21 open issues closed (5 others already closed by PR #65) |
