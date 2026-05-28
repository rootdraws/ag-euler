// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title EvcRolloverAdapter_CallPath
/// @notice Smoke integration for the single-item `evc.call` path: the adapter resolves
///         `getCurrentOnBehalfOfAccount` correctly when invoked via `evc.call(adapter, subaccount,
///         0, calldata)` rather than `evc.batch([...])`. Proves the adapter does not assume the
///         `batch` frame specifically — both paths yield a non-zero on-behalf-of account.
contract EvcRolloverAdapter_CallPath is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    address internal subaccount;

    function setUp() public override {
        super.setUp();
        subaccount = AUTHORIZED_CALLER;
    }

    /// @notice Adapter invoked through `evc.call` succeeds and settles the order end-to-end.
    function test_callPath_deliversDstCstAndSettlesOrder() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcCall(
            evcAdapterExact, subaccount, abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled via call path");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }

    /// @notice Adapter-side invariants hold after the `evc.call` path: INV-F2 (zero allowance),
    ///         INV-F1 (no dstCst leak), INV-F4 (zero ERC-6909 balance).
    function test_callPath_adapterPostStateIsClean() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcCall(
            evcAdapterExact, subaccount, abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination
        );

        // Mock-env carve-out: TestMintModule does not consume srcCST from the adapter's allowance.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE);
        uint256 tokenId = uint256(uint160(od.premiumToken));
        assertEq(premium.balanceOf(address(evcAdapterExact), tokenId), 0, "INV-F4 adapter ERC-6909 == 0");
    }
}
