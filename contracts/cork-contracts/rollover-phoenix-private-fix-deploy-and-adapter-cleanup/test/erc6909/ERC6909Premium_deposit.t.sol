// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";

contract ERC6909Premium_deposit_Test is Test {
    ERC6909Premium internal premium;
    MockERC20 internal token;

    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("recipient");

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    function setUp() public {
        premium = new ERC6909Premium();
        token = new MockERC20();
        token.mint(depositor, 1_000 ether);
        vm.prank(depositor);
        token.approve(address(premium), type(uint256).max);
    }

    // ─── when to is the zero address ────────────────────────────────────────────────────────

    function test_when_to_is_zero_address_it_should_revert_InvalidRecipient() public {
        vm.prank(depositor);
        vm.expectRevert(IERC6909Premium.InvalidRecipient.selector);
        premium.deposit(address(token), address(0), 100 ether);
    }

    // ─── when token.transferFrom reverts ────────────────────────────────────────────────────

    function test_when_transferFrom_reverts_it_should_revert_and_leave_balance_unchanged() public {
        uint256 tokenId = uint256(uint160(address(token)));
        token.setRevertOnTransferFrom(true);

        uint256 balBefore = premium.balanceOf(recipient, tokenId);

        vm.prank(depositor);
        vm.expectRevert(bytes("MockERC20: transferFrom reverted"));
        premium.deposit(address(token), recipient, 100 ether);

        assertEq(premium.balanceOf(recipient, tokenId), balBefore, "balance mutated on revert");
    }

    // ─── when amount is zero ────────────────────────────────────────────────────────────────

    function test_when_amount_is_zero_it_should_noop() public {
        uint256 tokenId = uint256(uint160(address(token)));
        uint256 tokenBalBefore = token.balanceOf(depositor);
        uint256 premiumTokenBalBefore = token.balanceOf(address(premium));

        vm.prank(depositor);
        premium.deposit(address(token), recipient, 0);

        assertEq(premium.balanceOf(recipient, tokenId), 0, "6909 balance should stay zero");
        assertEq(token.balanceOf(depositor), tokenBalBefore, "depositor ERC20 balance moved");
        assertEq(token.balanceOf(address(premium)), premiumTokenBalBefore, "premium ERC20 balance moved");
    }

    // ─── when all preconditions hold ────────────────────────────────────────────────────────

    function test_when_all_preconditions_hold_it_should_transferFrom_credit_and_emit() public {
        uint256 tokenId = uint256(uint160(address(token)));
        uint256 amount = 123 ether;

        uint256 depBefore = token.balanceOf(depositor);
        uint256 escrowBefore = token.balanceOf(address(premium));

        vm.expectEmit(true, true, true, true, address(premium));
        emit Transfer(depositor, address(0), recipient, tokenId, amount);

        vm.prank(depositor);
        premium.deposit(address(token), recipient, amount);

        assertEq(premium.balanceOf(recipient, tokenId), amount, "6909 credit wrong");
        assertEq(token.balanceOf(depositor), depBefore - amount, "depositor ERC20 not debited");
        assertEq(token.balanceOf(address(premium)), escrowBefore + amount, "escrow ERC20 not credited");
    }

    // ─── supportsInterface (3 leaves inline) ────────────────────────────────────────────────

    function test_supportsInterface_it_should_return_true_for_erc165_interface_id() public view {
        assertTrue(premium.supportsInterface(0x01ffc9a7), "erc165 id not supported");
    }

    function test_supportsInterface_it_should_return_true_for_erc6909_interface_id() public view {
        assertTrue(premium.supportsInterface(0x0f632fb3), "erc6909 id not supported");
    }

    function test_supportsInterface_it_should_return_false_for_unsupported_interface_id() public view {
        assertFalse(premium.supportsInterface(0xdeadbeef), "garbage id should not be supported");
    }
}
