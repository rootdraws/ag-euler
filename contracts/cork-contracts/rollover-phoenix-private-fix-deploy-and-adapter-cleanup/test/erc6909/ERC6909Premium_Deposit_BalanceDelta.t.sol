// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";
import {FoTToken} from "test/erc6909/FoTToken.sol";

/// @title ERC6909Premium_Deposit_BalanceDelta_Test
/// @notice A4 regression: `deposit` must fail closed with `DepositBalanceMismatch` when the
///         received balance delta differs from `amount`. Exercises both the FoT path (positive
///         mismatch) and the standard-ERC20 happy path (no mismatch — no revert).
contract ERC6909Premium_Deposit_BalanceDelta_Test is Test {
    ERC6909Premium internal premium;
    FoTToken internal fot;
    MockERC20 internal standardToken;

    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        premium = new ERC6909Premium();
        fot = new FoTToken();
        standardToken = new MockERC20();

        fot.mint(depositor, 1_000 ether);
        standardToken.mint(depositor, 1_000 ether);

        vm.startPrank(depositor);
        fot.approve(address(premium), type(uint256).max);
        standardToken.approve(address(premium), type(uint256).max);
        vm.stopPrank();
    }

    // ─── FoT token: received < amount ───────────────────────────────────────────────────────

    function test_when_token_charges_fee_it_should_revert_DepositBalanceMismatch() public {
        fot.setFeeBps(100); // 1% burn
        uint256 amount = 100 ether;
        uint256 expectedReceived = amount - (amount * 100) / 10_000; // 99 ether

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC6909Premium.DepositBalanceMismatch.selector, amount, expectedReceived)
        );
        premium.deposit(address(fot), recipient, amount);

        // State left clean on revert.
        uint256 tokenId = uint256(uint160(address(fot)));
        assertEq(premium.balanceOf(recipient, tokenId), 0, "credit must not land on mismatch");
    }

    // ─── FoT token at zero fee degrades to standard ERC20 ───────────────────────────────────

    function test_when_fee_is_zero_FoT_behaves_standard_and_credits_nominal_amount() public {
        fot.setFeeBps(0);
        uint256 amount = 50 ether;
        uint256 tokenId = uint256(uint160(address(fot)));

        vm.prank(depositor);
        premium.deposit(address(fot), recipient, amount);

        assertEq(premium.balanceOf(recipient, tokenId), amount, "credit should equal nominal amount");
        assertEq(fot.balanceOf(address(premium)), amount, "escrow balance should equal amount");
    }

    // ─── Standard ERC20 happy path ──────────────────────────────────────────────────────────

    function test_when_standard_erc20_it_should_credit_nominal_amount() public {
        uint256 amount = 123 ether;
        uint256 tokenId = uint256(uint160(address(standardToken)));

        vm.prank(depositor);
        premium.deposit(address(standardToken), recipient, amount);

        assertEq(premium.balanceOf(recipient, tokenId), amount, "credit should equal nominal amount");
        assertEq(standardToken.balanceOf(address(premium)), amount, "escrow balance should equal amount");
    }
}
