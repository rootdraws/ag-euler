// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {
    OrderStatus,
    NotMaker,
    InvalidOrderTokenPair,
    InconsistentIntent,
    InvalidOrderStatus
} from "contracts/interfaces/RolloverTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract PartialFillSettler_open is PartialFillSettlerTestBase {
    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _buildOnchainOrder(OrderData memory od)
        internal
        view
        returns (IOriginSettler.OnchainCrossChainOrder memory)
    {
        return IOriginSettler.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: abi.encode(od)
        });
    }

    function _synthGasless(IOriginSettler.OnchainCrossChainOrder memory onchainOrder, address sender)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory)
    {
        return IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(settler),
            user: sender,
            nonce: 0,
            originChainId: block.chainid,
            openDeadline: 0,
            fillDeadline: onchainOrder.fillDeadline,
            orderDataType: onchainOrder.orderDataType,
            orderData: onchainOrder.orderData
        });
    }

    function _orderIdFor(IOriginSettler.OnchainCrossChainOrder memory onchainOrder, address sender)
        internal
        view
        returns (bytes32)
    {
        IOriginSettler.GaslessCrossChainOrder memory synth = _synthGasless(onchainOrder, sender);
        return LibSettlerHashing.computeOrderId(address(settler), synth);
    }

    function _setOrderStatus(bytes32 orderId, OrderStatus status) internal {
        bytes32 slot = keccak256(abi.encode(orderId, uint256(0)));
        vm.store(address(settler), slot, bytes32(uint256(status)));
    }

    function _emptyResolved() internal pure returns (IOriginSettler.ResolvedCrossChainOrder memory r) {
        r.maxSpent = new IOriginSettler.Output[](0);
        r.minReceived = new IOriginSettler.Output[](0);
        r.fillInstructions = new IOriginSettler.FillInstruction[](0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Tests
    // ═══════════════════════════════════════════════════════════════

    function test_open_senderIsNotReceiver_revertsNotMaker() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        address imposter = address(0xBEEF);
        vm.prank(imposter);
        vm.expectRevert(NotMaker.selector);
        settler.open(onchain);
    }

    function test_open_srcCstTokenEqualsPremiumToken_revertsInvalidOrderTokenPair() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        od.premiumToken = od.srcCstToken;
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        vm.prank(user.addr);
        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.open(onchain);
    }

    function test_open_allowPartialFillsFalse_revertsInconsistentIntent() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        od.allowPartialFills = false;
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        vm.prank(user.addr);
        vm.expectRevert(InconsistentIntent.selector);
        settler.open(onchain);
    }

    function test_open_terminalStatus_revertsInvalidOrderStatus() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        bytes32 orderId = _orderIdFor(onchain, user.addr);

        OrderStatus[3] memory terminals = [OrderStatus.Settled, OrderStatus.Refunded, OrderStatus.Cancelled];

        for (uint256 i; i < terminals.length; ++i) {
            _setOrderStatus(orderId, terminals[i]);

            vm.prank(user.addr);
            vm.expectRevert(InvalidOrderStatus.selector);
            settler.open(onchain);
        }
    }

    function test_open_statusNoneAndValid_transitionsToOpenedAndEmits() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        bytes32 orderId = _orderIdFor(onchain, user.addr);

        vm.prank(user.addr);
        vm.expectEmit(true, false, false, false, address(settler));
        emit IOriginSettler.Open(orderId, _emptyResolved());
        settler.open(onchain);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "status should be Opened");
    }

    function test_open_alreadyOpened_noopsIdempotently() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        // First call: opens
        vm.prank(user.addr);
        settler.open(onchain);

        // Second call: should not emit Open
        vm.recordLogs();
        vm.prank(user.addr);
        settler.open(onchain);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 openTopic = IOriginSettler.Open.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], openTopic, "should not emit Open on second call");
        }
    }
}
