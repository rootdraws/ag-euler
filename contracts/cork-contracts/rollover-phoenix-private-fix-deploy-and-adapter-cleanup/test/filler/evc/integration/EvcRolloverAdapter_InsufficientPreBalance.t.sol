// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IEvcPartialFillAdapter} from "contracts/interfaces/IEvcPartialFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

/// @title EvcRolloverAdapter_InsufficientPreBalance
/// @notice Asserts the adapter's pre-balance guard: when the adapter holds less srcCST than
///         `srcCstAmount`, `execute` reverts with `EvcExactFillAdapter__InsufficientTokens(token,
///         required, available)` and the whole `evc.batch` rolls back atomically.
contract EvcRolloverAdapter_InsufficientPreBalance is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;

    address internal subaccount;

    function setUp() public override {
        super.setUp();
        subaccount = AUTHORIZED_CALLER;
    }

    /// @notice Adapter holds zero srcCST and the batch lacks a seeding step → reverts with
    ///         `available == 0`.
    function test_insufficientPreBalance_zeroBalance_revertsInsufficientTokens() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcExactFillAdapter.EvcExactFillAdapter__InsufficientTokens.selector, od.srcCstToken, ORDER_SIZE, 0
            )
        );
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    /// @notice Under-funded seed: adapter holds some srcCST but less than the requested
    ///         `srcCstAmount` → reverts with the actual `available` amount.
    function test_insufficientPreBalance_underfundedSeed_revertsInsufficientTokens() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 short = ORDER_SIZE / 3;
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, short);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcExactFillAdapter.EvcExactFillAdapter__InsufficientTokens.selector, od.srcCstToken, ORDER_SIZE, short
            )
        );
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    /// @notice Partial adapter mirrors the same guard.
    function test_insufficientPreBalance_partialAdapter_zeroBalance_reverts() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcPartialFillAdapter.EvcPartialFillAdapter__InsufficientTokens.selector, od.srcCstToken, ORDER_SIZE, 0
            )
        );
        _executeViaEvcBatch(
            evcAdapterPartial,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }
}
