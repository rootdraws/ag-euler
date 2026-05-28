// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PartialRolloverFillerTestBase} from "test/filler/partial/PartialRolloverFillerTestBase.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, OrderInTerminalState} from "contracts/interfaces/RolloverTypes.sol";

/// @title RolloverFiller_PartialTwoFillers
/// @notice Integration scenario demonstrating the DP-A per-user Partial deployment pattern: the
///         `PartialFillSettler` keys per-filler state on `msg.sender` (the filler contract), and
///         `PartialRolloverFiller.execute` atomically calls `finaliseAsSettled(digest, [address(this)])`
///         at the end of every run. Together these force one `PartialRolloverFiller(partial)` instance
///         per caller identity — a single shared filler would collapse every EOA into one slot
///         and the second caller would revert with `AlreadyFilledByFiller` (or with
///         `OrderInTerminalState` once the first filler's atomic finalise latched).
/// @dev Two scenarios:
///        1. Per-user isolation across DISTINCT orders — each filler owns its own digest, state
///           slots are independent, no collision.
///        2. DP-A constraint on SAME order — the second filler's `execute` bubbles
///           `OrderInTerminalState` because the first filler's atomic finalise already settled
///           the order at `participantCount == 1`. This is the behavioural justification for
///           per-user deployment over a shared Partial filler.
contract RolloverFiller_PartialTwoFillers is PartialRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    struct OrderBundle {
        IOriginSettler.GaslessCrossChainOrder order;
        OrderData od;
        bytes sig;
        bytes ofd;
    }

    function _buildBundle(address dest_) internal returns (OrderBundle memory b) {
        (b.order, b.od, b.sig, b.ofd) = _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, dest_);
    }

    function _runExecute(PartialRolloverFiller filler, OrderBundle memory b, address caller_, address dest_) internal {
        _preconditions(caller_, filler, b.od.srcCstToken, ORDER_SIZE, b.od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(filler, abi.encode(b.order), b.sig, b.ofd, ORDER_SIZE, caller_, dest_, caller_);
    }

    /// @notice Two distinct PartialRolloverFiller deployments settle two independent orders with no collision.
    function test_partialTwoFillers_independentOrders_settleInParallel() external {
        PartialRolloverFiller fillerA = new PartialRolloverFiller(address(partialSettler), address(factory));
        PartialRolloverFiller fillerB = new PartialRolloverFiller(address(partialSettler), address(factory));

        address callerA = makeAddr("callerA");
        address callerB = makeAddr("callerB");
        address destA = makeAddr("destA");
        address destB = makeAddr("destB");

        OrderBundle memory bA = _buildBundle(destA);
        vm.warp(block.timestamp + 1);
        OrderBundle memory bB = _buildBundle(destB);

        _runExecute(fillerA, bA, callerA, destA);
        _runExecute(fillerB, bB, callerB, destB);

        bytes32 orderIdA = LibSettlerHashing.computeOrderId(address(partialSettler), bA.order);
        bytes32 orderIdB = LibSettlerHashing.computeOrderId(address(partialSettler), bB.order);
        assertEq(uint8(partialSettler.orderStatus(orderIdA)), uint8(OrderStatus.Settled), "A settled");
        assertEq(uint8(partialSettler.orderStatus(orderIdB)), uint8(OrderStatus.Settled), "B settled");

        assertEq(IERC20(bA.od.dstCstToken).balanceOf(destA), ORDER_SIZE, "dstCST to destA");
        assertEq(IERC20(bB.od.dstCstToken).balanceOf(destB), ORDER_SIZE, "dstCST to destB");

        bytes32 digestA = LibSettlerHashing.computeOrderDigest(address(partialSettler), bA.order, bA.od);
        bytes32 digestB = LibSettlerHashing.computeOrderDigest(address(partialSettler), bB.order, bB.od);

        IPartialFillSettler.FillerRollover memory frAA = partialSettler.fillerRollovers(digestA, address(fillerA));
        IPartialFillSettler.FillerRollover memory frAB = partialSettler.fillerRollovers(digestA, address(fillerB));
        IPartialFillSettler.FillerRollover memory frBA = partialSettler.fillerRollovers(digestB, address(fillerA));
        IPartialFillSettler.FillerRollover memory frBB = partialSettler.fillerRollovers(digestB, address(fillerB));

        assertTrue(frAA.finalised, "fillerA finalised on digestA");
        assertTrue(frBB.finalised, "fillerB finalised on digestB");
        assertEq(frAB.srcCstProvided, 0, "fillerB has no slot on digestA");
        assertEq(frBA.srcCstProvided, 0, "fillerA has no slot on digestB");
    }

    /// @notice DP-A: on the same Partial order, the second filler's atomic execute reverts terminal.
    function test_partialTwoFillers_sameOrder_secondFillerRevertsTerminalAfterFirstAtomicSettle() external {
        PartialRolloverFiller fillerA = new PartialRolloverFiller(address(partialSettler), address(factory));
        PartialRolloverFiller fillerB = new PartialRolloverFiller(address(partialSettler), address(factory));

        address callerA = makeAddr("callerA");
        address callerB = makeAddr("callerB");

        OrderBundle memory b = _buildBundle(destination);

        _runExecute(fillerA, b, callerA, destination);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), b.order);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "settled after A");

        // Fund callerB on fillerB and attempt — reverts on terminal-state guard.
        _preconditions(callerB, fillerB, b.od.srcCstToken, ORDER_SIZE, b.od.premiumToken, PREMIUM_DEPOSIT);
        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(fillerB, abi.encode(b.order), b.sig, b.ofd, ORDER_SIZE, callerB, destination, callerB);
    }

    /// @notice Per-filler deployments keep filler-side invariants F1/F2/F4 on both deployments.
    function test_partialTwoFillers_bothPostStatesClean() external {
        PartialRolloverFiller fillerA = new PartialRolloverFiller(address(partialSettler), address(factory));
        PartialRolloverFiller fillerB = new PartialRolloverFiller(address(partialSettler), address(factory));

        address callerA = makeAddr("callerA");
        address callerB = makeAddr("callerB");
        address destA = makeAddr("destA");
        address destB = makeAddr("destB");

        OrderBundle memory bA = _buildBundle(destA);
        vm.warp(block.timestamp + 1);
        OrderBundle memory bB = _buildBundle(destB);

        _runExecute(fillerA, bA, callerA, destA);
        _runExecute(fillerB, bB, callerB, destB);

        address[] memory toks = new address[](2);
        toks[0] = bA.od.srcCstToken;
        toks[1] = bA.od.dstCstToken;
        _fillerSnapshot(fillerA, toks);
        _fillerSnapshot(fillerB, toks);

        uint256 tokenId = uint256(uint160(bA.od.premiumToken));
        assertEq(premium.balanceOf(address(fillerA), tokenId), 0, "fillerA INV-F4");
        assertEq(premium.balanceOf(address(fillerB), tokenId), 0, "fillerB INV-F4");
    }
}
