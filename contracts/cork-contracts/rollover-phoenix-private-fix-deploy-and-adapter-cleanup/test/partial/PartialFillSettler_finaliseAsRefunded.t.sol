// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidOrderStatus, DigestMismatch, NotExpired} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract PartialFillSettler_finaliseAsRefunded_Test is PartialFillSettlerTestBase {
    address internal fillerAddr = makeAddr("filler");
    address internal fillerAddr2 = makeAddr("filler2");
    address internal destination = makeAddr("destination");
    address internal destination2 = makeAddr("destination2");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;
    DummyERC20 internal premToken;

    event FillerFinalised(bytes32 indexed orderDigest, address indexed filler, uint256 dstCstProduced);
    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);
    event FinaliseBatch(bytes32 indexed orderDigest, address indexed caller, uint256 processed, uint256 skipped);

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premToken = new DummyERC20("Premium", "PREM", 18);
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

    function _fillPremiumPacked(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address targetFiller,
        address premiumPayer,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: premiumPayer,
                    targetFiller: targetFiller,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
        vm.prank(premiumPayer);
        settler.fill(oid, abi.encode(order), fillerData);
    }

    function _createOrderWithDistinctDst()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
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
    }

    function _setupRefundable()
        internal
        returns (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent)
    {
        (order,, intent) = _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);
        orderDigest = _computeOrderDigest(order);
    }

    // --- when _hashOrder(order) != orderDigest: revert DigestMismatch -

    function test_revert_when_order_mismatches_digest() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        // Mutate order so its hash no longer matches.
        order.nonce = order.nonce + 999;

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(DigestMismatch.selector);
        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }

    // --- when block.timestamp <= order.fillDeadline: revert NotExpired -

    function test_revert_when_not_expired() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline);
        vm.expectRevert(NotExpired.selector);
        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }

    // --- when orderStatus != Opened: revert InvalidOrderStatus --------

    function test_revert_when_status_is_None() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);

        // Not opened, so orderIdOf[orderDigest] == 0 which means
        // orderId == 0, and orderStatus[0] == None.
        bytes32 orderDigest = _computeOrderDigest(order);
        address[] memory fillers = new address[](0);

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(DigestMismatch.selector);
        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }

    function test_revert_when_status_is_Settled() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        bytes32 orderId = _computeOrderId(order);
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(2)));

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }

    function test_revert_when_status_is_Cancelled() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        bytes32 orderId = _computeOrderId(order);
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(4)));

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }

    // --- UW's ERC-1271 policy changed: succeed (no sig re-check) ------

    function test_succeeds_without_signature_reverification() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);

        // Any caller can invoke — no signature needed.
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(settler.refundedCount(orderDigest), 1, "refund succeeded without sig");
    }

    // --- when f.premiumSettled is true: skip --------------------------

    function test_skip_premium_settled_filler() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);
        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);

        bytes32 orderDigest = _computeOrderDigest(order);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(settler.refundedCount(orderDigest), 0, "premium-settled filler skipped");
    }

    // --- when f.dstCstProduced is zero: still advances count -----------

    function test_zeroDstProduced_filler_still_advances_refundedCount() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        // fillerAddr2 never filled — all fields default to zero.
        // Under D3 model the caller controls the list; zero-produced fillers
        // still get marked refunded (no transfer, but count advances).
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr2;

        address cellar = settler.cellarOf(orderDigest);
        uint256 cellarBefore = dstToken.balanceOf(cellar);

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        // Count advances, no transfer occurs.
        assertEq(settler.refundedCount(orderDigest), 1, "zero-produced still advances refundedCount");
        assertEq(dstToken.balanceOf(cellar), cellarBefore, "no transfer for zero produced");

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr2);
        assertTrue(fr.refunded, "zero-produced filler marked refunded");
    }

    // --- when f.refunded is already true: skip idempotently -----------

    function test_skip_already_refunded_filler() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        uint256 refundedBefore = settler.refundedCount(orderDigest);

        // Force status back to Opened so the call doesn't revert.
        bytes32 orderId = _computeOrderId(order);
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(1)));

        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(settler.refundedCount(orderDigest), refundedBefore, "no double refund");
    }

    // --- when f.finalised is true: skip (exclusive) -------------------

    function test_skip_finalised_filler() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);
        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr);
        assertTrue(fr.finalised, "filler should be finalised");

        // Force status back to Opened.
        bytes32 orderId = _computeOrderId(order);
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(1)));

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(settler.refundedCount(orderDigest), 0, "finalised filler not refunded");
    }

    // --- eligible filler: refund to cellar, emit ----------------------

    function test_refund_transfers_to_cellar_and_emits() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address cellar = settler.cellarOf(orderDigest);
        uint256 cellarBefore = dstToken.balanceOf(cellar);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);

        vm.expectEmit(true, true, true, true, address(settler));
        emit FillerFinalised(orderDigest, fillerAddr, DEFAULT_PRODUCE_AMOUNT);

        settler.finaliseAsRefunded(orderDigest, order, fillers);

        uint256 cellarAfter = dstToken.balanceOf(cellar);
        assertEq(cellarAfter - cellarBefore, DEFAULT_PRODUCE_AMOUNT, "dstCst returned to cellar");

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr);
        assertTrue(fr.refunded, "filler marked refunded");
        assertEq(settler.refundedCount(orderDigest), 1, "refundedCount incremented");
        assertEq(settler.totalDstCstEscrowed(orderDigest), 0, "escrowed decremented");
    }

    // --- refundedCount == participantCount: transition to Refunded -----

    function test_terminal_transition_to_Refunded() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        bytes32 orderId = _computeOrderId(order);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Refunded, orderDigest);

        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded), "order is Refunded");
    }

    // --- refundedCount < participantCount: leave Opened ---------------

    function test_partial_refund_stays_Opened() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        // Two fillers: one rollover-only, one premium-settled.
        _fillRolloverPacked(order, fillerAddr, destination, intent);
        _fillRolloverPacked(order, fillerAddr2, destination2, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr2);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr2, od.premiumToken, 10e18);
        _fillPremiumPacked(order, fillerAddr2, fillerAddr2, intent);

        bytes32 orderDigest = _computeOrderDigest(order);

        // Only refund fillerAddr (no premium). fillerAddr2 has premium
        // settled so it'll be skipped.
        address[] memory fillers = new address[](2);
        fillers[0] = fillerAddr;
        fillers[1] = fillerAddr2;

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        // Only fillerAddr refunded; fillerAddr2 skipped (premiumSettled).
        assertEq(settler.refundedCount(orderDigest), 1, "only one refunded");
        assertEq(settler.participantCount(orderDigest), 2, "two participants");

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "stays Opened");
    }

    // --- all fillers premium-paid: no transfer (all skip) -------------

    function test_all_premium_paid_zero_refunds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);
        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);

        bytes32 orderDigest = _computeOrderDigest(order);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        uint256 settlerBefore = dstToken.balanceOf(address(settler));

        vm.warp(order.fillDeadline + 1);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        uint256 settlerAfter = dstToken.balanceOf(address(settler));
        assertEq(settlerAfter, settlerBefore, "no tokens moved when all premium-settled");
        assertEq(settler.refundedCount(orderDigest), 0, "zero refunds");
    }

    // --- permissionless: any caller succeeds when Opened --------------

    function test_permissionless_call_succeeds() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);

        address anyone = makeAddr("randomCaller");
        vm.prank(anyone);
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(settler.refundedCount(orderDigest), 1, "permissionless refund succeeded");
    }

    // --- Taleb supp: zero dstCstProduced still unblocks terminal ---------

    function test_finaliseAsRefunded_ZeroDstProduced_StillAdvancesRefundedCount() public {
        // Setup: two fillers (A has real escrow, B has zero dstCstProduced).
        // Refunding both should still reach terminal since B advances count.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        // Filler A fills rollover (gets real dstCstProduced).
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        bytes32 orderDigest = _computeOrderDigest(order);

        // Directly manipulate storage to simulate filler B with a record
        // but zero dstCstProduced. We increment participantCount to 2 as if
        // B filled with zero-output.
        // participantCount mapping is at storage slot 6.
        bytes32 pcSlot = keccak256(abi.encode(orderDigest, uint256(6)));
        vm.store(address(settler), pcSlot, bytes32(uint256(2)));

        assertEq(settler.participantCount(orderDigest), 2, "participantCount set to 2");

        vm.warp(order.fillDeadline + 1);

        // Refund both fillers.
        address[] memory fillers = new address[](2);
        fillers[0] = fillerAddr;
        fillers[1] = fillerAddr2; // zero-produced, no record

        settler.finaliseAsRefunded(orderDigest, order, fillers);

        // Both should be refunded; terminal reached.
        assertEq(settler.refundedCount(orderDigest), 2, "both fillers refunded");
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded), "terminal Refunded reached");
    }

    // --- FinaliseBatch event emission ------------------------------------

    function test_emits_FinaliseBatch() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupRefundable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.warp(order.fillDeadline + 1);

        vm.expectEmit(true, true, true, true, address(settler));
        emit FinaliseBatch(orderDigest, address(this), 1, 0);

        settler.finaliseAsRefunded(orderDigest, order, fillers);
    }
}
