// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IEvcPartialFillAdapter} from "contracts/interfaces/IEvcPartialFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {BaseTestEvcFillerAdapter} from "test/filler/BaseTestEvcFillerAdapter.sol";

/// @title HarnessSmokeTest
/// @notice Smoke test for the post-split EVC adapter pair. Confirms each canonical adapter
///         deploys, immutables bind to the expected quadruple, constructor-time guards fire on
///         mis-bindings, and the threat-model tag surfaces the correct string.
contract HarnessSmokeTest is BaseTestEvcFillerAdapter {
    // ═══════════════════════════════════════════════════════════════
    //  Abstract-parent stubs
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory, Vm.Wallet memory, address)
        internal
        view
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signOrderWithSmartWallet(IOriginSettler.GaslessCrossChainOrder memory, address, address)
        internal
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signCancel(bytes32, uint256, Vm.Wallet memory, address) internal view override returns (bytes memory) {
        return "";
    }

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory s) {
        return s;
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}

    // ═══════════════════════════════════════════════════════════════
    //  Immutable bindings
    // ═══════════════════════════════════════════════════════════════

    function test_immutablesSetOnExactAdapter() public view {
        assertEq(evcAdapterExact.SETTLER(), address(exactSettler), "exact adapter SETTLER mismatch");
        assertEq(evcAdapterExact.FACTORY(), address(0), "exact adapter FACTORY should be zero");
        assertEq(evcAdapterExact.EVC(), address(evc), "exact adapter EVC mismatch");
    }

    function test_immutablesSetOnPartialAdapter() public view {
        assertEq(evcAdapterPartial.SETTLER(), address(partialSettler), "partial adapter SETTLER mismatch");
        assertEq(evcAdapterPartial.FACTORY(), address(factory), "partial adapter FACTORY should be factory");
        assertEq(evcAdapterPartial.EVC(), address(evc), "partial adapter EVC mismatch");
    }

    function test_adaptersBindToDistinctSettlers() public view {
        assertTrue(
            evcAdapterExact.SETTLER() != evcAdapterPartial.SETTLER(), "exact and partial adapters bind to same settler"
        );
    }

    function test_evcIsNonZero() public view {
        assertTrue(address(evc) != address(0), "evc must be deployed");
        assertTrue(evcAdapterExact.EVC() != address(0), "exact adapter EVC must be non-zero");
        assertTrue(evcAdapterPartial.EVC() != address(0), "partial adapter EVC must be non-zero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Stub revert surface via evc.call — direct-call rejection
    // ═══════════════════════════════════════════════════════════════

    function test_executeViaCallRevertsOnExactForeignSubaccount() public {
        address subaccount = address(0xBEEF);
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        _executeViaEvcCall(evcAdapterExact, subaccount, "", "", "", 0, address(0xBEEF), address(0xCAFE));
    }

    function test_executeViaCallRevertsOnPartialForeignSubaccount() public {
        address subaccount = address(0xBEEF);
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__InvalidCaller.selector);
        _executeViaEvcCall(evcAdapterPartial, subaccount, "", "", "", 0, address(0xBEEF), address(0xCAFE));
    }

    /// @dev Exercises the `evc.batch` path: the empty-item batch is a no-op; driving the adapter
    ///      with an unauthorised subaccount trips `EvcExactFillAdapter__InvalidCaller` inside
    ///      `_requireAuthenticatedEvcCaller` before any settler logic runs.
    function test_executeViaBatchRevertsOnExactForeignSubaccount() public {
        address subaccount = address(0xBEEF);
        IEVC.BatchItem[] memory empty = new IEVC.BatchItem[](0);
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        _executeViaEvcBatch(evcAdapterExact, subaccount, empty, empty, "", "", "", 0, address(0xBEEF), address(0xCAFE));
    }

    function test_executeViaBatchRevertsOnPartialForeignSubaccount() public {
        address subaccount = address(0xBEEF);
        IEVC.BatchItem[] memory empty = new IEVC.BatchItem[](0);
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__InvalidCaller.selector);
        _executeViaEvcBatch(
            evcAdapterPartial, subaccount, empty, empty, "", "", "", 0, address(0xBEEF), address(0xCAFE)
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Constructor guards
    // ═══════════════════════════════════════════════════════════════

    /// @dev Zero-EVC is rejected on both adapters.
    function test_constructorRevertsWhenEvcIsZero_Exact() public {
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__ZeroEvc.selector);
        new EvcExactFillAdapter(address(exactSettler), address(0), address(0), AUTHORIZED_CALLER);
    }

    function test_constructorRevertsWhenEvcIsZero_Partial() public {
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__ZeroEvc.selector);
        new EvcPartialFillAdapter(address(partialSettler), address(factory), address(0), AUTHORIZED_CALLER);
    }

    function test_constructorRevertsWhenAuthorizedCallerIsZero_Exact() public {
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        new EvcExactFillAdapter(address(exactSettler), address(0), address(evc), address(0));
    }

    function test_constructorRevertsWhenAuthorizedCallerIsZero_Partial() public {
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__InvalidCaller.selector);
        new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), address(0));
    }

    function test_constructorRevertsWhenExactBoundToPartialSettler() public {
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__SettlerMismatch.selector);
        new EvcExactFillAdapter(address(partialSettler), address(0), address(evc), AUTHORIZED_CALLER);
    }

    function test_constructorRevertsWhenPartialBoundToExactSettler() public {
        vm.expectRevert(IEvcPartialFillAdapter.EvcPartialFillAdapter__SettlerMismatch.selector);
        new EvcPartialFillAdapter(address(exactSettler), address(factory), address(evc), AUTHORIZED_CALLER);
    }

    function test_constructorRevertsWhenPartialFactoryMismatched() public {
        address bogusFactory = address(0xBADFACE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcPartialFillAdapter.EvcPartialFillAdapter__FactoryMismatch.selector, bogusFactory, address(factory)
            )
        );
        new EvcPartialFillAdapter(address(partialSettler), bogusFactory, address(evc), AUTHORIZED_CALLER);
    }

    /// @dev Exact binding must pass `expectedFactory_ = address(0)`.
    function test_constructorRevertsWhenExactPassedNonZeroFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcExactFillAdapter.EvcExactFillAdapter__FactoryMustBeZero.selector, address(factory)
            )
        );
        new EvcExactFillAdapter(address(exactSettler), address(factory), address(evc), AUTHORIZED_CALLER);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Threat-model NatSpec tag (test-spec §138)
    // ═══════════════════════════════════════════════════════════════

    function test_threatModelTagOnExactAdapter() public view {
        assertEq(
            evcAdapterExact.EXPECTED_THREAT_MODEL(),
            "per-subaccount",
            "Exact EVC adapter must surface per-subaccount threat model"
        );
    }

    function test_threatModelTagOnPartialAdapter() public view {
        assertEq(
            evcAdapterPartial.EXPECTED_THREAT_MODEL(),
            "per-subaccount",
            "Partial EVC adapter must surface per-subaccount threat model"
        );
    }
}
