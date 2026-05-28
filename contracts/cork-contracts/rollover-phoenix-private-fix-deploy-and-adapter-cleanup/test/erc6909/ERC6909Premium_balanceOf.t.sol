// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";

contract ERC6909Premium_balanceOf_Test is Test {
    ERC6909Premium internal premium;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal filler = makeAddr("filler");

    function setUp() public {
        premium = new ERC6909Premium();
        token = new MockERC20();
        token.mint(owner, 1_000 ether);
        vm.prank(owner);
        token.approve(address(premium), type(uint256).max);
    }

    // ─── when (owner, tokenId) has never received a deposit ─────────────────────────────────

    function test_when_no_deposit_it_should_return_zero() public {
        address untouched = makeAddr("untouched");
        uint256 tokenId = uint256(uint160(address(token)));
        assertEq(premium.balanceOf(untouched, tokenId), 0, "unfunded account should be zero");
    }

    // ─── when (owner, tokenId) has deposits net of withdrawals and settles ─────────────────

    function test_when_deposits_net_of_withdrawals_and_settles_it_should_return_net_balance() public {
        uint256 tokenId = uint256(uint160(address(token)));

        // Deposit 500, withdraw 100, settle 200 → net 200.
        vm.startPrank(owner);
        premium.deposit(address(token), owner, 500 ether);
        premium.withdraw(tokenId, recipient, 100 ether);
        premium.setOperator(owner, true); // owner is implicitly authorized; redundant but harmless
        premium.setOperator(filler, true);
        premium.settle(owner, filler, tokenId, 200 ether, recipient);
        vm.stopPrank();

        assertEq(premium.balanceOf(owner, tokenId), 200 ether, "net balance wrong after deposit/withdraw/settle");
    }
}
