// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcPartialFillAdapterTestBase} from "test/filler/evc/partial/EvcPartialFillAdapterTestBase.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, OrderInTerminalState} from "contracts/interfaces/RolloverTypes.sol";

/// @title EvcRolloverAdapter_PartialSameDigestTerminal
/// @notice Asserts atomic-execute's self-finalising semantics close out a Partial order to other
///         adapters: adapter-A runs `execute` on digest-X and the adapter's trailing
///         `finaliseAsSettled(digest, [address(this)])` flips the order to terminal. Adapter-B's
///         subsequent `execute` on the same digest reverts with `OrderInTerminalState` at the
///         rollover leg inside the settler.
contract EvcRolloverAdapter_PartialSameDigestTerminal is EvcPartialFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    /// @notice Second adapter on the same digest reverts with `OrderInTerminalState` after
    ///         the first adapter's atomic finalise.
    function test_partialSameDigest_secondAdapterRevertsTerminal() external {
        address subA = makeAddr("subA");
        address subB = makeAddr("subB");
        EvcPartialFillAdapter adapterA =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subA);
        EvcPartialFillAdapter adapterB =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subB);

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Adapter-A preconditions + execute → flips order terminal.
        _authoriseAdapterOperator(subA, adapterA);
        _prepareAdapterErc6909(subA, adapterA, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterA, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            adapterA, subA, _noItems(), _noItems(), abi.encode(order), sig, ofd, ORDER_SIZE, subA, destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled after adapterA");

        // Adapter-B tries the same digest — reverts terminal at rollover leg inside settler.
        _authoriseAdapterOperator(subB, adapterB);
        _prepareAdapterErc6909(subB, adapterB, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterB, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(OrderInTerminalState.selector);
        _executeViaEvcBatch(
            adapterB, subB, _noItems(), _noItems(), abi.encode(order), sig, ofd, ORDER_SIZE, subB, destination
        );
    }

    /// @notice After the second adapter's reverted `execute`, the settler's order status is
    ///         unchanged and the second adapter retains its seeded srcCST (atomic revert parity).
    function test_partialSameDigest_secondAdapterRevertLeavesStateUntouched() external {
        address subA = makeAddr("subA3");
        address subB = makeAddr("subB3");
        EvcPartialFillAdapter adapterA =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subA);
        EvcPartialFillAdapter adapterB =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subB);

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subA, adapterA);
        _prepareAdapterErc6909(subA, adapterA, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterA, od.srcCstToken, ORDER_SIZE);
        _executeViaEvcBatch(
            adapterA, subA, _noItems(), _noItems(), abi.encode(order), sig, ofd, ORDER_SIZE, subA, destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        uint8 statusAfterA = uint8(partialSettler.orderStatus(orderId));

        _authoriseAdapterOperator(subB, adapterB);
        _prepareAdapterErc6909(subB, adapterB, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterB, od.srcCstToken, ORDER_SIZE);

        uint256 adapterBPreSrc = IERC20(od.srcCstToken).balanceOf(address(adapterB));

        vm.expectRevert(OrderInTerminalState.selector);
        _executeViaEvcBatch(
            adapterB, subB, _noItems(), _noItems(), abi.encode(order), sig, ofd, ORDER_SIZE, subB, destination
        );

        assertEq(uint8(partialSettler.orderStatus(orderId)), statusAfterA, "order status unchanged by adapterB attempt");
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(adapterB)),
            adapterBPreSrc,
            "adapterB srcCST unchanged (atomic revert parity)"
        );
        assertEq(
            IERC20(od.srcCstToken).allowance(address(adapterB), address(partialSettler)),
            0,
            "adapterB zero allowance post-revert (INV-F2)"
        );
    }
}
