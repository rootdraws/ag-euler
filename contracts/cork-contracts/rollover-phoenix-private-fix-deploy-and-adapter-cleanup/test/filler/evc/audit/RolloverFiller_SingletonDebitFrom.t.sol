// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PartialRolloverFillerTestBase} from "test/filler/partial/PartialRolloverFillerTestBase.sol";
import {IPartialRolloverFiller} from "contracts/interfaces/IPartialRolloverFiller.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";

/// @title RolloverFiller_SingletonDebitFrom
/// @notice Audit-cycle coverage for the caller-side `debitFrom` authorization guard (pashov A2 /
///         Task 3). The canonical `PartialRolloverFiller` is a public singleton — any caller can invoke
///         `execute`. Without the caller-side check a caller could name an arbitrary `debitFrom`
///         that authorized the filler itself, draining the victim's ERC-6909 premium balance into
///         the caller's fill. The filler now requires `debitFrom` to have registered `msg.sender`
///         as an ERC-6909 operator whenever `debitFrom != msg.sender`.
/// @dev Located under `test/filler/evc/audit/` to group Pashov audit-cycle leaves alongside the
///      B1 suite. Drives the Partial-binding singleton because the vuln surfaces identically on
///      both bindings — covering one is sufficient for the selector + state assertions.
contract RolloverFiller_SingletonDebitFrom is PartialRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    address internal victim;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. Attacker names victim as debitFrom without operator authorization
    //     → revert DebitFromNotAuthorizedByCaller (A2 primary)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Victim has deposited premium and authorized the filler + settler as ERC-6909
    ///         operators, but has NOT authorized the attacker. The attacker invokes `execute`
    ///         naming `debitFrom = victim`. Without the A2 guard the settler-side dual-auth would
    ///         still pass (the filler is an authorized operator, and `msg.sender` is the filler
    ///         contract from the settler's perspective), letting the attacker drain the victim's
    ///         premium balance. The caller-side check rejects before any settler call.
    function test_attacker_withVictimDebitFrom_reverts_DebitFromNotAuthorizedByCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Victim preconditions: deposit premium, authorize settler + filler (mirrors the public
        // UX a victim would follow to stake premium behind the singleton).
        _depositPremium(victim, od.premiumToken, PREMIUM_DEPOSIT);
        vm.startPrank(victim);
        premium.setOperator(address(partialSettler), true);
        premium.setOperator(address(rolloverFillerPartial), true);
        vm.stopPrank();

        // Attacker preconditions: srcCST only. No premium deposit, not authorized by victim.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", attacker, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(attacker, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(
            abi.encodeWithSelector(IPartialRolloverFiller.DebitFromNotAuthorizedByCaller.selector, victim, attacker)
        );
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, victim, destination, attacker);

        // State is clean: victim's premium balance is unchanged, adapter retains nothing.
        uint256 tokenId = uint256(uint160(od.premiumToken));
        assertEq(premium.balanceOf(victim, tokenId), PREMIUM_DEPOSIT, "victim premium untouched");
        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "filler srcCST zero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. Caller uses its own debitFrom — happy path
    // ═══════════════════════════════════════════════════════════════

    /// @notice Attacker owns the premium deposit and calls `execute` with `debitFrom = attacker`.
    ///         The caller-side guard short-circuits (`debitFrom == msg.sender`) and the call
    ///         settles end-to-end — the premium is drawn from the attacker's own balance, not the
    ///         victim's.
    function test_attacker_withSelfDebitFrom_settlesFromOwnBalance() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Victim stakes premium (as in test #1) but is a bystander here — we only observe that
        // their balance is never touched.
        _depositPremium(victim, od.premiumToken, PREMIUM_DEPOSIT);
        vm.startPrank(victim);
        premium.setOperator(address(partialSettler), true);
        premium.setOperator(address(rolloverFillerPartial), true);
        vm.stopPrank();

        // Attacker is the caller and the premium source — canonical happy-path shape.
        _preconditions(attacker, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 tokenId = uint256(uint160(od.premiumToken));
        uint256 victimBefore = premium.balanceOf(victim, tokenId);

        _executeRollover(
            rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, attacker, destination, attacker
        );

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        // The guard did NOT fire (debitFrom == msg.sender short-circuits) and the call settled. In
        // the harness `minPremiumPerShare = 0` so no premium tokens move, but the settler still
        // flips `premiumSettled = true` on the filler's bookkeeping row. Victim balance is observed
        // as untouched to prove isolation from the attacker-driven flow.
        assertTrue(fr.premiumSettled, "premium leg settled under attacker's own debitFrom");
        assertEq(premium.balanceOf(victim, tokenId), victimBefore, "victim balance untouched");
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Victim authorizes attacker as ERC-6909 operator — attacker call passes
    // ═══════════════════════════════════════════════════════════════

    /// @notice Victim explicitly grants the attacker ERC-6909 operator status over the premium
    ///         ledger. The caller-side guard treats that as consent and lets the attacker drive
    ///         the premium leg against the victim's balance — matching the cooperative flow
    ///         (principal / agent) the guard is designed to allow.
    function test_victimAuthorizesAttacker_asOperator_executeSettles() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Victim deposits premium and authorizes the settler, the filler, AND the attacker as
        // operators. Attacker authorization is what unlocks cross-caller `debitFrom`.
        _depositPremium(victim, od.premiumToken, PREMIUM_DEPOSIT);
        vm.startPrank(victim);
        premium.setOperator(address(partialSettler), true);
        premium.setOperator(address(rolloverFillerPartial), true);
        premium.setOperator(attacker, true);
        vm.stopPrank();

        // Attacker provides srcCST and drives the call.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", attacker, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(attacker, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);

        uint256 tokenId = uint256(uint160(od.premiumToken));
        uint256 victimBefore = premium.balanceOf(victim, tokenId);

        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, victim, destination, attacker);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        // Guard passed via `isOperator(victim, attacker) == true`. The harness uses
        // `minPremiumPerShare = 0`, so the settler advances `premiumSettled` without moving
        // tokens — the premium-leg execution itself is the proof the cooperative path works.
        assertTrue(fr.premiumSettled, "consented cross-caller premium leg settled");
        assertEq(premium.balanceOf(victim, tokenId), victimBefore, "victim ERC-6909 unchanged at zero-premium rate");
    }
}
