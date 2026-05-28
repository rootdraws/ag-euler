// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC6909PremiumInvariantHandler} from "test/invariant/ERC6909PremiumInvariantHandler.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";

/// @notice Invariant tests for ERC6909Premium — 3 EINV properties.
contract ERC6909PremiumInvariantTest is Test {
    ERC6909PremiumInvariantHandler internal handler;

    function setUp() public {
        handler = new ERC6909PremiumInvariantHandler();
        targetContract(address(handler));
    }

    /// EINV-1: Balance conservation — sum of balances == deposits - withdraws - settles.
    function invariant_E1_balanceConservation() public view {
        uint256 sumBalances;
        uint256 n = handler.actorCount();
        uint256 tid = handler.tokenId();
        ERC6909Premium prem = handler.premium();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actorAt(i);
            sumBalances += prem.balanceOf(actor, tid);
        }
        uint256 expected = handler.ghost_totalDeposits() - handler.ghost_totalWithdraws() - handler.ghost_totalSettles();
        assertEq(sumBalances, expected);
    }

    /// EINV-2: Dual-auth settle — unauthorized callers always revert.
    function invariant_E2_dualAuthSettle() public view {
        assertEq(
            handler.ghost_unauthorizedSettleAttempts(),
            handler.ghost_unauthorizedSettleReverts(),
            "unauthorized settle succeeded"
        );
    }

    /// EINV-3: No phantom debit — a revert inside settle leaves balances unchanged.
    function invariant_E3_noPhantomDebit() public view {
        uint256 n = handler.actorCount();
        uint256 tid = handler.tokenId();
        ERC6909Premium prem = handler.premium();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actorAt(i);
            uint256 onChain = prem.balanceOf(actor, tid);
            uint256 ghost = handler.ghost_balances(actor);
            assertEq(onChain, ghost);
        }
    }
}
