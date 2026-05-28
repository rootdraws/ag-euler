// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";

/// @dev Reenters ERC6909Premium.withdraw from inside an ERC-20 transfer callback to prove the
///      nonReentrant modifier fires.
contract WithdrawReentrant {
    ERC6909Premium public premium;
    MockERC20 public token;
    bool public attack;

    constructor(ERC6909Premium _premium, MockERC20 _token) {
        premium = _premium;
        token = _token;
    }

    function setAttack(bool v) external {
        attack = v;
    }

    function onTransferCallback() external {
        if (attack) {
            // Reenter withdraw — should revert with ReentrancyGuardReentrantCall and bubble.
            premium.withdraw(uint256(uint160(address(token))), address(this), 1);
        }
    }
}

contract ERC6909Premium_withdraw_Test is Test {
    ERC6909Premium internal premium;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal to = makeAddr("to");

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    function setUp() public {
        premium = new ERC6909Premium();
        token = new MockERC20();

        token.mint(owner, 1_000 ether);
        vm.startPrank(owner);
        token.approve(address(premium), type(uint256).max);
        premium.deposit(address(token), owner, 500 ether);
        vm.stopPrank();
    }

    // ─── when amount is zero ──────────────────────────────────────────────────────────────────

    function test_when_amount_is_zero_it_should_noop() public {
        uint256 tokenId = uint256(uint160(address(token)));
        uint256 balBefore = premium.balanceOf(owner, tokenId);
        uint256 tokenBalBefore = token.balanceOf(owner);
        uint256 premiumBalBefore = token.balanceOf(address(premium));

        vm.prank(owner);
        premium.withdraw(tokenId, to, 0);

        assertEq(premium.balanceOf(owner, tokenId), balBefore, "6909 balance moved");
        assertEq(token.balanceOf(owner), tokenBalBefore, "owner ERC20 balance moved");
        assertEq(token.balanceOf(address(premium)), premiumBalBefore, "premium ERC20 balance moved");
    }

    function test_when_amount_is_zero_it_should_not_call_safeTransfer() public {
        token.setRevertOnZeroTransfer(true);
        uint256 tokenId = uint256(uint160(address(token)));

        // This should NOT revert because we short-circuit before safeTransfer
        vm.prank(owner);
        premium.withdraw(tokenId, to, 0);
    }

    // ─── when msg.sender has insufficient balance for the tokenId ───────────────────────────

    function test_when_insufficient_balance_it_should_revert_InsufficientBalance() public {
        uint256 tokenId = uint256(uint160(address(token)));
        vm.prank(owner);
        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        premium.withdraw(tokenId, to, 1_000 ether);
    }

    // ─── when to is the zero address ────────────────────────────────────────────────────────

    function test_when_to_is_zero_it_should_revert_InvalidRecipient() public {
        uint256 tokenId = uint256(uint160(address(token)));
        vm.prank(owner);
        vm.expectRevert(IERC6909Premium.InvalidRecipient.selector);
        premium.withdraw(tokenId, address(0), 1 ether);
    }

    // ─── when all preconditions hold ────────────────────────────────────────────────────────

    function test_when_all_preconditions_hold_it_should_decrement_transfer_and_emit() public {
        uint256 tokenId = uint256(uint160(address(token)));
        uint256 amount = 100 ether;

        uint256 credBefore = premium.balanceOf(owner, tokenId);
        uint256 escrowBefore = token.balanceOf(address(premium));
        uint256 toBefore = token.balanceOf(to);

        vm.expectEmit(true, true, true, true, address(premium));
        emit Transfer(owner, owner, address(0), tokenId, amount);

        vm.prank(owner);
        premium.withdraw(tokenId, to, amount);

        assertEq(premium.balanceOf(owner, tokenId), credBefore - amount, "credit not decremented");
        assertEq(token.balanceOf(address(premium)), escrowBefore - amount, "escrow not debited");
        assertEq(token.balanceOf(to), toBefore + amount, "recipient not paid");
    }

    // ─── when the underlying token transfer reverts ─────────────────────────────────────────

    function test_when_token_transfer_reverts_it_should_bubble_and_leave_balance_unchanged() public {
        uint256 tokenId = uint256(uint160(address(token)));
        token.setRevertOnTransfer(true);

        uint256 credBefore = premium.balanceOf(owner, tokenId);

        vm.prank(owner);
        vm.expectRevert(bytes("MockERC20: transfer reverted"));
        premium.withdraw(tokenId, to, 50 ether);

        assertEq(premium.balanceOf(owner, tokenId), credBefore, "balance mutated across reverting tx");
    }

    // ─── when a reentrant withdraw is attempted ─────────────────────────────────────────────

    function test_when_reentrant_withdraw_it_should_revert_ReentrancyGuardReentrantCall() public {
        // Build a fresh stack: attacker owns the premium credit, attacker calls withdraw,
        // token's transfer hook reenters withdraw.
        WithdrawReentrant attacker = new WithdrawReentrant(premium, token);
        token.mint(address(attacker), 10 ether);

        vm.startPrank(address(attacker));
        token.approve(address(premium), type(uint256).max);
        premium.deposit(address(token), address(attacker), 10 ether);
        vm.stopPrank();

        token.setTransferHook(address(attacker));
        attacker.setAttack(true);

        vm.prank(address(attacker));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        premium.withdraw(uint256(uint160(address(token))), address(attacker), 1 ether);
    }
}
