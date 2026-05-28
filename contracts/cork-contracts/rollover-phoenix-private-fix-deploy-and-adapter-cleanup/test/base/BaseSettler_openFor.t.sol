// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {WrongOriginSettler, WrongOriginChain, OpenDeadlinePassed} from "contracts/settlers/BaseSettlerErrors.sol";

contract BaseSettler_OpenForTest is ExactFillSettlerTestBase {
    address internal constant REPAY_TO = address(0xBEEF);

    /// @notice Proves H3 fix: FillInstruction.originData round-trips as
    ///         GaslessCrossChainOrder and the decoded orderId matches.
    function test_openFor_EmittedOpenEventCarriesDecodableOriginData() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.recordLogs();
        settler.openFor(order, sig, originFillerData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 openSelector = IOriginSettler.Open.selector;

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != openSelector) continue;
            found = true;

            // Decode the ResolvedCrossChainOrder from event data
            IOriginSettler.ResolvedCrossChainOrder memory resolved =
                abi.decode(logs[i].data, (IOriginSettler.ResolvedCrossChainOrder));

            // Every FillInstruction.originData must decode as GaslessCrossChainOrder
            for (uint256 j; j < resolved.fillInstructions.length; ++j) {
                IOriginSettler.GaslessCrossChainOrder memory decoded =
                    abi.decode(resolved.fillInstructions[j].originData, (IOriginSettler.GaslessCrossChainOrder));

                // The decoded order must produce the same orderId
                bytes32 decodedOrderId = LibSettlerHashing.computeOrderId(address(settler), decoded);
                assertEq(decodedOrderId, resolved.orderId, "originData does not round-trip to the same orderId");

                // The decoded user must match
                assertEq(decoded.user, order.user);
            }
            break;
        }
        assertTrue(found, "Open event not emitted");
    }

    /// @notice Proves resolveFor also encodes originData correctly.
    function test_resolveFor_OriginDataDecodesAsGaslessCrossChainOrder() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);

        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolveFor(order, originFillerData);

        for (uint256 i; i < resolved.fillInstructions.length; ++i) {
            IOriginSettler.GaslessCrossChainOrder memory decoded =
                abi.decode(resolved.fillInstructions[i].originData, (IOriginSettler.GaslessCrossChainOrder));

            bytes32 decodedOrderId = LibSettlerHashing.computeOrderId(address(settler), decoded);
            assertEq(decodedOrderId, resolved.orderId, "resolveFor originData does not round-trip");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  H4: ERC-7683 guards
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_RevertsOnWrongOriginSettler() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        order.originSettler = address(0xDEAD);
        // Re-encode orderData is not needed since guard checks before decode
        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(WrongOriginSettler.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_RevertsOnWrongOriginChain() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        order.originChainId = block.chainid + 1;
        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(WrongOriginChain.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_RevertsOnExpiredOpenDeadline() public {
        vm.warp(1000);
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        order.openDeadline = uint32(block.timestamp - 1);
        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(OpenDeadlinePassed.selector);
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_ZeroOpenDeadline_FallsBackToFillDeadline() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        order.openDeadline = 0;
        // fillDeadline is in the future by default, so this should NOT revert
        // Re-encode orderData to keep consistency
        order.orderData = order.orderData; // unchanged
        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        // Should succeed without reverting
        settler.openFor(order, sig, originFillerData);
    }

    function test_openFor_RevertsOnExpiredFillDeadline_WhenOpenDeadlineIsZero() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        order.openDeadline = 0;
        order.fillDeadline = uint32(block.timestamp - 1);
        bytes memory sig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        vm.expectRevert(OpenDeadlinePassed.selector);
        settler.openFor(order, sig, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  N3: Idempotency short-circuit
    // ═══════════════════════════════════════════════════════════════

    function test_openFor_IdempotentOnReopen_NoSigRecovery() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        bytes memory validSig = _signOrder(order, user, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, REPAY_TO);

        // First open succeeds
        settler.openFor(order, validSig, originFillerData);

        // Second open with INVALID sig returns without reverting (idempotent)
        bytes memory invalidSig =
            hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
        settler.openFor(order, invalidSig, originFillerData);
    }
}
