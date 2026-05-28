// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {
    OrderStatus,
    InvalidSignature,
    InvalidOrderStatus,
    InvalidOrderTokenPair,
    InconsistentIntent,
    InvalidOriginFillerData
} from "contracts/interfaces/RolloverTypes.sol";

contract PartialFillSettler_openFor is PartialFillSettlerTestBase {
    address internal constant REPAY_TO = address(0xBEEF);

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _forceStatus(bytes32 orderId, OrderStatus status) internal {
        bytes32 slot = keccak256(abi.encode(orderId, uint256(0)));
        vm.store(address(settler), slot, bytes32(uint256(status)));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1: empty originFillerData reverts
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_emptyOriginFillerData_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes memory sig = _signOrder(order, user, address(settler));

        vm.expectRevert(InvalidOriginFillerData.selector);
        settler.openFor(order, sig, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: valid EOA sig transitions None -> Opened, emits Open
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_validEOA_transitionsToOpened() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);

        vm.expectEmit(true, false, false, false, address(settler));
        emit IOriginSettler.Open(orderId, _dummyResolved());

        _openForPartial(order, user, REPAY_TO);

        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: valid EOA sig records repaymentTo
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_validEOA_recordsRepaymentTo() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        _openForPartial(order, user, REPAY_TO);

        bytes32 orderId = _computeOrderId(order);
        assertEq(settler.repaymentTo(orderId), REPAY_TO);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 4: ERC-1271 sig behaves identically to EOA
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_erc1271Valid_behavesLikeEOA() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        order.user = smartWalletAddr;
        od.receiver = smartWalletAddr;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent.orderDigest = digest;
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrderWithSmartWallet(order, smartWalletAddr, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        settler.openFor(order, sig, originFillerData);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
        assertEq(settler.repaymentTo(orderId), REPAY_TO);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 5: invalid signature reverts
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_invalidSignature_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        Vm.Wallet memory rando = vm.createWallet("rando");
        bytes memory badSig = _signOrder(order, rando, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidSignature.selector);
        settler.openFor(order, badSig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 6: allowPartialFills false reverts InconsistentIntent
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_allowPartialFillsFalse_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        od.allowPartialFills = false;
        intent.allowPartialFills = false;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent.orderDigest = digest;
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InconsistentIntent.selector);
        settler.openFor(order, sig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 7: srcCstToken == premiumToken reverts
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_srcCstEqualsPremium_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        od.premiumToken = od.srcCstToken;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent.orderDigest = digest;
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.openFor(order, sig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 8: already Opened is idempotent no-op (no emit)
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_alreadyOpened_noop() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        _openForPartial(order, user, REPAY_TO);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));

        vm.recordLogs();
        _openForPartial(order, user, REPAY_TO);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IOriginSettler.Open.selector, "Open event should not be emitted on idempotent call"
            );
        }

        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 9: terminal statuses revert InvalidOrderStatus
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_settledStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Settled);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_refundedStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Refunded);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_cancelledStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Cancelled);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 10: openFor succeeds on a fresh order (status None)
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_freshOrder_transitionsToOpened() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.None));

        _openForPartial(order, user, REPAY_TO);

        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 11 (PR 2): two orders differ only in rolloverHooks (ref-type previously-omitted
    //                  field). Pre-PR-2 they shared a digest; post-PR-2 `orderIdOf[digest]`
    //                  stores both distinctly.
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_twoOrdersDifferingInRolloverHooks_storedDistinctly() public {
        (IOriginSettler.GaslessCrossChainOrder memory orderA, OrderData memory odA,) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        // Start from a clone of orderA/odA/intentA, then flip rolloverHooks to a distinct
        // (non-empty) list. Re-derive the digest and re-bind cellarIntentHash + orderData.
        (IOriginSettler.GaslessCrossChainOrder memory orderB, OrderData memory odB, CellarIntent memory intentB) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        odB.rolloverHooks = new Call[](1);
        odB.rolloverHooks[0] =
            Call({target: address(0xC0DE), value: 0, callData: hex"1234", allowFailure: false, isDelegateCall: false});
        bytes32 digestB = LibSettlerHashing.computeOrderDigest(address(settler), orderB, odB);
        intentB.orderDigest = digestB;
        intentB.rolloverHooks = odB.rolloverHooks;
        odB.cellarIntentHash = keccak256(abi.encode(intentB));
        orderB.orderData = abi.encode(odB);

        bytes32 digestA = LibSettlerHashing.computeOrderDigest(address(settler), orderA, odA);
        assertTrue(digestA != digestB, "digests must differ when rolloverHooks differ");

        _openForPartial(orderA, user, REPAY_TO);
        _openForPartial(orderB, user, REPAY_TO);

        bytes32 orderIdA = LibSettlerHashing.computeOrderId(address(settler), orderA);
        bytes32 orderIdB = LibSettlerHashing.computeOrderId(address(settler), orderB);
        assertEq(settler.orderIdOf(digestA), orderIdA, "slotA mapped to orderIdA");
        assertEq(settler.orderIdOf(digestB), orderIdB, "slotB mapped to orderIdB");
        assertTrue(orderIdA != orderIdB, "orderIds must not alias");
        // Ensure the two orders' digests map to DIFFERENT slots (no shared mapping entry).
        assertTrue(settler.orderIdOf(digestA) != settler.orderIdOf(digestB), "slots must not alias");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 12 (PR 2): two orders differ only in repaymentAmount (value-type previously-omitted
    //                  field). Same distinctness guarantee.
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_twoOrdersDifferingInRepaymentAmount_storedDistinctly() public {
        (IOriginSettler.GaslessCrossChainOrder memory orderA, OrderData memory odA,) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        (IOriginSettler.GaslessCrossChainOrder memory orderB, OrderData memory odB, CellarIntent memory intentB) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        odB.repaymentAmount = odA.repaymentAmount + 1234;
        bytes32 digestB = LibSettlerHashing.computeOrderDigest(address(settler), orderB, odB);
        intentB.orderDigest = digestB;
        odB.cellarIntentHash = keccak256(abi.encode(intentB));
        orderB.orderData = abi.encode(odB);

        bytes32 digestA = LibSettlerHashing.computeOrderDigest(address(settler), orderA, odA);
        assertTrue(digestA != digestB, "digests must differ when repaymentAmount differs");

        _openForPartial(orderA, user, REPAY_TO);
        _openForPartial(orderB, user, REPAY_TO);

        bytes32 orderIdA = LibSettlerHashing.computeOrderId(address(settler), orderA);
        bytes32 orderIdB = LibSettlerHashing.computeOrderId(address(settler), orderB);
        assertEq(settler.orderIdOf(digestA), orderIdA, "slotA mapped to orderIdA");
        assertEq(settler.orderIdOf(digestB), orderIdB, "slotB mapped to orderIdB");
        assertTrue(orderIdA != orderIdB, "orderIds must not alias");
        assertTrue(settler.orderIdOf(digestA) != settler.orderIdOf(digestB), "slots must not alias");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: dummy resolved order for expectEmit
    // ═══════════════════════════════════════════════════════════════

    function _dummyResolved() private pure returns (IOriginSettler.ResolvedCrossChainOrder memory r) {}
}
