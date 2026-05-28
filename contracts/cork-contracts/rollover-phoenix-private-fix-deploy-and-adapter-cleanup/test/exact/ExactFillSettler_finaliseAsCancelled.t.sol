// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {
    OrderStatus,
    InvalidOrderStatus,
    DigestMismatch,
    NotMaker,
    OrderHasFills
} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

contract ExactFillSettler_finaliseAsCancelled_Test is ExactFillSettlerTestBase {
    address internal filler = makeAddr("filler");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");

    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);

    // ─── helpers ───────────────────────────────────────────────────

    function _fillRolloverPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address dest)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fd = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: dest})));
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fd);
    }

    // ─── when _hashOrder(order) != orderId → revert DigestMismatch ─

    function test_revert_when_orderId_mismatches_order() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);

        bytes32 wrongId = bytes32(uint256(0xDEAD));

        vm.prank(user.addr);
        vm.expectRevert(DigestMismatch.selector);
        settler.finaliseAsCancelled(wrongId, order, "");
    }

    // ─── when status != Opened → revert InvalidOrderStatus ────────

    function test_revert_when_status_is_None() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    function test_revert_when_status_is_Settled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Force Settled (slot 0 = orderStatus).
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(2)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    function test_revert_when_status_is_Refunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(3)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    function test_revert_when_status_is_Cancelled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(4)));

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    // ─── when any fill record exists → revert OrderHasFills ───────

    function test_revert_when_rollover_leg_filled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        _fillRolloverPacked(order, filler, destination);

        vm.prank(user.addr);
        vm.expectRevert(OrderHasFills.selector);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    // ─── msg.sender == order.user → succeed (direct cancel) ───────

    function test_cancel_by_user_transitions_to_Cancelled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        uint256 settlerBalBefore = IERC20(address(vaultUnderlying)).balanceOf(address(settler));
        uint256 userBalBefore = IERC20(address(vaultUnderlying)).balanceOf(user.addr);

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderId, order, "");

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
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Cancelled, bytes32(0));

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderId, order, "");
    }

    // ─── gasless cancel: valid cancelSig from non-user sender ─────

    function test_cancel_with_valid_cancelSig_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes memory cancelSig = _signCancel(orderId, cancelDeadline, user, address(settler));

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        settler.finaliseAsCancelled(orderId, order, cancelSig);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Cancelled), "gasless cancel should succeed");
    }

    // ─── cancelSig is invalid → revert NotMaker ──────────────────

    function test_revert_when_cancelSig_is_garbage() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // 32 bytes cancelDeadline + 65 bytes garbage sig
        bytes memory garbageSig = abi.encodePacked(
            uint256(block.timestamp + 1 hours), bytes32(uint256(0x1)), bytes32(uint256(0x2)), uint8(27)
        );

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(NotMaker.selector);
        settler.finaliseAsCancelled(orderId, order, garbageSig);
    }

    // ─── cancelSig signs different orderId → revert NotMaker ──────

    function test_revert_when_cancelSig_signs_wrong_orderId() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        bytes32 wrongOrderId = bytes32(uint256(0xBAD));
        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes memory cancelSig = _signCancel(wrongOrderId, cancelDeadline, user, address(settler));

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(NotMaker.selector);
        settler.finaliseAsCancelled(orderId, order, cancelSig);
    }

    // ─── after fillDeadline, Opened, no fills → still succeed ─────

    function test_cancel_after_fillDeadline_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.warp(order.fillDeadline + 1);

        vm.prank(user.addr);
        settler.finaliseAsCancelled(orderId, order, "");

        assertEq(
            uint256(settler.orderStatus(orderId)),
            uint256(OrderStatus.Cancelled),
            "cancel after deadline should still work"
        );
    }
}
