// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {BaseTestFiller} from "test/filler/BaseTestFiller.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IExactRolloverFiller} from "contracts/interfaces/IExactRolloverFiller.sol";
import {IPartialRolloverFiller} from "contracts/interfaces/IPartialRolloverFiller.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";

/// @title HarnessSmokeTest
/// @notice Smoke test for the post-split filler pair. Confirms each canonical filler deploys,
///         immutables bind to the expected settler, constructor-time shape guards trigger on
///         mis-bindings, and expected threat-model tags surface the correct string.
contract HarnessSmokeTest is BaseTestFiller {
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
    //  Tests
    // ═══════════════════════════════════════════════════════════════

    function test_immutablesSetOnExactFiller() public view {
        assertEq(rolloverFillerExact.SETTLER(), address(exactSettler), "exact filler SETTLER mismatch");
    }

    function test_immutablesSetOnPartialFiller() public view {
        assertEq(rolloverFillerPartial.SETTLER(), address(partialSettler), "partial filler SETTLER mismatch");
        assertEq(rolloverFillerPartial.FACTORY(), address(factory), "partial filler FACTORY mismatch");
    }

    function test_fillersBindToDistinctSettlers() public view {
        assertTrue(
            rolloverFillerExact.SETTLER() != rolloverFillerPartial.SETTLER(),
            "exact and partial fillers bind to same settler"
        );
    }

    /// @dev Both fillers require `debitFrom == msg.sender` OR operator-authorisation. The test
    ///      contract is msg.sender, so pass `address(this)` to short-circuit the A2 guard. The
    ///      empty-orderData decode then reverts with no return data.
    function test_executeRevertsOnEmptyOrderDataPartial() public {
        vm.expectRevert(bytes(""));
        rolloverFillerPartial.execute("", "", "", 0, address(this), address(0xCAFE));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Mis-binding guards
    // ═══════════════════════════════════════════════════════════════

    /// @dev `ExactRolloverFiller(partialSettler, _)` — the Partial-only probe succeeds on a
    ///      Partial settler, signalling a mis-binding on the Exact path.
    function test_constructorRevertsWhenExactBoundToPartialSettler() public {
        vm.expectRevert(IExactRolloverFiller.ExactRolloverFiller__SettlerMismatch.selector);
        new ExactRolloverFiller(address(partialSettler), address(0));
    }

    /// @dev `PartialRolloverFiller(exactSettler, _)` — the Partial probe fails on an Exact
    ///      settler; the constructor refuses.
    function test_constructorRevertsWhenPartialBoundToExactSettler() public {
        vm.expectRevert(IPartialRolloverFiller.PartialRolloverFiller__SettlerMismatch.selector);
        new PartialRolloverFiller(address(exactSettler), address(factory));
    }

    /// @dev Partial binding with a wrong factory argument reverts at deploy.
    function test_constructorRevertsWhenPartialFactoryMismatched() public {
        address bogusFactory = address(0xBADFACE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPartialRolloverFiller.PartialRolloverFiller__FactoryMismatch.selector, bogusFactory, address(factory)
            )
        );
        new PartialRolloverFiller(address(partialSettler), bogusFactory);
    }

    /// @dev Exact binding must pass `expectedFactory_ = address(0)` — any other value trips the
    ///      FactoryMustBeZero guard.
    function test_constructorRevertsWhenExactPassedNonZeroFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IExactRolloverFiller.ExactRolloverFiller__FactoryMustBeZero.selector, address(factory)
            )
        );
        new ExactRolloverFiller(address(exactSettler), address(factory));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Threat-model NatSpec tag (test-spec §138)
    // ═══════════════════════════════════════════════════════════════

    function test_threatModelTagOnExactFiller() public view {
        assertEq(
            rolloverFillerExact.EXPECTED_THREAT_MODEL(),
            "shared-singleton",
            "Exact filler must surface shared-singleton threat model"
        );
    }

    function test_threatModelTagOnPartialFiller() public view {
        assertEq(
            rolloverFillerPartial.EXPECTED_THREAT_MODEL(),
            "shared-singleton",
            "Partial filler must surface shared-singleton threat model"
        );
    }
}
