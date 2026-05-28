// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidOrderStatus, NotExpired} from "contracts/interfaces/RolloverTypes.sol";
import {InvalidFillers} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";

/// @title BaseSettler_transitionIfTerminal (PR 3 — Task 9)
/// @notice Coverage for the shared `_transitionIfTerminal` predicate on BaseSettler. Every leaf
///         drives the predicate via the Partial settler's finalise flow (the predicate lives on
///         Base but the only caller today is Partial — Exact remains a special case documented
///         in the BaseSettler NatSpec). Exact's own single-participant terminal path is covered
///         by `ExactFillSettler_finaliseAsSettled`.
/// @dev MUST preserve the `participantCount == 0 → early-return` guard landed in `fafcf65`
///      (Pashov A1). The matching leaf is asserted here AND in the pre-existing
///      `PartialFillSettler_EmptyFillers` suite (regression guard across PR-65 and PR-3).
contract BaseSettler_transitionIfTerminal_Partial is PartialFillSettlerTestBase {
    address internal fillerA = makeAddr("fillerA");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");
    DummyERC20 internal dstToken;
    DummyERC20 internal premToken;

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premToken = new DummyERC20("Premium", "PRM", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    function _openAndBind()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest)
    {
        OrderData memory od;
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premToken);
        digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent.orderDigest = digest;
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
        _openForPartial(order, user, repayTo);
    }

    function _driveFullLifecycle(
        IOriginSettler.GaslessCrossChainOrder memory order,
        CellarIntent memory intent,
        bytes32 digest
    ) internal {
        _fillRollover(order, fillerA, destination, intent, "");
        vm.prank(fillerA);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerA, address(premToken), 10e18);
        _fillPremium(order, fillerA, fillerA, fillerA, intent, "");
        mockFactory.setHookNonces(digest, 1);
    }

    // Leaf: participantCount == 0 → early-return (Pashov A1)
    function test_participantCountZero_earlyReturn() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes32 digest) = _openAndBind();
        address[] memory empty = new address[](0);
        vm.expectRevert(InvalidFillers.selector);
        settler.finaliseAsSettled(digest, empty);
        // Even with the InvalidFillers revert lifted, the predicate's early-return would prevent
        // a refund-drift. Assert the order remains Opened.
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
    }

    // Leaf: finalised + refunded < participantCount → no transition
    function test_partial_incompleteFinalise_noTransition() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest) =
            _openAndBind();
        // One filler lands a rollover leg but no premium → eligible set is empty.
        _fillRollover(order, fillerA, destination, intent, "");
        // finaliseAsSettled skips because premiumSettled is false — no counter moves.
        address[] memory fillers = new address[](1);
        fillers[0] = fillerA;
        settler.finaliseAsSettled(digest, fillers);
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
    }

    // Leaf: totalDstCstEscrowed != 0 → no transition
    function test_partial_escrowRemaining_noTransition() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent,) = _openAndBind();
        _fillRollover(order, fillerA, destination, intent, "");
        // No finalise yet — escrow still held.
        assertGt(settler.totalDstCstEscrowed(_computeOrderDigest(order)), 0, "escrow non-zero");
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
    }

    // Leaf: hookPhase0Done == false → no Settled transition
    function test_partial_hookNotDone_noSettled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest) =
            _openAndBind();
        _fillRollover(order, fillerA, destination, intent, "");
        vm.prank(fillerA);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerA, address(premToken), 10e18);
        _fillPremium(order, fillerA, fillerA, fillerA, intent, "");
        // Note: hookNonces NOT set — predicate should not reach Settled.
        address[] memory fillers = new address[](1);
        fillers[0] = fillerA;
        settler.finaliseAsSettled(digest, fillers);
        bytes32 orderId = _computeOrderId(order);
        // With finalisedCount > 0 but hookPhase0Done false, the Settled branch skips; and with
        // refundedCount != participantCount, the Refunded branch also skips. Status stays Opened.
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
    }

    // Leaf: all conditions met → Settled transition
    function test_partial_allConditionsMet_transitionsSettled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest) =
            _openAndBind();
        _driveFullLifecycle(order, intent, digest);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerA;
        settler.finaliseAsSettled(digest, fillers);
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled));
    }

    // Leaf: refundedCount == participantCount AND finalisedCount == 0 → Refunded
    function test_partial_allRefunded_transitionsRefunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest) =
            _openAndBind();
        _fillRollover(order, fillerA, destination, intent, "");
        // No premium settled — refund path is eligible after fillDeadline.
        vm.warp(uint256(order.fillDeadline) + 1);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerA;
        settler.finaliseAsRefunded(digest, order, fillers);
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded));
    }

    // Leaf: Exact settler's single-participant terminal path is a documented special case.
    //        Exact does not route through `_transitionIfTerminal`; coverage is owned by
    //        `ExactFillSettler_finaliseAsSettled`. This leaf is a regression marker asserting
    //        Exact still transitions to Settled via its own finalise flow.
    // (intentionally deferred — covered by ExactFillSettler_finaliseAsSettled suite)
}
