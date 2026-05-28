// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidOrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract ExactFillSettler_finaliseAsSettled_Test is ExactFillSettlerTestBase {
    address internal filler = makeAddr("filler");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;

    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);
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
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ─── helpers ───────────────────────────────────────────────────

    /// @dev Fill rollover leg with correctly packed fillerData.
    function _fillRolloverPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address dest)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fd = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: dest})));
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fd);
    }

    /// @dev Fill premium leg with correctly packed fillerData.
    function _fillPremiumPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address debitFrom)
        internal
    {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = abi.encodePacked(uint8(1), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
        vm.prank(filler_);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    /// @dev Create an order with distinct srcCstToken and dstCstToken
    ///      so rollover-leg leftover detection does not confuse
    ///      minted dstCst as srcCst leftovers.
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

    /// @dev Full happy-path setup: create order, open, fill rollover,
    ///      fill premium (zero-amount via minPremiumPerShare=0), ready
    ///      for finaliseAsSettled.
    function _setupSettleable() internal returns (bytes32 orderId, IOriginSettler.GaslessCrossChainOrder memory order) {
        (order,,) = _createOrderWithDistinctDst();

        _openForExact(order, user, repayTo);
        orderId = _computeOrderId(order);

        _fillRolloverPacked(order, filler, destination);

        // Authorize settler as operator on ERC6909 so premium settle
        // (zero-amount no-op) passes auth.
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        _fillPremiumPacked(order, filler, filler);
    }

    // ─── when orderStatus[orderId] is not Opened → revert ─────────

    function test_revert_when_status_is_None() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        bytes32 orderId = _computeOrderId(order);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsSettled(orderId);
    }

    function test_revert_when_status_is_Settled() public {
        (bytes32 orderId,) = _setupSettleable();

        settler.finaliseAsSettled(orderId);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled));

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsSettled(orderId);
    }

    function test_revert_when_status_is_Refunded() public {
        (bytes32 orderId,) = _setupSettleable();

        // Force status to Refunded via vm.store (slot 0 = orderStatus)
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(3)));

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsSettled(orderId);
    }

    function test_revert_when_status_is_Cancelled() public {
        (bytes32 orderId,) = _setupSettleable();

        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(0))), bytes32(uint256(4)));

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.finaliseAsSettled(orderId);
    }

    // ─── when paymentSettled is false → revert PaymentNotSettled ───

    function test_revert_when_paymentSettled_is_false() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createOrderWithDistinctDst();

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Fill rollover only — premium not filled, so
        // paymentSettled stays false.
        _fillRolloverPacked(order, filler, destination);

        vm.expectRevert(IExactFillSettler.PaymentNotSettled.selector);
        settler.finaliseAsSettled(orderId);
    }

    // ─── when rollover fillRecord missing → revert ────────────────

    function test_revert_when_fillRecord_missing() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, repayTo);
        bytes32 orderId = _computeOrderId(order);

        // Force paymentSettled=true without actually filling any leg.
        // Slot 2 = paymentSettled mapping.
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(2))), bytes32(uint256(1)));

        vm.expectRevert(IExactFillSettler.InvalidFillRecord.selector);
        settler.finaliseAsSettled(orderId);
    }

    // ─── happy path: Opened → Settled ─────────────────────────────

    function test_transition_Opened_to_Settled() public {
        (bytes32 orderId,) = _setupSettleable();

        settler.finaliseAsSettled(orderId);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "status should be Settled");
    }

    function test_transfers_dstCst_to_destination() public {
        (bytes32 orderId,) = _setupSettleable();

        uint256 settlerBefore = dstToken.balanceOf(address(settler));
        uint256 destBefore = dstToken.balanceOf(destination);

        settler.finaliseAsSettled(orderId);

        uint256 settlerAfter = dstToken.balanceOf(address(settler));
        uint256 destAfter = dstToken.balanceOf(destination);

        assertEq(
            settlerBefore - settlerAfter, DEFAULT_PRODUCE_AMOUNT, "settler balance should decrease by produced amount"
        );
        assertEq(destAfter - destBefore, DEFAULT_PRODUCE_AMOUNT, "destination should receive produced amount");
    }

    function test_emits_OrderFinalised() public {
        (bytes32 orderId,) = _setupSettleable();

        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderFinalised(orderId, OrderStatus.Settled, bytes32(0));

        settler.finaliseAsSettled(orderId);
    }

    // ─── permissionless: any msg.sender succeeds ──────────────────

    function test_succeeds_when_called_by_arbitrary_sender() public {
        (bytes32 orderId,) = _setupSettleable();

        address anyone = address(0xBEEF);
        vm.prank(anyone);
        settler.finaliseAsSettled(orderId);

        assertEq(
            uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "permissionless caller should settle"
        );
    }

    // ─── when dstCST.safeTransfer reverts: rescueable credit (closes #39) ───

    function test_safeTransferReverts_StillSettles_CreditsRescueable() public {
        // Blacklist-safe branch: on safeTransfer revert the order still transitions to Settled
        // (so the lifecycle is not stuck) and the amount is booked on rescueable[orderId][filler]
        // with a FillerRescueCredited event. The transfer is forced to revert by draining the
        // settler's dstToken balance before the finalise call.
        (bytes32 orderId,) = _setupSettleable();

        uint256 settlerBal = dstToken.balanceOf(address(settler));
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), settlerBal);

        uint256 destBefore = dstToken.balanceOf(destination);

        vm.recordLogs();
        settler.finaliseAsSettled(orderId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Order still settled — lifecycle progressed.
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Settled), "order must still Settle");

        // Destination received nothing; rescueable carries the full amount keyed on filler.
        assertEq(dstToken.balanceOf(destination), destBefore, "destination must not be paid on revert path");
        assertEq(
            settler.rescueableOf(orderId, filler), DEFAULT_PRODUCE_AMOUNT, "rescueable credited exactly dstCstProduced"
        );

        // FillerRescueCredited event emitted with non-empty reason bytes.
        bytes32 rescueTopic = keccak256("FillerRescueCredited(bytes32,address,uint256,bytes)");
        bool rescueSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 3 && logs[i].topics[0] == rescueTopic) {
                rescueSeen = true;
                assertEq(logs[i].topics[1], orderId, "rescue event orderId topic");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(filler))), "rescue event filler topic");
                (uint256 amt, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                assertEq(amt, DEFAULT_PRODUCE_AMOUNT, "rescue event amount");
                assertGt(reason.length, 0, "rescue reason must bubble non-empty revert data");
            }
        }
        assertTrue(rescueSeen, "FillerRescueCredited event not emitted");
    }

    // --- Task 36 (#47): OrderAttribution emission ------------------------

    function test_emits_OrderAttribution_withMatchingIdentities_OnHappyPath() public {
        (bytes32 orderId, IOriginSettler.GaslessCrossChainOrder memory order) = _setupSettleable();

        // Happy path — mock cellar latched `premiumFiredFor[digest][filler] = true` on the
        // premium-leg fill, so `cellarFiller` resolves to the rollover-leg filler. On Exact the
        // three identity fields all equal `rolloverRec.filler` by construction (single-participant).
        // Cycle-1 C1 (#47) — `tokenId` is the ERC-6909 ledger id (premium token address packed
        // into uint256), enabling three-way join against `ERC6909Premium.settle` emissions.
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.expectEmit(true, true, true, true, address(settler));
        emit OrderAttribution(
            orderId, filler, filler, filler, uint256(uint160(od.premiumToken)), DEFAULT_PRODUCE_AMOUNT
        );

        settler.finaliseAsSettled(orderId);
    }
}
