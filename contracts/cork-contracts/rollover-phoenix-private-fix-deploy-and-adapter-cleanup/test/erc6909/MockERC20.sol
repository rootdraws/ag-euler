// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMockTransferHook {
    function onTransferCallback() external;
}

/// @title MockERC20
/// @notice Test-only ERC20 with per-test toggles for pathological behaviours that Phoenix's
///         `DummyERC20` does not cover: reverting transfers, silent-false transfers, and a hook
///         that re-enters a target contract on `transfer` / `transferFrom`. No ownership, no
///         pause — only flags readable and writable by any caller.
contract MockERC20 is ERC20 {
    bool public revertOnTransfer;
    bool public revertOnTransferFrom;
    bool public revertOnZeroTransfer;
    bool public returnFalseOnTransfer;
    bool public returnFalseOnTransferFrom;

    /// @dev When set, `transfer` calls this address's fallback via a low-level call — the hook
    ///      implements any reentrant logic. Used by the reentrancy-guard tests.
    address public transferHook;

    constructor() ERC20("MockERC20", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRevertOnTransfer(bool v) external {
        revertOnTransfer = v;
    }

    function setRevertOnTransferFrom(bool v) external {
        revertOnTransferFrom = v;
    }

    function setRevertOnZeroTransfer(bool v) external {
        revertOnZeroTransfer = v;
    }

    function setReturnFalseOnTransfer(bool v) external {
        returnFalseOnTransfer = v;
    }

    function setReturnFalseOnTransferFrom(bool v) external {
        returnFalseOnTransferFrom = v;
    }

    function setTransferHook(address hook) external {
        transferHook = hook;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (revertOnZeroTransfer && amount == 0) {
            revert("MockERC20: zero transfer reverted");
        }
        if (revertOnTransfer) {
            revert("MockERC20: transfer reverted");
        }
        if (returnFalseOnTransfer) {
            return false;
        }
        if (transferHook != address(0)) {
            // Direct external call — if the hook reverts, Solidity bubbles the raw revert data
            // so tests asserting `ReentrancyGuardReentrantCall.selector` see the original error.
            IMockTransferHook(transferHook).onTransferCallback();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (revertOnTransferFrom) {
            revert("MockERC20: transferFrom reverted");
        }
        if (returnFalseOnTransferFrom) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
