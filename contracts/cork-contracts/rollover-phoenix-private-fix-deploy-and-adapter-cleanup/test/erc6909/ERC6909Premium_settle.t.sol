// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";

/// @dev Reenters ERC6909Premium.settle from inside an ERC-20 transfer callback.
contract SettleReentrant {
    ERC6909Premium public premium;
    MockERC20 public token;
    address public debitFrom;
    address public recipient;
    bool public attack;

    constructor(ERC6909Premium _premium, MockERC20 _token, address _debitFrom, address _recipient) {
        premium = _premium;
        token = _token;
        debitFrom = _debitFrom;
        recipient = _recipient;
    }

    function setAttack(bool v) external {
        attack = v;
    }

    function onTransferCallback() external {
        if (attack) {
            premium.settle(debitFrom, address(this), uint256(uint160(address(token))), 1, recipient);
        }
    }
}

contract ERC6909Premium_settle_Test is Test {
    ERC6909Premium internal premium;
    MockERC20 internal token;

    address internal debitFrom = makeAddr("debitFrom");
    address internal filler = makeAddr("filler");
    address internal settler = makeAddr("settler");
    address internal recipient = makeAddr("recipient");

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    event Settled(
        address indexed debitFrom,
        address indexed premiumFiller,
        uint256 indexed tokenId,
        uint256 amount,
        address recipient
    );

    function setUp() public {
        premium = new ERC6909Premium();
        token = new MockERC20();

        token.mint(debitFrom, 1_000 ether);
        vm.startPrank(debitFrom);
        token.approve(address(premium), type(uint256).max);
        premium.deposit(address(token), debitFrom, 500 ether);
        // Register the settler AND filler as operators. This is the dual-auth happy path.
        premium.setOperator(settler, true);
        premium.setOperator(filler, true);
        vm.stopPrank();
    }

    function _tokenId() internal view returns (uint256) {
        return uint256(uint160(address(token)));
    }

    // ─── when msg.sender is not authorized by debitFrom ─────────────────────────────────────

    function test_when_msgsender_not_authorized_it_should_revert_UnauthorizedSettler() public {
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert(IERC6909Premium.UnauthorizedSettler.selector);
        premium.settle(debitFrom, filler, _tokenId(), 10 ether, recipient);
    }

    // ─── when premiumFiller is not authorized by debitFrom ──────────────────────────────────

    function test_when_premiumFiller_not_authorized_it_should_revert_UnauthorizedPremiumFiller() public {
        address rogueFiller = makeAddr("rogueFiller");
        vm.prank(settler);
        vm.expectRevert(IERC6909Premium.UnauthorizedPremiumFiller.selector);
        premium.settle(debitFrom, rogueFiller, _tokenId(), 10 ether, recipient);
    }

    // ─── when balanceOf(debitFrom, tokenId) is less than amount ─────────────────────────────

    function test_when_insufficient_balance_it_should_revert_InsufficientBalance() public {
        vm.prank(settler);
        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        premium.settle(debitFrom, filler, _tokenId(), 10_000 ether, recipient);
    }

    // ─── when amount is zero ────────────────────────────────────────────────────────────────

    function test_when_amount_is_zero_it_should_not_emit_Transfer() public {
        vm.recordLogs();
        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), 0, recipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != keccak256("Transfer(address,address,address,uint256,uint256)"),
                "Transfer emitted on zero-amount"
            );
        }
    }

    function test_when_amount_is_zero_it_should_noop_successfully() public {
        uint256 credBefore = premium.balanceOf(debitFrom, _tokenId());
        uint256 escrowBefore = token.balanceOf(address(premium));
        uint256 recipBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(premium));
        emit Settled(debitFrom, filler, _tokenId(), 0, recipient);

        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), 0, recipient);

        assertEq(premium.balanceOf(debitFrom, _tokenId()), credBefore, "credit moved on zero-amount");
        assertEq(token.balanceOf(address(premium)), escrowBefore, "escrow moved on zero-amount");
        assertEq(token.balanceOf(recipient), recipBefore, "recipient paid on zero-amount");
    }

    // ─── when all checks pass (4 sub-leaves) ───────────────────────────────────────────────

    function test_when_all_checks_pass_it_should_decrement_balance() public {
        uint256 before = premium.balanceOf(debitFrom, _tokenId());
        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), 100 ether, recipient);
        assertEq(premium.balanceOf(debitFrom, _tokenId()), before - 100 ether, "debit not applied");
    }

    function test_when_all_checks_pass_it_should_safeTransfer_to_recipient() public {
        uint256 escrowBefore = token.balanceOf(address(premium));
        uint256 recipBefore = token.balanceOf(recipient);

        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), 100 ether, recipient);

        assertEq(token.balanceOf(address(premium)), escrowBefore - 100 ether, "escrow not debited");
        assertEq(token.balanceOf(recipient), recipBefore + 100 ether, "recipient not paid");
    }

    function test_when_all_checks_pass_it_should_emit_Transfer() public {
        uint256 amount = 50 ether;

        vm.expectEmit(true, true, true, true, address(premium));
        emit Transfer(settler, debitFrom, address(0), _tokenId(), amount);

        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), amount, recipient);
    }

    function test_when_all_checks_pass_it_should_emit_Settled() public {
        vm.expectEmit(true, true, true, true, address(premium));
        emit Settled(debitFrom, filler, _tokenId(), 100 ether, recipient);

        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), 100 ether, recipient);
    }

    function test_when_all_checks_pass_it_should_complete_atomically() public {
        // Atomicity: a single settle call produces one consistent state snapshot — balance,
        // escrow, and recipient balance all move exactly once by the same amount.
        uint256 amount = 77 ether;
        uint256 credBefore = premium.balanceOf(debitFrom, _tokenId());
        uint256 escrowBefore = token.balanceOf(address(premium));
        uint256 recipBefore = token.balanceOf(recipient);

        vm.prank(settler);
        premium.settle(debitFrom, filler, _tokenId(), amount, recipient);

        assertEq(premium.balanceOf(debitFrom, _tokenId()), credBefore - amount, "credit delta wrong");
        assertEq(token.balanceOf(address(premium)), escrowBefore - amount, "escrow delta wrong");
        assertEq(token.balanceOf(recipient), recipBefore + amount, "recipient delta wrong");
    }

    // ─── when the token reverts in transfer ─────────────────────────────────────────────────

    function test_when_token_reverts_in_transfer_it_should_bubble_and_leave_balance_unchanged() public {
        token.setRevertOnTransfer(true);
        uint256 credBefore = premium.balanceOf(debitFrom, _tokenId());

        vm.prank(settler);
        vm.expectRevert(bytes("MockERC20: transfer reverted"));
        premium.settle(debitFrom, filler, _tokenId(), 100 ether, recipient);

        assertEq(premium.balanceOf(debitFrom, _tokenId()), credBefore, "credit mutated on revert");
    }

    // ─── when the token returns false on transfer ──────────────────────────────────────────

    function test_when_token_returns_false_on_transfer_it_should_revert_SafeERC20FailedOperation() public {
        token.setReturnFalseOnTransfer(true);
        uint256 credBefore = premium.balanceOf(debitFrom, _tokenId());

        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        premium.settle(debitFrom, filler, _tokenId(), 100 ether, recipient);

        assertEq(premium.balanceOf(debitFrom, _tokenId()), credBefore, "credit mutated on failed transfer");
    }

    // ─── when a reentrant settle is attempted ──────────────────────────────────────────────

    function test_when_reentrant_settle_it_should_revert_ReentrancyGuardReentrantCall() public {
        SettleReentrant attacker = new SettleReentrant(premium, token, debitFrom, recipient);

        // Authorize attacker as both settler-side operator and filler. Must also ensure the
        // debitFrom's ERC20 balance has enough to cover the reentry amount.
        vm.startPrank(debitFrom);
        premium.setOperator(address(attacker), true);
        vm.stopPrank();

        // Attacker installs its hook on the token so the call-back fires during safeTransfer.
        token.setTransferHook(address(attacker));
        attacker.setAttack(true);

        vm.prank(address(attacker));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        premium.settle(debitFrom, address(attacker), _tokenId(), 50 ether, recipient);
    }
}
