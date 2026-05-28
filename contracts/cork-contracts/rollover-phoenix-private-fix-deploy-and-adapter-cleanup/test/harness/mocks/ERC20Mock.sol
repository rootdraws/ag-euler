// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved. Only used in tests — not shipped as part of
// the deployed contracts.
/// @dev Forked from phoenix@40d9b17/test/forge/mocks/ERC20Mock.sol. Re-sync on lib/cellar bumps
///      that classify as rollover-affecting (see plan/implementation-plan.md → Mid-plan submodule
///      bump procedure).

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title ERC20Mock Contract
 * @author Cork Team
 * @notice Mock contract which provides ERC20
 */
abstract contract ERC20Mock is ERC20Burnable {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    fallback() external payable {
        deposit();
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function redeem(uint256 wad) public {
        _burn(msg.sender, wad);
        emit Withdrawal(msg.sender, wad);

        payable(msg.sender).transfer(wad);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
