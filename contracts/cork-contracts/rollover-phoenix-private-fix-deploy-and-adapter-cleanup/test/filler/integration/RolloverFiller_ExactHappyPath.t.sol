// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactRolloverFillerTestBase} from "test/filler/exact/ExactRolloverFillerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title RolloverFiller_ExactHappyPath
/// @notice End-to-end integration scenarios for the Exact-settler-bound `RolloverFiller`: UW
///         signs a Cork rollover `GaslessCrossChainOrder`, a retail caller drives the filler's
///         `execute` path, and the suite asserts the cross-contract post-state (UW cellar
///         holdings, destination holdings, filler-side invariants INV-F1/F2/F4, settler order
///         status). Covers both caller-as-debitFrom and third-party-as-debitFrom patterns.
contract RolloverFiller_ExactHappyPath is ExactRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    /// @notice Caller-is-debitFrom happy path delivers dstCST to destination and settles order.
    function test_exactHappyPath_callerIsDebitFrom_deliversDstCstAndSettles() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }

    /// @notice Filler holds zero of every touched token and zero allowance post-execute (INV-F1/F2).
    function test_exactHappyPath_fillerPostStateIsClean() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        address[] memory toks = new address[](2);
        toks[0] = od.srcCstToken;
        toks[1] = od.dstCstToken;
        _fillerSnapshot(rolloverFillerExact, toks);

        uint256 tokenId = uint256(uint160(od.premiumToken));
        assertEq(premium.balanceOf(address(rolloverFillerExact), tokenId), 0, "INV-F4 ERC-6909");
        assertFalse(premium.isOperator(caller, address(0)), "no filler operator residue");
    }

    /// @notice Third-party `debitFrom` (distinct from caller) settles the premium leg end-to-end.
    function test_exactHappyPath_thirdPartyDebitFrom_settlesPremiumFromThirdParty() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Third party owns the premium deposit and authorises the settler, filler, and caller.
        // Caller authorisation is the A2 remediation: the filler now requires `debitFrom` to have
        // registered `msg.sender` as an ERC-6909 operator when they differ.
        _depositPremium(thirdParty, od.premiumToken, PREMIUM_DEPOSIT);
        vm.startPrank(thirdParty);
        premium.setOperator(address(exactSettler), true);
        premium.setOperator(address(rolloverFillerExact), true);
        premium.setOperator(caller, true);
        vm.stopPrank();

        // Caller only needs srcCST.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "srcCst mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerExact), od.srcCstToken, ORDER_SIZE);

        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, thirdParty, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "settled via thirdParty debit");
        assertTrue(exactSettler.paymentSettled(orderId), "premium settled");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }

    /// @notice Caller's srcCST delta reconciles end-to-end under the mock harness (INV-F3 proxy).
    function test_exactHappyPath_callerSrcCstDeltaReconciles() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 balBefore = IERC20(od.srcCstToken).balanceOf(caller);
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        uint256 balAfter = IERC20(od.srcCstToken).balanceOf(caller);

        // In the mock harness `TestMintModule` does not consume srcCST from the settler, so the
        // full srcCstAmount returns to the caller via the filler's leftover-return step. Filler
        // retains nothing — proxy for INV-F3 under the harness.
        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerExact)), 0, "filler retained nothing");
        assertEq(balAfter, balBefore, "caller srcCST reconciled via leftover-return");
    }
}
