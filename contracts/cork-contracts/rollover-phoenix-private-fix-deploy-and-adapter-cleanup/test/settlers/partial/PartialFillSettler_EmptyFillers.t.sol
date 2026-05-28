// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {InvalidFillers} from "contracts/settlers/BaseSettlerErrors.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @title PartialFillSettler_EmptyFillers
/// @notice Audit-cycle coverage for the empty-fillers griefing guard (Pashov A1 / Task 4).
///         `finaliseAsSettled` now reverts `InvalidFillers` when called with a zero-length
///         `fillers[]` array, and the terminal predicate in `_maybeTransitionToTerminal` requires
///         `participantCount > 0` so a zero-fill order cannot drift to `Refunded` via the
///         `refundedCount == participantCount == 0` tautology.
/// @dev Both leaves drive the settler directly so the `InvalidFillers` revert is observable
///      without threading through the filler infrastructure.
contract PartialFillSettler_EmptyFillers is PartialFillSettlerTestBase {
    address internal attacker = makeAddr("attacker");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;
    DummyERC20 internal premToken;

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premToken = new DummyERC20("Premium", "PREM", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _openedOrder()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, bytes32 orderDigest, bytes32 orderId)
    {
        (order,,) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premToken);

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        CellarIntent memory intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        _openForPartial(order, user, repayTo);

        orderDigest = _computeOrderDigest(order);
        orderId = _computeOrderId(order);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1 — empty fillers reverts InvalidFillers
    // ═══════════════════════════════════════════════════════════════

    /// @notice An attacker (or any caller) hitting `finaliseAsSettled` with an empty `fillers[]`
    ///         array on an opened order must now revert. Before Task 4 the call was a silent
    ///         no-op that spent the caller's gas while exposing a grief surface — any key-holder
    ///         could spam the function while the order was live.
    function test_empty_fillers_reverts_InvalidFillers() public {
        (, bytes32 orderDigest,) = _openedOrder();

        address[] memory empty = new address[](0);

        vm.prank(attacker);
        vm.expectRevert(InvalidFillers.selector);
        settler.finaliseAsSettled(orderDigest, empty);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2 — empty fillers cannot transition an opened order
    // ═══════════════════════════════════════════════════════════════

    /// @notice The `participantCount > 0` terminal-predicate guard protects against a subtle
    ///         state drift that would otherwise trigger even with the `fillers.length == 0`
    ///         revert in place. We assert defense-in-depth: the order's status stays `Opened`
    ///         after a failed empty-fillers call (the revert bubbles up so no state moves).
    function test_empty_fillers_leaves_status_Opened() public {
        (, bytes32 orderDigest, bytes32 orderId) = _openedOrder();

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "precondition: opened");

        address[] memory empty = new address[](0);

        vm.prank(attacker);
        try settler.finaliseAsSettled(orderDigest, empty) {
            revert("expected InvalidFillers revert");
        } catch {}

        assertEq(
            uint256(settler.orderStatus(orderId)),
            uint256(OrderStatus.Opened),
            "status must not transition on empty-fillers call"
        );
        assertEq(settler.finalisedCount(orderDigest), 0, "no finaliseCount mutation");
        assertEq(settler.refundedCount(orderDigest), 0, "no refundedCount mutation");
        assertEq(settler.participantCount(orderDigest), 0, "no participantCount mutation");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3 — happy path with non-empty fillers still succeeds
    // ═══════════════════════════════════════════════════════════════

    /// @notice Regression guard. With one filler landed, `finaliseAsSettled` completes and the
    ///         order transitions to `Settled`. Confirms the new guards do not disturb the
    ///         canonical single-filler flow covered end-to-end in `test/partial/*`.
    function test_non_empty_fillers_still_transitions_to_Settled() public {
        address fillerAddr = makeAddr("filler");
        address destination = makeAddr("destination");

        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premToken);

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        _openForPartial(order, user, repayTo);
        _fillRollover(order, fillerAddr, destination, intent, "");

        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, address(premToken), 10e18);

        _fillPremium(order, fillerAddr, fillerAddr, fillerAddr, intent, "");

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        bytes32 orderId = _computeOrderId(order);
        assertEq(
            uint256(settler.orderStatus(orderId)),
            uint256(OrderStatus.Settled),
            "canonical one-filler flow must still settle"
        );
    }
}
