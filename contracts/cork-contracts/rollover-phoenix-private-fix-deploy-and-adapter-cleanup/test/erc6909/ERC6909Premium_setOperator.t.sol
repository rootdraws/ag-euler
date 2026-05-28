// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";

contract ERC6909Premium_setOperator_Test is Test {
    ERC6909Premium internal premium;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");

    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    function setUp() public {
        premium = new ERC6909Premium();
    }

    // ─── when approved is true ──────────────────────────────────────────────────────────────

    function test_when_approved_true_it_should_set_mapping_and_emit() public {
        vm.expectEmit(true, true, false, true, address(premium));
        emit OperatorSet(owner, operator, true);

        vm.prank(owner);
        premium.setOperator(operator, true);

        assertTrue(premium.isOperator(owner, operator), "operator should be approved");
    }

    // ─── when approved is false ─────────────────────────────────────────────────────────────

    function test_when_approved_false_it_should_set_mapping_and_emit() public {
        // Prime the slot to true first so we observe the transition to false.
        vm.prank(owner);
        premium.setOperator(operator, true);

        vm.expectEmit(true, true, false, true, address(premium));
        emit OperatorSet(owner, operator, false);

        vm.prank(owner);
        premium.setOperator(operator, false);

        assertFalse(premium.isOperator(owner, operator), "operator should be revoked");
    }

    // ─── when operator equals msg.sender ────────────────────────────────────────────────────

    function test_when_operator_equals_msgsender_it_should_still_succeed() public {
        vm.expectEmit(true, true, false, true, address(premium));
        emit OperatorSet(owner, owner, true);

        vm.prank(owner);
        premium.setOperator(owner, true);

        assertTrue(premium.isOperator(owner, owner), "self-operator write should persist");
    }

    // ─── when called twice with the same approved value ─────────────────────────────────────

    function test_when_called_twice_same_approved_it_should_be_idempotent_and_still_emit() public {
        vm.prank(owner);
        premium.setOperator(operator, true);
        assertTrue(premium.isOperator(owner, operator), "first write failed");

        // Second identical write — per EIP-6909 the event fires again.
        vm.expectEmit(true, true, false, true, address(premium));
        emit OperatorSet(owner, operator, true);

        vm.prank(owner);
        premium.setOperator(operator, true);

        assertTrue(premium.isOperator(owner, operator), "idempotent write broke state");
    }
}
