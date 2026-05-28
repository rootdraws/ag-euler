// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {BaseTestSettler} from "test/BaseTestSettler.sol";
import {MockBaseSettler} from "test/base/MockBaseSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";

/// @title BaseSettlerTestBase
/// @notice Shared setup for all BaseSettler unit-test suites. Deploys a `MockBaseSettler` and
///         provides minimal implementations of the abstract signing / snapshot hooks that
///         `BaseTestSettler` requires.
abstract contract BaseSettlerTestBase is BaseTestSettler {
    MockBaseSettler internal mockSettler;

    function setUp() public virtual override {
        super.setUp();
        mockSettler = new MockBaseSettler(address(factory), address(premium));
    }

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler)
        internal
        view
        override
        returns (bytes memory signature)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", MockBaseSettler(settler).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        signature = abi.encodePacked(r, s, v);
    }

    function _signOrderWithSmartWallet(IOriginSettler.GaslessCrossChainOrder memory, address, address)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signCancel(bytes32, uint256, Vm.Wallet memory, address) internal pure override returns (bytes memory) {
        return "";
    }

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory) {
        return SettlerSnapshot(0, 0, 0, 0, 0);
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}
}
