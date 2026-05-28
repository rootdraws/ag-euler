// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IEvcPartialFillAdapter} from "contracts/interfaces/IEvcPartialFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

/// @title EvcRolloverAdapter_DirectCallRejected
/// @notice Asserts the EVC gating surface: any invocation of `adapter.execute` that does not
///         resolve `getCurrentOnBehalfOfAccount` to a non-zero account reverts with
///         `EvcExactFillAdapter__InvalidCaller`. Exercises direct EOA calls and calls from an
///         EVC-unaware contract — neither enters an EVC batch/call frame.
contract EvcRolloverAdapter_DirectCallRejected is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;

    address internal subaccount;

    function setUp() public override {
        super.setUp();
        subaccount = AUTHORIZED_CALLER;
    }

    /// @notice Direct `adapter.execute(...)` call from an EOA (not inside `evc.batch` / `evc.call`)
    ///         reverts `InvalidCaller`.
    function test_directCall_fromEoaRevertsInvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        address eoa = makeAddr("eoa-caller");
        vm.prank(eoa);
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        evcAdapterExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);
    }

    /// @notice Call from an EVC-unaware contract bubbles the same `InvalidCaller` revert.
    function test_directCall_fromContractRevertsInvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        NonEvcCaller nec = new NonEvcCaller();
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        nec.pokeExecute(address(evcAdapterExact), abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);
    }

    /// @notice Partial adapter mirrors the same gate.
    function test_directCall_partialFromEoaRevertsInvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        address eoa = makeAddr("eoa-caller-partial");
        vm.prank(eoa);
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__InvalidCaller.selector);
        evcAdapterPartial.execute(abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);
    }

    /// @notice Third direct-call surface per test-spec §7: a hypothetical future EVC revision that
    ///         returns `address(0)` from `getCurrentOnBehalfOfAccount` INSTEAD of reverting (the
    ///         current mainline EVC reverts inside this selector when called outside a batch/call
    ///         frame). The adapter's zero-caller safety-net guard fires independently of the EVC's
    ///         own revert semantics, so `msg.sender == evc` with a zero resolved caller still
    ///         reverts `InvalidCaller`. Proves the guard at `EvcExactFillAdapter._requireAuthenticatedEvcCaller`
    ///         is not dead code on current EVC versions but an explicit version-independent guard.
    function test_directCall_evcFrameWithZeroCallerRevertsInvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Mock the EVC's caller-resolution selector to return `address(0)` — simulating a future
        // revision that reports "no authenticated caller" via return value instead of revert.
        vm.mockCall(
            address(evc),
            abi.encodeWithSelector(IEVC.getCurrentOnBehalfOfAccount.selector, address(0)),
            abi.encode(address(0), false)
        );

        // Caller is the EVC itself (emulating the EVC forwarding a batch item).
        vm.prank(address(evc));
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        evcAdapterExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);

        vm.clearMockedCalls();
    }
}

/// @dev Minimal contract that forwards arguments straight to `adapter.execute` without going
///      through the EVC. Used to prove the adapter rejects EVC-unaware call sites.
contract NonEvcCaller {
    function pokeExecute(
        address adapter,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external {
        (bool ok, bytes memory data) = adapter.call(
            abi.encodeWithSignature(
                "execute(bytes,bytes,bytes,uint256,address,address)",
                orderData,
                signature,
                originFillerData,
                srcCstAmount,
                debitFrom,
                destination
            )
        );
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }
}
