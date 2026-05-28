// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";

/// @title FinaliseAsCancelled_Reentrancy
/// @notice Verifies the Pashov A5 remediation: `finaliseAsCancelled` carries a `nonReentrant`
///         modifier on both settlers. Although the body performs no external state-changing
///         calls today, the guard is applied as defense-in-depth against future changes and
///         cross-function reentrancy (it shares OZ's single `_status` slot with `fill`,
///         `finaliseAsSettled`, and `finaliseAsRefunded`).
/// @dev Writing `ENTERED` (= 2) into OZ's namespaced ReentrancyGuard storage slot before the
///      call proves the modifier fires. The slot is
///      `keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1))
///      & ~bytes32(uint256(0xff))` per OZ v5.
contract FinaliseAsCancelled_Reentrancy_Test is Test {
    // OZ v5 ReentrancyGuard namespaced storage slot.
    bytes32 internal constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    uint256 internal constant ENTERED = 2;

    PartialFillSettler internal partialSettler;
    ExactFillSettler internal exactSettler;

    function setUp() public {
        // No factory / 6909 interaction needed — the modifier fires before any body logic.
        partialSettler = new PartialFillSettler(address(0xF), address(0x6909));
        exactSettler = new ExactFillSettler(address(0xF), address(0x6909));
    }

    function _emptyGaslessOrder() internal view returns (IOriginSettler.GaslessCrossChainOrder memory order) {
        order.originSettler = address(this);
        order.user = address(this);
        order.nonce = 0;
        order.originChainId = block.chainid;
        order.openDeadline = uint32(block.timestamp + 1);
        order.fillDeadline = uint32(block.timestamp + 2);
        order.orderDataType = bytes32(0);
        order.orderData = bytes("");
    }

    function _armEntered(address target) internal {
        vm.store(target, REENTRANCY_GUARD_STORAGE, bytes32(ENTERED));
    }

    // ═══════════════════════════════════════════════════════════════
    //  PartialFillSettler — finaliseAsCancelled nonReentrant
    // ═══════════════════════════════════════════════════════════════

    /// @notice Partial: ReentrancyGuard armed → `finaliseAsCancelled` reverts with
    ///         `ReentrancyGuardReentrantCall`. Confirms the modifier is wired up.
    function test_partial_finaliseAsCancelled_reentrancy_reverts() public {
        _armEntered(address(partialSettler));

        IOriginSettler.GaslessCrossChainOrder memory order = _emptyGaslessOrder();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        partialSettler.finaliseAsCancelled(bytes32(0), order, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  ExactFillSettler — finaliseAsCancelled nonReentrant
    // ═══════════════════════════════════════════════════════════════

    /// @notice Exact: ReentrancyGuard armed → `finaliseAsCancelled` reverts with
    ///         `ReentrancyGuardReentrantCall`. Confirms the modifier is wired up.
    function test_exact_finaliseAsCancelled_reentrancy_reverts() public {
        _armEntered(address(exactSettler));

        IOriginSettler.GaslessCrossChainOrder memory order = _emptyGaslessOrder();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        exactSettler.finaliseAsCancelled(bytes32(0), order, "");
    }
}
