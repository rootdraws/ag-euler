// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcAdapterInvariantHandler} from "test/filler/evc/invariant/EvcAdapterInvariantHandler.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";

/// @title EvcAdapterInvariantTest
/// @notice Invariant fuzz driver for `EvcExactFillAdapter` / `EvcPartialFillAdapter` properties
///         INV-F1, F2, F4, F5, F6, F7, F8. The handler distributes actions across both
///         Exact-bound and Partial-bound adapters; each `invariant_Fn_*` function below asserts
///         one RFC 003 §7.5-derived property against the cumulative ghost state built up over
///         the fuzz campaign.
/// @dev INV-F3 (caller receives leftover) is intentionally dropped — the reference adapter does
///      not sweep leftovers per RFC 003 §7.3 / DP-EVC-C. Curators compose sibling sweep steps.
contract EvcAdapterInvariantTest is Test {
    EvcAdapterInvariantHandler internal handler;

    function setUp() public {
        handler = new EvcAdapterInvariantHandler();

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = EvcAdapterInvariantHandler.actionExecuteExactHappy.selector;
        selectors[1] = EvcAdapterInvariantHandler.actionExecutePartialHappy.selector;
        selectors[2] = EvcAdapterInvariantHandler.actionExecuteZeroDestination.selector;
        selectors[3] = EvcAdapterInvariantHandler.actionExecuteInsufficientBalance.selector;
        selectors[4] = EvcAdapterInvariantHandler.actionExecuteDirectCall.selector;
        selectors[5] = EvcAdapterInvariantHandler.actionExecuteOverFunded.selector;
        selectors[6] = EvcAdapterInvariantHandler.actionExecuteCrossCallerTheft.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F1 — adapter holds no unexpected tokens
    // ═══════════════════════════════════════════════════════════════

    /// @notice INV-F1 — each adapter's token balance is bounded by the tracked srcCST excess
    ///         (no-sweep retention), and dstCST balance is zero unconditionally.
    function invariant_F1_adapterHoldsNoUnexpectedTokens() public view {
        uint256 nAdapters = handler.ghostAdaptersLen();
        for (uint256 a; a < nAdapters; ++a) {
            address adapter = handler.ghost_adapters(a);
            uint256 nToks = handler.ghostAdapterTokensLen(adapter);
            for (uint256 t; t < nToks; ++t) {
                address tkn = handler.ghostAdapterToken(adapter, t);
                uint256 expected = handler.ghost_adapterSrcCstExcess(adapter, tkn);
                assertLe(
                    IERC20(tkn).balanceOf(adapter),
                    expected == 0 ? 0 : expected,
                    "INV-F1: adapter token balance exceeds tracked excess"
                );
            }
            uint256 nDst = handler.ghostAdapterDstCstLen(adapter);
            for (uint256 d; d < nDst; ++d) {
                address dstTkn = handler.ghostAdapterDstCst(adapter, d);
                assertEq(IERC20(dstTkn).balanceOf(adapter), 0, "INV-F1: adapter holds dstCST");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F2 — no dangling approvals from the adapter
    // ═══════════════════════════════════════════════════════════════

    function invariant_F2_noDanglingApprovals() public view {
        uint256 nAdapters = handler.ghostAdaptersLen();
        for (uint256 a; a < nAdapters; ++a) {
            address adapter = handler.ghost_adapters(a);
            uint256 nToks = handler.ghostAdapterAllowanceTokensLen(adapter);
            uint256 nSpenders = handler.ghostAdapterAllowanceSpendersLen(adapter);
            for (uint256 t; t < nToks; ++t) {
                address tkn = handler.ghostAdapterAllowanceToken(adapter, t);
                for (uint256 s; s < nSpenders; ++s) {
                    address spender = handler.ghostAdapterAllowanceSpender(adapter, s);
                    assertEq(IERC20(tkn).allowance(adapter, spender), 0, "INV-F2: dangling allowance");
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F4 — adapter holds zero ERC-6909 units
    // ═══════════════════════════════════════════════════════════════

    function invariant_F4_adapterHoldsNo6909() public view {
        uint256 nAdapters = handler.ghostAdaptersLen();
        address prem = handler.premiumContract();
        for (uint256 a; a < nAdapters; ++a) {
            address adapter = handler.ghost_adapters(a);
            uint256 nIds = handler.ghostAdapterErc6909IdsLen(adapter);
            for (uint256 i; i < nIds; ++i) {
                uint256 id = handler.ghostAdapterErc6909Id(adapter, i);
                assertEq(IERC6909Premium(prem).balanceOf(adapter, id), 0, "INV-F4: adapter ERC-6909 balance");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F5 — adapter never authorises anyone as its ERC-6909 operator
    // ═══════════════════════════════════════════════════════════════

    /// @notice INV-F5 — the adapter itself never calls `setOperator`, so for every (adapter,
    ///         actor) pair `isOperator(adapter, actor) == false`. Complementary to the subaccount-
    ///         side flips required for premium settlement.
    function invariant_F5_adapterNotOperator() public view {
        uint256 nAdapters = handler.ghostAdaptersLen();
        uint256 nActors = handler.ghostActorsLen();
        address prem = handler.premiumContract();
        for (uint256 a; a < nAdapters; ++a) {
            address adapter = handler.ghost_adapters(a);
            for (uint256 k; k < nActors; ++k) {
                address actor = handler.ghost_actors(k);
                assertFalse(IERC6909Premium(prem).isOperator(adapter, actor), "INV-F5: adapter authorised operator");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F6 — EVC caller resolution holds end-to-end (C1 strengthened)
    // ═══════════════════════════════════════════════════════════════

    /// @notice INV-F6 (strengthened per PR 3a cycle-1 C1) — for every successful happy-path
    ///         `execute` the settler's own state MUST show the adapter as the filler it saw. For
    ///         Exact: `fillRecords[orderId][rolloverOH].filler == address(adapter)` AND
    ///         `orderStatus == Settled`. For Partial: `fillerRollovers[digest][adapter]` has
    ///         `srcCstProvided != 0 && finalised == true`. The invariant asserts the handler's
    ///         settler-side observation counter matches the total settled count.
    /// @dev The earlier lockstep check (`ghost_resolvedCallerDebitCount == ghost_settledCount`) was
    ///      tautological — both counters were bumped together in the same try-branch. The
    ///      strengthened version reads independently from the deployed settler contract, so a bug
    ///      where the settler sees a different `msg.sender` (e.g. a future refactor that routed
    ///      through `evc.call` instead of a direct settler call) would surface as a counter
    ///      divergence.
    function invariant_F6_settlerSawAdapter() public view {
        assertEq(
            handler.ghost_settlerObservedAdapterCount(),
            handler.ghost_settledCount(),
            "INV-F6: settler-observed adapter count diverged from settled count"
        );
    }

    /// @notice INV-F6b — every successful happy-path `execute` leaves the `debitFrom` ERC-6909
    ///         premium balance equal to or below its pre-call value. Complements F6 with a direct
    ///         debit-side observation (C1). With the handler's zero-amount premium Output the
    ///         expected post-call balance equals the pre-call balance; a non-zero premium Output
    ///         would strictly decrease it.
    /// @dev Relative strength: F6 (`ghost_settlerObservedAdapterCount` vs `ghost_settledCount`)
    ///      carries the primary evidence that the settler saw the adapter as the caller — it is
    ///      independent of fuzz-generated premium amounts. F6b is a sanity check that only binds
    ///      meaningfully when `requiredPremium > 0`; with the current zero-amount premium Output
    ///      it is structurally weaker than F6. It would still fire if the adapter caused the
    ///      debitor balance to INCREASE post-fill, so it remains a useful guard against exotic
    ///      mis-routed-refund bugs.
    function invariant_F6b_debitFromBalanceNonIncreasing() public view {
        assertEq(
            handler.ghost_settlerDebitedDebitorCount(),
            handler.ghost_settledCount(),
            "INV-F6b: debitFrom balance-monotonicity observation diverged from settled count"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F7 — atomic revert parity (C2 split)
    // ═══════════════════════════════════════════════════════════════

    /// @notice INV-F7 — reverting `execute` actions MUST actually revert. A breach here means the
    ///         adapter silently accepted an invalid destination / insufficient pre-balance /
    ///         direct-call caller (i.e. `ghost_atomicFailures` was incremented in an
    ///         "unexpected success" branch).
    function invariant_F7_adapterReverts() public view {
        assertEq(handler.ghost_atomicFailures(), 0, "INV-F7: adapter unexpectedly succeeded on a revert action");
    }

    /// @notice INV-F7b — reverting `execute` actions MUST leave the adapter's observable state
    ///         (dstCST balance, settler allowance, ERC-6909 balance) unchanged from its pre-call
    ///         snapshot. Addresses PR 3a cycle-1 C2: the prior implementation used
    ///         `vm.revertToState` inside the parity check, which rolled back the counter writes
    ///         themselves — any "adapter reverts but leaves dirty state" breach was observed then
    ///         immediately erased. The new handler snapshots pre-call state in memory and compares
    ///         after the call returns; the counter now survives the action.
    function invariant_F7b_adapterRevertLeavesCleanState() public view {
        assertEq(
            handler.ghost_atomicDirtyStateFailures(), 0, "INV-F7b: adapter reverted but left observable state dirty"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F8 — adapter emits zero events
    // ═══════════════════════════════════════════════════════════════

    function invariant_F8_noEventsFromAdapter() public view {
        assertEq(handler.ghost_adapterEventCount(), 0, "INV-F8: adapter emitted events");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INV-F9 — cross-caller theft is impossible (B1)
    // ═══════════════════════════════════════════════════════════════

    /// @notice INV-F9 (B1) — pashov Critical-1. A curator subaccount (the seeder) pre-seeds a
    ///         per-subaccount `EvcExactFillAdapter` / `EvcPartialFillAdapter` with srcCST and
    ///         authorises ERC-6909 premium spend. A different curator subaccount (the attacker)
    ///         then dispatches an `evc.batch` targeting the seeder's adapter with
    ///         `onBehalfOfAccount = attacker`. The adapter's `AUTHORIZED_CALLER` gate MUST
    ///         reject, so the attacker's batch MUST revert. This invariant asserts the handler
    ///         never observed an attacker success.
    /// @dev Hand-verified once (plan Task 2): temporarily revert Task 1 and confirm this invariant
    ///      fails red against the reverted adapter. Then re-apply Task 1 and confirm it passes.
    function invariant_F9_noCrossCallerTheft() public view {
        assertEq(handler.ghost_crossCallerTheftSucceeded(), 0, "INV-F9: attacker drained cross-caller pre-seeded state");
    }
}
