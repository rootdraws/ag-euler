// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FillerInvariantHandler} from "test/filler/invariant/FillerInvariantHandler.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";

/// @title FillerInvariantTest
/// @notice Invariant fuzz driver for `RolloverFiller` properties INV-F1..F5, F7, F8. The handler
///         distributes actions across both the Exact-bound and Partial-bound reference fillers;
///         each `invariant_Fn_*` function below asserts one RFC 003 §7.5 / §7.2-derived property
///         against the cumulative ghost state built up over the fuzz campaign.
contract FillerInvariantTest is Test {
    FillerInvariantHandler internal handler;

    function setUp() public {
        handler = new FillerInvariantHandler();

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = FillerInvariantHandler.actionExecuteExactHappy.selector;
        selectors[1] = FillerInvariantHandler.actionExecutePartialHappy.selector;
        selectors[2] = FillerInvariantHandler.actionExecuteZeroDestination.selector;
        selectors[3] = FillerInvariantHandler.actionExecuteOverfund.selector;
        selectors[4] = FillerInvariantHandler.actionExecuteInsufficient6909.selector;
        selectors[5] = FillerInvariantHandler.actionExecuteRevertingDestination.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-F1 — filler contract holds zero of every token it ever touched.
    function invariant_F1_fillerHoldsNoTokens() public view {
        uint256 fillers = handler.ghostFillersSeenLen();
        uint256 tokens = handler.ghostTokensSeenLen();
        for (uint256 f; f < fillers; ++f) {
            address filler = handler.ghost_fillersSeen(f);
            for (uint256 t; t < tokens; ++t) {
                address tkn = handler.ghost_tokensSeen(t);
                assertEq(IERC20(tkn).balanceOf(filler), 0, "INV-F1: filler token balance");
            }
        }
    }

    /// @notice INV-F2 — no dangling ERC-20 allowance from filler to any settler it spoke to.
    function invariant_F2_noDanglingApprovals() public view {
        uint256 fillers = handler.ghostFillersSeenLen();
        uint256 tokens = handler.ghostTokensSeenLen();
        uint256 spenders = handler.ghostSpendersSeenLen();
        for (uint256 f; f < fillers; ++f) {
            address filler = handler.ghost_fillersSeen(f);
            for (uint256 t; t < tokens; ++t) {
                address tkn = handler.ghost_tokensSeen(t);
                for (uint256 s; s < spenders; ++s) {
                    address spender = handler.ghost_spendersSeen(s);
                    assertEq(IERC20(tkn).allowance(filler, spender), 0, "INV-F2: dangling allowance");
                }
            }
        }
    }

    /// @notice INV-F3 — caller's net srcCST loss never exceeds `actualRolled`. Any srcCST the
    ///         filler pulls that isn't actually consumed by the rollover leg MUST come back to
    ///         the caller via the leftover-return step.
    /// @dev In the mock harness `TestMintModule` never consumes srcCST, so `ghost_actualRolled`
    ///      stays 0 and caller net loss should also be 0 (every happy-path `execute` pulls and
    ///      returns the full amount). The strict-equality form — caller loss exactly equals
    ///      `actualRolled` — belongs to the integration suite (real `RolloverModule` +
    ///      PoolManager); here we assert the one-sided bound that catches silent retention by
    ///      the filler: net loss never exceeds actual fills.
    function invariant_F3_leftoverReturnedToCaller() public view {
        assertLe(
            handler.ghost_callerNetLossSum(), handler.ghost_actualRolled(), "INV-F3: caller lost more than actualRolled"
        );
    }

    /// @notice INV-F4 — filler holds zero ERC-6909 units for any token-id seen.
    function invariant_F4_fillerHoldsNo6909() public view {
        uint256 fillers = handler.ghostFillersSeenLen();
        uint256 ids = handler.ghostErc6909IdsSeenLen();
        address prem = handler.premiumContract();
        for (uint256 f; f < fillers; ++f) {
            address filler = handler.ghost_fillersSeen(f);
            for (uint256 i; i < ids; ++i) {
                uint256 id = handler.ghost_erc6909IdsSeen(i);
                assertEq(IERC6909Premium(prem).balanceOf(filler, id), 0, "INV-F4: filler ERC-6909 balance");
            }
        }
    }

    /// @notice INV-F5 — the filler itself never authorises anyone else as its ERC-6909 operator.
    /// @dev The literal "filler is never an operator of anyone" form from the plan does NOT hold
    ///      in this harness: the premium-leg settlement requires `isOperator(debitFrom, filler) ==
    ///      true` because `ERC6909Premium.settle` enforces dual-auth (both settler AND filler must
    ///      be authorised by `debitFrom`). Actors in the fuzz campaign legitimately flip that bit
    ///      on as a precondition. The asserted property here is the complementary half — the
    ///      filler contract never calls `setOperator` itself, so for every filler and every
    ///      actor-as-operator-candidate the filler's own `isOperator(filler, actor)` is false.
    function invariant_F5_fillerNotOperator() public view {
        uint256 fillers = handler.ghostFillersSeenLen();
        uint256 actors = handler.ghostActorsSeenLen();
        address prem = handler.premiumContract();
        for (uint256 f; f < fillers; ++f) {
            address filler = handler.ghost_fillersSeen(f);
            for (uint256 a; a < actors; ++a) {
                address actor = handler.ghost_actorsSeen(a);
                assertFalse(IERC6909Premium(prem).isOperator(filler, actor), "INV-F5: filler authorised operator");
            }
        }
    }

    /// @notice INV-F7 — atomic-revert parity. Every reverting action must leave filler-side
    ///         state untouched. The handler's revert-path actions snapshot, drive, assert, and
    ///         `vm.revertToState` — they increment `ghost_atomicFailures` on any breach.
    function invariant_F7_atomicRevertParity() public view {
        assertEq(handler.ghost_atomicFailures(), 0, "INV-F7: atomic revert parity breached");
    }

    /// @notice INV-F8 — filler emits zero events of its own. `vm.recordLogs` is armed before
    ///         every action; the handler filters for `emitter == filler` and accumulates.
    function invariant_F8_noEventsFromFiller() public view {
        assertEq(handler.ghost_fillerEventCount(), 0, "INV-F8: filler emitted events");
    }

    /// @notice INV-F9 (liveness) — the happy-path actions must actually settle something under
    ///         the fuzz campaign. Without this, INV-F1..F5, F7, F8 all pass vacuously against a
    ///         no-op `execute` (no balance pulled → F1 holds; no approval → F2 holds; etc).
    ///         Implemented as a standalone direct-drive test rather than an invariant function
    ///         because forge evaluates invariants at depth 0 (before any call); a cumulative
    ///         happy-path count ghost would fail there even though the campaign settles many
    ///         orders afterwards.
    ///
    ///         This test deterministically invokes both Exact and Partial happy actions on the
    ///         handler, then asserts the ghosts advanced. Paired with the campaign (which runs
    ///         the same actions fuzzed), it closes the vacuity gap.
    ///
    ///         Verification procedure (plan/review/CONSOLIDATED.md §7 item 4): mutate
    ///         `RolloverFiller.execute` to a no-op and rerun this test; it MUST fail with the
    ///         liveness message. Revert the mutation — test returns to green.
    function test_F9_liveness_happyActionsCreditDestination() public {
        uint256 settledBefore = handler.ghost_settledCount();
        uint256 creditedBefore = handler.ghost_destinationCreditedCount();

        handler.actionExecuteExactHappy(1, 2);
        handler.actionExecutePartialHappy(3, 0);

        uint256 settledAfter = handler.ghost_settledCount();
        uint256 creditedAfter = handler.ghost_destinationCreditedCount();

        assertGt(settledAfter, settledBefore, "INV-F9: no happy-path execute returned - liveness failure");
        assertEq(
            creditedAfter - creditedBefore,
            settledAfter - settledBefore,
            "INV-F9: happy-path succeeded without crediting destination - silent no-op"
        );
    }
}
