// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved. Only used in tests — not shipped as part of
// the deployed contracts.
/// @dev Forked from phoenix@40d9b17/test/forge/mocks/DummyERC20.sol. Re-sync on lib/cellar bumps
///      that classify as rollover-affecting (see plan/implementation-plan.md → Mid-plan submodule
///      bump procedure).

import {ERC20, ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";

/**
 * @title DummyERC20 Contract
 * @author Cork Team
 * @notice Dummy contract which provides ERC20
 */
contract DummyERC20 is ERC20Mock {
    uint8 internal __decimals;

    constructor(string memory name, string memory symbol, uint8 _decimals) ERC20(name, symbol) {
        __decimals = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return __decimals;
    }
}
