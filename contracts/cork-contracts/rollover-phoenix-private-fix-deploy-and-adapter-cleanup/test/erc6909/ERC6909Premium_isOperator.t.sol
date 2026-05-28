// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";

contract ERC6909Premium_isOperator_Test is Test {
    ERC6909Premium internal premium;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");

    function setUp() public {
        premium = new ERC6909Premium();
    }

    // ─── when no operator relation has been set ─────────────────────────────────────────────

    function test_when_no_operator_relation_it_should_return_false() public view {
        assertFalse(premium.isOperator(owner, operator), "unset relation should be false");
    }

    // ─── when setOperator was called with approved true ─────────────────────────────────────

    function test_when_setOperator_true_it_should_return_true() public {
        vm.prank(owner);
        premium.setOperator(operator, true);
        assertTrue(premium.isOperator(owner, operator), "true-approval should surface");
    }

    // ─── when setOperator was called with approved true then approved false ─────────────────

    function test_when_setOperator_true_then_false_it_should_return_false() public {
        vm.startPrank(owner);
        premium.setOperator(operator, true);
        premium.setOperator(operator, false);
        vm.stopPrank();
        assertFalse(premium.isOperator(owner, operator), "revocation should surface");
    }
}
