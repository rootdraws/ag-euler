// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidOrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {InvalidFillers, BalanceFloorViolated} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract PartialFillSettler_finaliseAsSettled_Test is PartialFillSettlerTestBase {
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
    event OrderAttribution(
        bytes32 indexed orderId,
        address indexed fillerSlot,
        address indexed premiumFiller,
        address cellarFiller,
        uint256 tokenId,
        uint256 amount
    );

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

    function _setupSettleable()
        internal
        returns (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent)
    {
        (order,, intent) = _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        _fillRolloverPacked(order, fillerAddr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);

        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);

        orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);
    }

    // --- when fillers[] is empty: revert InvalidFillers (Pashov A1) ---

    function test_empty_fillers_reverts_InvalidFillers() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        address[] memory empty = new address[](0);

        vm.expectRevert(InvalidFillers.selector);
        settler.finaliseAsSettled(orderDigest, empty);
    }

    // --- when f.premiumSettled is false: skip -------------------------

    function test_skip_filler_without_premium_settled() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        _fillRolloverPacked(order, fillerAddr, destination, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        assertEq(settler.finalisedCount(orderDigest), 0, "no filler finalised when premium not settled");
    }

    // --- when f.finalised is already true: skip idempotently ----------

    function test_skip_already_finalised_filler() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled));

        // Force status back to Opened so the call doesn't revert on
        // InvalidOrderStatus, allowing us to test the skip path.
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(1)));

        uint256 destBefore = dstToken.balanceOf(destination);
        settler.finaliseAsSettled(orderDigest, fillers);
        uint256 destAfter = dstToken.balanceOf(destination);

        assertEq(destAfter, destBefore, "no transfer on already-finalised filler");
    }

    // --- when f.refunded is true: skip --------------------------------

    function test_skip_refunded_filler() public {
        _setupSettleable();

        // Manually set filler as refunded via direct storage.
        // FillerRollover is at _fillerRollovers mapping (slot differs),
        // but we can verify the skip behavior by refunding first, then
        // trying to settle. We cheat by calling finaliseAsRefunded first.
        // Instead, just verify that finaliseAsSettled skips if
        // premiumSettled && refunded. We test the refunded flag by
        // verifying no extra transfer happens if we call settle after
        // the filler has already been refunded.

        // Force the filler's refunded flag by calling finaliseAsRefunded.
        // This requires past deadline and premiumSettled = true, but
        // refund skips premium-settled fillers. So we need a filler
        // that has rollover but NOT premium settled, and refund it, then
        // try to settle it.

        // Create a second scenario: filler without premium, refund it,
        // then try settle.
        (IOriginSettler.GaslessCrossChainOrder memory order2,, CellarIntent memory intent2) =
            _createOrderWithDistinctDst();

        // Use a different nonce to avoid collision
        order2.nonce = order2.nonce + 1;
        OrderData memory od2 = abi.decode(order2.orderData, (OrderData));
        bytes32 digest2 = LibSettlerHashing.computeOrderDigest(address(settler), order2, od2);
        intent2 = CellarIntent({
            orderDigest: digest2,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order2.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od2.rolloverHooks,
            premiumHooks: od2.premiumHooks
        });
        od2.cellarIntentHash = keccak256(abi.encode(intent2));
        order2.orderData = abi.encode(od2);

        _openForPartial(order2, user, repayTo);
        _fillRolloverPacked(order2, fillerAddr, destination, intent2);

        bytes32 orderDigest2 = _computeOrderDigest(order2);

        // Warp past deadline and refund.
        vm.warp(order2.fillDeadline + 1);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;
        settler.finaliseAsRefunded(orderDigest2, order2, fillers);

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest2, fillerAddr);
        assertTrue(fr.refunded, "filler should be refunded");

        // Now try to settle the refunded filler (force status back to
        // Opened and hookNonces set).
        bytes32 orderId2 = _computeOrderId(order2);
        vm.store(address(settler), keccak256(abi.encode(orderId2, uint256(0))), bytes32(uint256(1)));
        mockFactory.setHookNonces(orderDigest2, 1);

        uint256 destBefore = dstToken.balanceOf(destination);
        settler.finaliseAsSettled(orderDigest2, fillers);
        uint256 destAfter = dstToken.balanceOf(destination);

        assertEq(destAfter, destBefore, "no transfer on refunded filler");
    }

    // --- eligible filler: set finalised, transfer, emit ---------------

    function test_sets_finalised_and_transfers() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        uint256 destBefore = dstToken.balanceOf(destination);
        uint256 settlerBefore = dstToken.balanceOf(address(settler));

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        uint256 destAfter = dstToken.balanceOf(destination);
        uint256 settlerAfter = dstToken.balanceOf(address(settler));

        assertEq(destAfter - destBefore, DEFAULT_PRODUCE_AMOUNT, "destination receives dstCst");
        assertEq(settlerBefore - settlerAfter, DEFAULT_PRODUCE_AMOUNT, "settler balance decreases");
        assertEq(settler.finalisedCount(orderDigest), 1, "finalisedCount incremented");
        assertEq(settler.totalDstCstEscrowed(orderDigest), 0, "totalDstCstEscrowed decremented to zero");

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr);
        assertTrue(fr.finalised, "filler marked finalised");
    }

    function test_emits_FillerFinalised() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.expectEmit(true, true, true, true, address(settler));
        emit FillerFinalised(orderDigest, fillerAddr, DEFAULT_PRODUCE_AMOUNT);

        settler.finaliseAsSettled(orderDigest, fillers);
    }

    // --- terminal condition: Opened -> Settled ------------------------

    function test_terminal_transition_to_Settled() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "order transitions to Settled");
    }

    function test_emits_OrderFinalised_on_terminal() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();

        bytes32 orderId = _computeOrderId(order);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Settled, orderDigest);

        settler.finaliseAsSettled(orderDigest, fillers);
    }

    function test_stays_Opened_without_hookNonces_bit() public {
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
        // hookNonces NOT set (defaults to 0)

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        bytes32 orderId = _computeOrderId(order);
        assertEq(
            uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "stays Opened without hookNonces bit"
        );
    }

    // --- when dstCST.safeTransfer reverts for one filler: rescueable credit ---

    function test_safeTransferReverts_CreditsRescueable_EmitsFillerRescueCredited() public {
        // Blacklist-safe branch (closes #39): on safeTransfer revert the filler's slot still
        // latches finalised = true, the order still transitions to Settled (terminal predicate
        // observes the escrow at 0), and the amount is booked on rescueable[orderDigest][filler]
        // with a FillerRescueCredited event bearing the raw revert reason. The transfer is
        // forced to revert by draining the settler's dstToken balance before the finalise call.
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();

        uint256 settlerBal = dstToken.balanceOf(address(settler));
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), settlerBal);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        uint256 destBefore = dstToken.balanceOf(destination);

        // Match the FillerRescueCredited event. `reason` is token-implementation specific so we
        // only check the indexed topics and the amount; we assert the non-empty reason
        // separately below.
        vm.recordLogs();
        settler.finaliseAsSettled(orderDigest, fillers);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Terminal transition still fired.
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "order must still Settle");

        // Filler marked finalised and finalisedCount advanced.
        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr);
        assertTrue(fr.finalised, "filler must still latch finalised");
        assertEq(settler.finalisedCount(orderDigest), 1, "finalisedCount must advance");

        // Rescueable credited exactly the escrowed amount; destination untouched.
        assertEq(
            settler.rescueableOf(orderDigest, fillerAddr),
            DEFAULT_PRODUCE_AMOUNT,
            "rescueable must equal the dstCstProduced amount"
        );
        assertEq(dstToken.balanceOf(destination), destBefore, "destination must not be paid on revert path");

        // FillerRescueCredited was emitted with a non-empty reason.
        bytes32 rescueTopic = keccak256("FillerRescueCredited(bytes32,address,uint256,bytes)");
        bool rescueSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 3 && logs[i].topics[0] == rescueTopic) {
                rescueSeen = true;
                assertEq(logs[i].topics[1], orderDigest, "rescue event orderDigest topic");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(fillerAddr))), "rescue event filler topic");
                (uint256 amt, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                assertEq(amt, DEFAULT_PRODUCE_AMOUNT, "rescue event amount");
                assertGt(reason.length, 0, "rescue reason must bubble non-empty revert data");
            }
        }
        assertTrue(rescueSeen, "FillerRescueCredited event not emitted");
    }

    // --- when one of three fillers' safeTransfer reverts: others still paid ---

    function test_safeTransferRevertsForOne_ofThree_OthersStillPaid() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        address filler3 = makeAddr("filler3");
        address destination3 = makeAddr("destination3");

        // Three fillers each roll their leg and settle their premium.
        _fillRolloverPacked(order, fillerAddr, destination, intent);
        _fillRolloverPacked(order, fillerAddr2, destination2, intent);
        _fillRolloverPacked(order, filler3, destination3, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _authoriseAndSettlePremium(order, od, intent, fillerAddr);
        _authoriseAndSettlePremium(order, od, intent, fillerAddr2);
        _authoriseAndSettlePremium(order, od, intent, filler3);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Cap the settler's dstToken balance so the FIRST TWO payouts succeed and the third
        // (filler3, DEFAULT_PRODUCE_AMOUNT) reverts with ERC20InsufficientBalance. Payout order
        // matches fillers[] — we place filler3 last so the short balance affects only that
        // transfer.
        uint256 settlerBal = dstToken.balanceOf(address(settler));
        uint256 bleedAmount = settlerBal - (2 * DEFAULT_PRODUCE_AMOUNT);
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), bleedAmount);

        address[] memory fillers = new address[](3);
        fillers[0] = fillerAddr;
        fillers[1] = fillerAddr2;
        fillers[2] = filler3;

        settler.finaliseAsSettled(orderDigest, fillers);

        // Two happy fillers paid.
        assertEq(dstToken.balanceOf(destination), DEFAULT_PRODUCE_AMOUNT, "filler1 destination paid");
        assertEq(dstToken.balanceOf(destination2), DEFAULT_PRODUCE_AMOUNT, "filler2 destination paid");
        assertEq(dstToken.balanceOf(destination3), 0, "filler3 destination not paid");

        // Only the third filler has a rescueable credit.
        assertEq(settler.rescueableOf(orderDigest, fillerAddr), 0, "filler1 no rescueable");
        assertEq(settler.rescueableOf(orderDigest, fillerAddr2), 0, "filler2 no rescueable");
        assertEq(settler.rescueableOf(orderDigest, filler3), DEFAULT_PRODUCE_AMOUNT, "filler3 rescueable credited");

        // All three latched finalised; terminal predicate fired.
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "order must Settle");
        assertEq(settler.finalisedCount(orderDigest), 3, "finalisedCount == participantCount");
    }

    function _authoriseAndSettlePremium(
        IOriginSettler.GaslessCrossChainOrder memory order,
        OrderData memory od,
        CellarIntent memory intent,
        address f
    ) internal {
        vm.prank(f);
        premium.setOperator(address(settler), true);
        _depositPremium(f, od.premiumToken, 10e18);
        _fillPremiumPacked(order, f, f, intent);
    }

    // --- when called twice: second call is idempotent skip ------------

    function test_second_call_is_idempotent() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled));

        // Second call reverts because order is no longer Opened.
        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsSettled(orderDigest, fillers);
    }

    // --- when fillers[] contains duplicate: skip second occurrence -----

    function test_duplicate_filler_skips_second() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        address[] memory fillers = new address[](2);
        fillers[0] = fillerAddr;
        fillers[1] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);

        assertEq(settler.finalisedCount(orderDigest), 1, "only one finalisation despite duplicate");
    }

    // --- H1: mixed-outcome wedge — refund B then finalise A => Settled ---

    function test_finaliseAsSettled_AfterMixedOutcome_TransitionsToSettled() public {
        // Two fillers: A has premium settled, B does not.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        // Both fill rollover leg.
        _fillRolloverPacked(order, fillerAddr, destination, intent);
        _fillRolloverPacked(order, fillerAddr2, destination2, intent);

        // Only fillerAddr (A) settles premium.
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);
        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Warp past deadline and refund filler B.
        vm.warp(order.fillDeadline + 1);
        address[] memory refundFillers = new address[](1);
        refundFillers[0] = fillerAddr2;
        settler.finaliseAsRefunded(orderDigest, order, refundFillers);

        // Confirm B is refunded and order still open.
        bytes32 orderId = _computeOrderId(order);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "still Opened after refund B");

        // Now finalise A — should trigger terminal transition to Settled.
        address[] memory settleFillers = new address[](1);
        settleFillers[0] = fillerAddr;

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Settled, orderDigest);

        settler.finaliseAsSettled(orderDigest, settleFillers);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "mixed outcome => Settled");
    }

    // --- H1: all refunded — does NOT transition to Settled ---------------

    function test_finaliseAsSettled_AllRefunded_DoesNotTransitionToSettled() public {
        // Single filler, no premium settled — refund only.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Warp past deadline and refund.
        vm.warp(order.fillDeadline + 1);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;
        settler.finaliseAsRefunded(orderDigest, order, fillers);

        bytes32 orderId = _computeOrderId(order);
        // All refunded => Refunded, NOT Settled.
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Refunded), "all refunded => Refunded");
    }

    // --- FinaliseBatch event emission ------------------------------------

    function test_emits_FinaliseBatch() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        address[] memory fillers = new address[](2);
        fillers[0] = fillerAddr;
        fillers[1] = fillerAddr2; // not filled — will be skipped

        vm.expectEmit(true, true, true, true, address(settler));
        emit FinaliseBatch(orderDigest, address(this), 1, 1);

        settler.finaliseAsSettled(orderDigest, fillers);
    }

    // --- zero dstCstProduced: no transfer, no revert ---------------------

    function test_zero_dstCstProduced_skips_transfer() public {
        (bytes32 orderDigest,,) = _setupSettleable();

        // Compute storage slot for _fillerRollovers[orderDigest][fillerAddr].dstCstProduced.
        // _fillerRollovers is at base slot 1 (after BaseSettler.orderStatus at slot 0).
        bytes32 innerMapSlot = keccak256(abi.encode(orderDigest, uint256(1)));
        bytes32 structBase = keccak256(abi.encode(uint256(uint160(fillerAddr)), innerMapSlot));
        bytes32 dstCstProducedSlot = bytes32(uint256(structBase) + 1);

        // Also zero out _totalDstCstEscrowed[orderDigest] at base slot 2.
        bytes32 totalEscrowedSlot = keccak256(abi.encode(orderDigest, uint256(2)));

        vm.store(address(settler), dstCstProducedSlot, bytes32(0));
        vm.store(address(settler), totalEscrowedSlot, bytes32(0));

        // Sanity: confirm storage manipulation worked.
        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, fillerAddr);
        assertEq(fr.dstCstProduced, 0, "dstCstProduced should be 0 after vm.store");
        assertTrue(fr.premiumSettled, "premiumSettled still true");

        uint256 destBefore = dstToken.balanceOf(destination);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        // Should not revert even though dstCstProduced == 0.
        settler.finaliseAsSettled(orderDigest, fillers);

        uint256 destAfter = dstToken.balanceOf(destination);
        assertEq(destAfter, destBefore, "no transfer when dstCstProduced is zero");
        assertEq(settler.finalisedCount(orderDigest), 1, "filler still marked finalised");
    }

    // --- Task 36 (#47): OrderAttribution emission ------------------------

    function test_emits_OrderAttribution_withMatchingIdentities_OnHappyPath() public {
        (bytes32 orderDigest, IOriginSettler.GaslessCrossChainOrder memory order,) = _setupSettleable();
        bytes32 orderId = _computeOrderId(order);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        // Happy path — mock cellar latched `premiumFiredFor[digest][filler] = true` inside the
        // premium-leg fill, so all three attribution identities match and `cellarFiller` equals
        // the slot filler. Cycle-1 C1 (#47) — `tokenId` is the ERC-6909 ledger id, i.e. the
        // premium token address packed into `uint256`, enabling three-way join against
        // `ERC6909Premium.settle` emissions.
        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderAttribution(
            orderId, fillerAddr, fillerAddr, fillerAddr, uint256(uint160(address(premToken))), DEFAULT_PRODUCE_AMOUNT
        );

        settler.finaliseAsSettled(orderDigest, fillers);
    }

    function test_emits_OrderAttribution_withZeroCellarFiller_WhenPremiumHookReverted() public {
        // Reproduce the catch branch of `_onPremiumLegFill`: the cellar never latches
        // `premiumFiredFor`, so `finaliseAsSettled` emits `cellarFiller = address(0)`. The filler's
        // `premiumSettled` latch is still set (catch branch mirrors the success branch), so the
        // finalise path runs.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);
        _fillRolloverPacked(order, fillerAddr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerAddr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerAddr, od.premiumToken, 10e18);

        // Force the `_onPremiumLegFill` catch branch: phase-1 forward reverts, so the mock never
        // latches `premiumFiredFor`. The settler's `premiumSettled` still flips on both branches
        // (end-state parity with PR 7), so `finaliseAsSettled` still runs — but the attribution
        // event surfaces `cellarFiller == address(0)` as a drift signal for off-chain consumers.
        mockFactory.setPhaseRevert(true, 1, "");
        _fillPremiumPacked(order, fillerAddr, fillerAddr, intent);
        mockFactory.setPhaseRevert(false, 1, "");

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        bytes32 orderId = _computeOrderId(order);
        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderAttribution(
            orderId, fillerAddr, fillerAddr, address(0), uint256(uint160(address(premToken))), DEFAULT_PRODUCE_AMOUNT
        );

        settler.finaliseAsSettled(orderDigest, fillers);
    }

    // --- Task 37 (#46): balance-floor assertion --------------------------

    function test_balanceFloor_HoldsOnHappyPath() public {
        // With a single filler and a successful payout the settler's dstCST balance ends at zero
        // and the floor (remaining totalDstCstEscrowed) is also zero — invariant trivially holds.
        (bytes32 orderDigest,,) = _setupSettleable();

        address[] memory fillers = new address[](1);
        fillers[0] = fillerAddr;

        settler.finaliseAsSettled(orderDigest, fillers);
        // Did not revert — floor respected.
        assertEq(settler.totalDstCstEscrowed(orderDigest), 0, "escrow drained");
        assertEq(dstToken.balanceOf(address(settler)), 0, "settler balance at zero");
    }

    function test_balanceFloor_HoldsAcrossPartialBatchWithRemainingEscrow() public {
        // Two fillers, one in the batch. Remaining floor == fillerAddr2's dstCstProduced. The
        // settler's balance after the batch still carries the second filler's escrow, so the
        // check passes. The purpose is to exercise the non-zero floor branch.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        _fillRolloverPacked(order, fillerAddr, destination, intent);
        _fillRolloverPacked(order, fillerAddr2, destination2, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _authoriseAndSettlePremium(order, od, intent, fillerAddr);
        _authoriseAndSettlePremium(order, od, intent, fillerAddr2);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        address[] memory batch = new address[](1);
        batch[0] = fillerAddr;

        // Should not revert — settler still holds fillerAddr2's escrow as floor.
        settler.finaliseAsSettled(orderDigest, batch);

        assertEq(
            settler.totalDstCstEscrowed(orderDigest), DEFAULT_PRODUCE_AMOUNT, "second filler's escrow remains as floor"
        );
        assertEq(
            dstToken.balanceOf(address(settler)), DEFAULT_PRODUCE_AMOUNT, "settler balance matches remaining floor"
        );
    }

    function test_balanceFloor_RevertsWhenSettlerDrainedBelowRemainingEscrow() public {
        // Two fillers; batch processes one. Before the call, silently drain the settler so its
        // balance falls below the post-batch remaining escrow. The assertion must revert with
        // `BalanceFloorViolated(observed, floor)` — a silent-siphon tripwire.
        //
        // The catch branch on the first filler's payout books the amount as rescueable (credit
        // stays on the settler), so to push the balance below the floor we also need to drain the
        // second filler's share of escrow before the assertion. We do that via a direct
        // `vm.prank` transfer of the settler's balance to address(0xdead) AFTER the batch's
        // successful payout would have run — which means we must force the revert condition by
        // simulating the silent siphon within the finaliseAsSettled loop itself.
        //
        // Simplest reproduction: pre-drain settler below the two-filler total, then expect revert
        // in the batch where only one filler pays and the second filler's floor cannot be met.
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        _fillRolloverPacked(order, fillerAddr, destination, intent);
        _fillRolloverPacked(order, fillerAddr2, destination2, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _authoriseAndSettlePremium(order, od, intent, fillerAddr);
        _authoriseAndSettlePremium(order, od, intent, fillerAddr2);

        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Drain settler to DEFAULT_PRODUCE_AMOUNT - 1 (less than the remaining floor after a
        // single-filler batch's transfer).
        uint256 settlerBal = dstToken.balanceOf(address(settler));
        uint256 bleed = settlerBal - (DEFAULT_PRODUCE_AMOUNT - 1);
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), bleed);

        address[] memory batch = new address[](1);
        batch[0] = fillerAddr;

        // Flow in three concrete steps:
        //   1. Pre-drain brings the settler's dstCST balance to `DPA - 1` before the call.
        //   2. The payout transfer to `destination` tries to send `DPA` but only `DPA - 1` is on
        //      the settler, so `SafeERC20.safeTransfer` reverts — the catch branch fires and the
        //      amount is booked as rescueable (credit stays on the settler, balance unchanged at
        //      `DPA - 1`).
        //   3. The balance-floor check then compares `observed (= DPA - 1)` against
        //      `floor (= DPA, fillerAddr2's still-escrowed share)` and reverts
        //      `BalanceFloorViolated(DPA - 1, DPA)`.
        vm.expectRevert(
            abi.encodeWithSelector(BalanceFloorViolated.selector, DEFAULT_PRODUCE_AMOUNT - 1, DEFAULT_PRODUCE_AMOUNT)
        );
        settler.finaliseAsSettled(orderDigest, batch);
    }
}
