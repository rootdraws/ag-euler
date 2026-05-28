// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactRolloverFillerTestBase} from "test/filler/exact/ExactRolloverFillerTestBase.sol";
import {PartialRolloverFillerTestBase} from "test/filler/partial/PartialRolloverFillerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, OrderInTerminalState, InconsistentIntent} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";

/// @title RolloverFiller_CancelNoFills (Exact binding)
/// @notice Case 1 — pre-fill cancel scenario: UW cancels an Opened order before any fill; the
///         filler's subsequent `execute` reverts with the settler's terminal-state guard
///         (`OrderInTerminalState`), which is what a caller observing the public cancel must
///         see. Case 2a — cross-binding isolation: the Exact filler applied to a Partial-flagged
///         order reverts via the Exact settler's `InconsistentIntent` validation; the filler
///         does not paper over the incompatible `allowPartialFills` flag.
contract RolloverFiller_CancelNoFills_Exact is ExactRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    /// @notice UW cancels a pre-fill order; subsequent filler execute reverts terminal.
    function test_cancelNoFills_uwCancelsOpenedOrder_executeReverts() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // UW opens and then self-cancels (no cellar signature needed when msg.sender == user).
        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        vm.prank(user.addr);
        exactSettler.finaliseAsCancelled(orderId, order, "");
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Cancelled), "order cancelled");

        // Filler execute now hits BaseSettler's terminal-state guard on fill.
        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    /// @notice Cross-binding: Exact filler rejects a Partial-flagged order via InconsistentIntent.
    function test_cancelNoFills_exactFiller_rejectsPartialFlaggedOrder() external {
        // Build an order whose `allowPartialFills == true`; the Exact settler's `_validateOpen`
        // rejects with `InconsistentIntent`. The filler does not coerce the flag.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, true, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.expectRevert(InconsistentIntent.selector);
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }
}

/// @title RolloverFiller_CancelNoFills_Partial
/// @notice Case 2b — cross-binding isolation on the Partial side: a Partial filler applied to an
///         Exact-flagged order (`allowPartialFills == false`) reverts via the Partial settler's
///         `_validateOpen` guard with `InconsistentIntent`. Symmetric to the Exact-side case.
contract RolloverFiller_CancelNoFills_Partial is PartialRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    /// @notice Cross-binding: Partial filler rejects an Exact-flagged order via InconsistentIntent.
    function test_cancelNoFills_partialFiller_rejectsExactFlaggedOrder() external {
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(partialSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(partialSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.expectRevert(InconsistentIntent.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }
}
