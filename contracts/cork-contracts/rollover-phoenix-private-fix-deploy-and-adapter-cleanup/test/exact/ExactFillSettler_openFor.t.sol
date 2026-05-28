// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {
    OrderStatus,
    InvalidSignature,
    InvalidOrderStatus,
    InvalidOrderTokenPair,
    InconsistentIntent,
    InvalidOriginFillerData
} from "contracts/interfaces/RolloverTypes.sol";

contract ExactFillSettler_openFor is ExactFillSettlerTestBase {
    address internal constant REPAY_TO = address(0xBEEF);

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    /// @dev Force orderStatus[orderId] to `status` via vm.store.
    ///      orderStatus mapping is at slot 0 (OZ 5.x ReentrancyGuard
    ///      uses transient storage, not a regular slot).
    function _forceStatus(bytes32 orderId, OrderStatus status) internal {
        bytes32 slot = keccak256(abi.encode(orderId, uint256(0)));
        vm.store(address(settler), slot, bytes32(uint256(status)));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1: empty originFillerData reverts
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_emptyOriginFillerData_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes memory sig = _signOrder(order, user, address(settler));

        vm.expectRevert(InvalidOriginFillerData.selector);
        settler.openFor(order, sig, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: valid EOA sig transitions None -> Opened, emits Open
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_validEOA_transitionsToOpened() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);

        vm.expectEmit(true, false, false, false, address(settler));
        emit IOriginSettler.Open(orderId, _dummyResolved());

        _openForExact(order, user, REPAY_TO);

        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: valid EOA sig records repaymentTo
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_validEOA_recordsRepaymentTo() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        _openForExact(order, user, REPAY_TO);

        bytes32 orderId = _computeOrderId(order);
        assertEq(settler.repaymentTo(orderId), REPAY_TO);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 4: ERC-1271 sig behaves identically to EOA
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_erc1271Valid_behavesLikeEOA() public {
        // Build order for EOA user, then rebind to smart wallet
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);

        order.user = smartWalletAddr;
        od.receiver = smartWalletAddr;

        // Recompute intent (orderDigest changes because od.receiver
        // changed)
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
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        // Sign with a random wallet that is NOT order.user
        Vm.Wallet memory rando = vm.createWallet("rando");
        bytes memory badSig = _signOrder(order, rando, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidSignature.selector);
        settler.openFor(order, badSig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 6: allowPartialFills true reverts InconsistentIntent
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_allowPartialFills_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);

        // Flip allowPartialFills and re-encode
        od.allowPartialFills = true;
        intent.allowPartialFills = true;
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
            _createExactOrder(user, DEFAULT_ORDER_SIZE);

        // Force srcCstToken == premiumToken and re-encode
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
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        // First open
        _openForExact(order, user, REPAY_TO);

        bytes32 orderId = _computeOrderId(order);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));

        // Second open — should NOT emit Open
        vm.recordLogs();
        _openForExact(order, user, REPAY_TO);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IOriginSettler.Open.selector, "Open event should not be emitted on idempotent call"
            );
        }

        // Status unchanged
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 9: terminal statuses revert InvalidOrderStatus
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_settledStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Settled);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_refundedStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Refunded);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_cancelledStatus_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        _forceStatus(orderId, OrderStatus.Cancelled);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(InvalidOrderStatus.selector);
        settler.openFor(order, sig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 10: fill-before-open preserves fillRecord.filler
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_fillBeforeOpen_preservesFiller() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes32 orderId = _computeOrderId(order);
        address filler = address(0xF111);

        // Fill rollover leg before opening (status == None is allowed)
        _fillRollover(order, filler, filler);

        // Now openFor succeeds and transitions to Opened
        _openForExact(order, user, REPAY_TO);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Opened));

        // fillRecord.filler is preserved (not overwritten by openFor)
        bytes32 outputHash = _computeOutputHash(
            IOriginSettler.Output({
                token: bytes32(uint256(uint160(address(vaultUnderlying)))),
                amount: DEFAULT_ORDER_SIZE,
                recipient: bytes32(uint256(uint160(user.addr))),
                chainId: block.chainid
            })
        );
        (address recordedFiller,,,) = settler.fillRecords(orderId, outputHash);
        assertEq(recordedFiller, filler);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: dummy resolved order for expectEmit data-match skip
    // ═══════════════════════════════════════════════════════════════

    function _dummyResolved() private pure returns (IOriginSettler.ResolvedCrossChainOrder memory r) {
        // Only topic matching is enabled in expectEmit; the data
        // payload is not checked, so an empty struct suffices.
    }
}
