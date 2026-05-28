// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidOrderStatus, DigestMismatch, NotExpired} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract ExactFillSettler_finaliseAsRefunded_Test is ExactFillSettlerTestBase {
    address internal filler = makeAddr("filler");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;

    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ─── helpers ───────────────────────────────────────────────────

    function _fillRolloverPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address dest)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fd = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: dest})));
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fd);
    }

    function _createOrderWithDistinctDst()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
    }

    // ─── when _hashOrder(order) != orderId → revert DigestMismatch ─

    function test_revert_when_orderId_mismatches_order() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);

        bytes32 wrongId = bytes32(uint256(0xDEAD));

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(DigestMismatch.selector);
        settler.finaliseAsRefunded(wrongId, order);
    }

    // ─── when block.timestamp <= order.fillDeadline → revert ──────

    function test_revert_when_not_expired() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Warp to exactly fillDeadline (<=, so should still revert).
        vm.warp(order.fillDeadline);
        vm.expectRevert(NotExpired.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── when orderStatus == None → revert InvalidOrderStatus ─────

    function test_revert_when_status_is_None() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── when orderStatus == Settled → revert InvalidOrderStatus ──

    function test_revert_when_status_is_Settled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Force Settled status via vm.store (slot 1).
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(2)));

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── when orderStatus == Refunded → revert InvalidOrderStatus ─

    function test_revert_when_status_is_Refunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(3)));

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── when orderStatus == Cancelled → revert InvalidOrderStatus

    function test_revert_when_status_is_Cancelled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(4)));

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── when Opened AND paymentSettled==true → revert OrderComplete

    function test_revert_when_payment_already_settled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Force paymentSettled=true (slot 2).
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(2))), bytes32(uint256(1)));

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(IExactFillSettler.OrderComplete.selector);
        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── windfall: rollover filled, premium not settled ────────────

    function test_refund_transfers_dstCst_to_cellar() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createOrderWithDistinctDst();

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        _fillRolloverPacked(order, filler, destination);

        address cellar = settler.cellarOf(orderId);

        vm.warp(order.fillDeadline + 1);

        uint256 cellarBefore = dstToken.balanceOf(cellar);

        settler.finaliseAsRefunded(orderId, order);

        uint256 cellarAfter = dstToken.balanceOf(cellar);
        assertEq(cellarAfter - cellarBefore, DEFAULT_PRODUCE_AMOUNT, "dstCst should be returned to cellar");
    }

    function test_refund_windfall_transitions_to_Refunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createOrderWithDistinctDst();

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        _fillRolloverPacked(order, filler, destination);

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderId, order);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded), "status should be Refunded");
    }

    function test_refund_windfall_emits_OrderFinalised() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createOrderWithDistinctDst();

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        _fillRolloverPacked(order, filler, destination);

        vm.warp(order.fillDeadline + 1);

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Refunded, bytes32(0));

        settler.finaliseAsRefunded(orderId, order);
    }

    // ─── both legs un-filled: no transfer, status → Refunded ──────

    function test_refund_no_fills_transitions_to_Refunded() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        vm.warp(order.fillDeadline + 1);

        uint256 settlerBefore = vaultUnderlying.balanceOf(address(settler));

        settler.finaliseAsRefunded(orderId, order);

        uint256 settlerAfter = vaultUnderlying.balanceOf(address(settler));

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded), "status should be Refunded");
        assertEq(settlerBefore, settlerAfter, "no tokens should move when no fills exist");
    }
}
