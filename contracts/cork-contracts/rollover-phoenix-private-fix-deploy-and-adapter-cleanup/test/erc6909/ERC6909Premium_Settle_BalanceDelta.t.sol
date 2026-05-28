// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";
import {FoTToken} from "test/erc6909/FoTToken.sol";

/// @title ERC6909Premium_Settle_BalanceDelta_Test
/// @notice §39 settle-side regression: `settle` must fail closed with `SettleBalanceMismatch` when
///         the recipient's received balance delta differs from `amount`. Mirrors the deposit-side
///         A4 regression landed in `0cdb91c` on the payout leg. Exercises the FoT path (positive
///         mismatch), the zero-fee degenerate path (no mismatch), and the standard-ERC20 happy
///         path. Balance and ledger state must be unchanged on revert — the debit happens before
///         the external transfer and the whole transaction rolls back.
contract ERC6909Premium_Settle_BalanceDelta_Test is Test {
    ERC6909Premium internal premium;
    FoTToken internal fot;
    MockERC20 internal standardToken;

    address internal debitFrom = makeAddr("debitFrom");
    address internal filler = makeAddr("filler");
    address internal settler = makeAddr("settler");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        premium = new ERC6909Premium();
        fot = new FoTToken();
        standardToken = new MockERC20();

        // Pre-seed the escrow with both tokens so `settle` has balance to debit. The FoT token
        // must be funded with fee == 0 so the escrow holds the full nominal amount — the
        // settle-side fee is re-enabled per-test before the debit.
        fot.setFeeBps(0);
        fot.mint(debitFrom, 1_000 ether);
        standardToken.mint(debitFrom, 1_000 ether);

        vm.startPrank(debitFrom);
        fot.approve(address(premium), type(uint256).max);
        standardToken.approve(address(premium), type(uint256).max);
        premium.deposit(address(fot), debitFrom, 500 ether);
        premium.deposit(address(standardToken), debitFrom, 500 ether);
        premium.setOperator(settler, true);
        premium.setOperator(filler, true);
        vm.stopPrank();
    }

    // ─── FoT token: recipient receives < amount → revert ───────────────────────────────────

    function test_when_token_charges_fee_it_should_revert_SettleBalanceMismatch() public {
        fot.setFeeBps(100); // 1% burn on transfer
        uint256 amount = 100 ether;
        uint256 expectedReceived = amount - (amount * 100) / 10_000; // 99 ether

        uint256 tokenId = uint256(uint160(address(fot)));
        uint256 ledgerBefore = premium.balanceOf(debitFrom, tokenId);
        uint256 escrowBefore = fot.balanceOf(address(premium));
        uint256 recipBefore = fot.balanceOf(recipient);

        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(IERC6909Premium.SettleBalanceMismatch.selector, amount, expectedReceived)
        );
        premium.settle(debitFrom, filler, tokenId, amount, recipient);

        // Full rollback: ledger, escrow, and recipient untouched.
        assertEq(premium.balanceOf(debitFrom, tokenId), ledgerBefore, "debit must not apply on mismatch");
        assertEq(fot.balanceOf(address(premium)), escrowBefore, "escrow must not move on mismatch");
        assertEq(fot.balanceOf(recipient), recipBefore, "recipient must not be credited on mismatch");
    }

    // ─── FoT token at zero fee degrades to standard behaviour ──────────────────────────────

    function test_when_fee_is_zero_FoT_behaves_standard_and_pays_nominal_amount() public {
        fot.setFeeBps(0);
        uint256 amount = 50 ether;
        uint256 tokenId = uint256(uint160(address(fot)));

        vm.prank(settler);
        premium.settle(debitFrom, filler, tokenId, amount, recipient);

        assertEq(fot.balanceOf(recipient), amount, "recipient receives nominal amount");
    }

    // ─── Standard ERC20 happy path ─────────────────────────────────────────────────────────

    function test_when_standard_erc20_it_should_pay_nominal_amount() public {
        uint256 amount = 123 ether;
        uint256 tokenId = uint256(uint160(address(standardToken)));

        vm.prank(settler);
        premium.settle(debitFrom, filler, tokenId, amount, recipient);

        assertEq(standardToken.balanceOf(recipient), amount, "recipient receives nominal amount");
    }
}
