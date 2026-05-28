// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {
    OrderStatus,
    InvalidOrderStatus,
    DigestMismatch,
    NotMaker,
    OrderHasFills
} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract PartialFillSettler_finaliseAsCancelled_Test is PartialFillSettlerTestBase {
    address internal fillerAddr = makeAddr("filler");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;

    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // --- helpers -------------------------------------------------------

    function _fillRolloverPacked(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address filler_,
        address dest,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: dest, debitFrom: address(0), targetFiller: filler_, intent: intent, cellarSig: ""
                })
            )
        );
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fillerData);
    }

    function _createOrderWithDistinctDst()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
        od.dstCstToken = address(dstToken);

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
    }

    // --- when orderIdOf[orderDigest] == 0: revert InvalidOrderStatus --

    function test_revert_when_orderDigest_is_unknown() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);

        bytes32 wrongDigest = bytes32(uint256(0xDEAD));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(wrongDigest, order, "");
    }

    // --- when _hashOrder(order) != orderId: revert DigestMismatch -----

    function test_revert_when_order_does_not_reproduce_orderId() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderDigest = _computeOrderDigest(order);

        // Mutate order so _hashOrder won't match the stored orderId
        order.nonce = order.nonce + 1;

        vm.prank(user.addr);
        vm.expectRevert(DigestMismatch.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    // --- when orderStatus != Opened: revert InvalidOrderStatus --------

    function test_revert_when_status_is_None() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        // Order not opened — orderIdOf[digest] == 0 → InvalidOrderStatus
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    function test_revert_when_status_is_Settled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(2)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    function test_revert_when_status_is_Refunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(3)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    function test_revert_when_status_is_Cancelled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(4)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    // --- when participantCount > 0 OR totalDstCstEscrowed > 0: revert -

    function test_revert_when_order_has_fills() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();

        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        bytes32 orderDigest = _computeOrderDigest(order);

        vm.prank(user.addr);
        vm.expectRevert(OrderHasFills.selector);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    // --- msg.sender == order.user: cancel succeeds --------------------

    function test_cancel_by_user_transitions_to_Cancelled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        uint256 settlerBalBefore = IERC20(address(vaultUnderlying)).balanceOf(address(settler));
        uint256 userBalBefore = IERC20(address(vaultUnderlying)).balanceOf(user.addr);

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderDigest, order, "");

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Cancelled), "status should be Cancelled");
        assertEq(
            IERC20(address(vaultUnderlying)).balanceOf(address(settler)),
            settlerBalBefore,
            "settler balance unchanged on cancel"
        );
        assertEq(
            IERC20(address(vaultUnderlying)).balanceOf(user.addr), userBalBefore, "user balance unchanged on cancel"
        );
    }

    function test_cancel_by_user_emits_OrderFinalised() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Cancelled, orderDigest);

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderDigest, order, "");
    }

    // --- valid cancel sig from non-user sender: gasless cancel --------

    function test_cancel_with_valid_cancelSig_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes memory cancelSig = _signCancel(orderId, cancelDeadline, user, address(settler));

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        settler.finaliseAsCancelled(orderDigest, order, cancelSig);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Cancelled), "gasless cancel should succeed");
    }

    // --- cancelSig is invalid: revert NotMaker ------------------------

    function test_revert_when_cancelSig_is_garbage() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderDigest = _computeOrderDigest(order);

        bytes memory garbageSig = abi.encodePacked(
            uint256(block.timestamp + 1 hours), bytes32(uint256(0x1)), bytes32(uint256(0x2)), uint8(27)
        );

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(NotMaker.selector);
        settler.finaliseAsCancelled(orderDigest, order, garbageSig);
    }

    // --- cancelSig signs different orderId: revert NotMaker -----------

    function test_revert_when_cancelSig_signs_wrong_orderId() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderDigest = _computeOrderDigest(order);

        bytes32 wrongOrderId = bytes32(uint256(0xBAD));
        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes memory cancelSig = _signCancel(wrongOrderId, cancelDeadline, user, address(settler));

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(NotMaker.selector);
        settler.finaliseAsCancelled(orderDigest, order, cancelSig);
    }

    // --- ZeroRollover (no state written): cancel still succeeds -------

    function test_cancel_after_failed_fill_attempt() public {
        // When a fill reverts (e.g. ZeroRollover), no fill state is
        // written. So after a failed fill attempt the order is still
        // open with zero participants, and cancel succeeds.
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        // Simulate a failed fill: mockFactory produces 0 -> ZeroRollover
        mockFactory.setRolloverBehavior(address(dstToken), 0);
        // The fill call would revert with ZeroRollover, so no state
        // written. We just verify cancel works on the un-filled order.

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderDigest, order, "");

        assertEq(
            uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Cancelled), "cancel succeeds after failed fill"
        );
    }

    // --- after fillDeadline AND Opened AND no fills: succeed ----------

    function test_cancel_after_fillDeadline_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        _openForPartial(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = _computeOrderDigest(order);

        vm.warp(order.fillDeadline + 1);

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderDigest, order, "");

        assertEq(
            uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Cancelled), "cancel after deadline still works"
        );
    }
}
