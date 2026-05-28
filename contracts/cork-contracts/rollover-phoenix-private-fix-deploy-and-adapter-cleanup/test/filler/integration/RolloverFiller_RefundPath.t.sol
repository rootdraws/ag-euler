// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactRolloverFillerTestBase} from "test/filler/exact/ExactRolloverFillerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {OrderData, RolloverFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";

/// @title RolloverFiller_RefundPath
/// @notice Integration coverage for partial-execute failure modes and the post-deadline refund
///         path. Two scenarios:
///           A. Premium leg fails mid-`execute` (ERC-6909 balance short) — the whole transaction
///              reverts atomically; filler, settler, and ERC-6909 post-state equal the pre-state.
///           B. A rollover leg lands via an external direct-settler call; the `debitFrom` never
///              settles the premium and the fill deadline passes. A keeper (not the filler
///              contract) invokes `finaliseAsRefunded` and the UW cellar receives the escrowed
///              dstCST back. Exact-settler variant — the Partial settler's refund path is
///              identical in shape (`finaliseAsRefunded(digest, order, fillers[])`).
contract RolloverFiller_RefundPath is ExactRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    /// @notice Premium leg failure inside `execute` reverts the whole transaction atomically.
    function test_refundPath_premiumFailure_revertsAtomically() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Force a non-zero premium debit by setting `minPremiumPerShare` — but skip the deposit.
        // The settler's premium leg reaches `ERC6909Premium.settle`, which reverts with
        // InsufficientBalance when `debitFrom`'s ERC-6909 balance is zero.
        od.minPremiumPerShare = 1e18;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        sig = _signOrder(order, user, address(exactSettler));

        // srcCST prepared + caller authorizes settler + filler, but SKIP premium deposit.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerExact), od.srcCstToken, ORDER_SIZE);
        vm.startPrank(caller);
        premium.setOperator(address(exactSettler), true);
        premium.setOperator(address(rolloverFillerExact), true);
        vm.stopPrank();

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        uint8 statusBefore = uint8(exactSettler.orderStatus(orderId));
        uint256 fillerBalBefore = IERC20(od.srcCstToken).balanceOf(address(rolloverFillerExact));
        uint256 callerBalBefore = IERC20(od.srcCstToken).balanceOf(caller);

        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        // Atomic parity: no state change on filler, settler, or caller balances.
        assertEq(uint8(exactSettler.orderStatus(orderId)), statusBefore, "order status unchanged");
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(rolloverFillerExact)), fillerBalBefore, "filler srcCST unchanged"
        );
        assertEq(IERC20(od.srcCstToken).balanceOf(caller), callerBalBefore, "caller srcCST unchanged");
        assertEq(
            IERC20(od.srcCstToken).allowance(address(rolloverFillerExact), address(exactSettler)),
            0,
            "INV-F2 allowance zero post-revert"
        );
    }

    /// @notice Post-deadline refund returns escrowed dstCST to the UW cellar (keeper-invoked).
    function test_refundPath_postDeadlineRefund_returnsDstCstToCellar() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        // Rollover-only fill via a third party (NOT through RolloverFiller) so the order reaches
        // the "rollover landed, premium pending" state.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", thirdParty, ORDER_SIZE));
        require(ok, "mint failed");
        vm.startPrank(thirdParty);
        IERC20(od.srcCstToken).approve(address(exactSettler), ORDER_SIZE);
        bytes memory rolloverFD =
            bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: thirdParty})));
        exactSettler.fill(orderId, abi.encode(order), rolloverFD);
        vm.stopPrank();

        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), ORDER_SIZE, "escrow holds dstCST pre-refund");

        // Deadline passes and a keeper (arbitrary address) calls finaliseAsRefunded. UW cellar
        // receives back the dstCST the settler was escrowing.
        vm.warp(order.fillDeadline + 1);
        uint256 cellarBalBefore = IERC20(od.dstCstToken).balanceOf(userCellarAddr);
        uint256 thirdPartySrcBefore = IERC20(od.srcCstToken).balanceOf(thirdParty);
        uint256 thirdPartyDstBefore = IERC20(od.dstCstToken).balanceOf(thirdParty);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        exactSettler.finaliseAsRefunded(orderId, order);

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Refunded), "order refunded");
        assertEq(IERC20(od.dstCstToken).balanceOf(userCellarAddr) - cellarBalBefore, ORDER_SIZE, "dstCST to UW cellar");

        // Negative-space guards (P26-G1 / P26-T2). The refund path is a one-way sweep of escrowed
        // dstCST back to the UW cellar and nothing else. Asserted here:
        //   (a) the declared rollover-leg `destination` (thirdParty, in this test) never gains
        //       dstCST — the refund credits the cellar, not the filler;
        //   (b) thirdParty's srcCST balance is unchanged across the refund call — the refund path
        //       touches only dstCST, srcCST restitution (mock-harness-only) happened at rollover
        //       time inside `_onRolloverLegFill` and is independent of the refund;
        //   (c) the settler's dstCST escrow is fully drained to the cellar, not split or retained.
        assertEq(
            IERC20(od.dstCstToken).balanceOf(thirdParty), thirdPartyDstBefore, "destination never credited on refund"
        );
        assertEq(IERC20(od.dstCstToken).balanceOf(thirdParty), 0, "destination dstCST must stay at zero");
        assertEq(
            IERC20(od.srcCstToken).balanceOf(thirdParty), thirdPartySrcBefore, "third-party srcCST unchanged by refund"
        );
        assertEq(
            IERC20(od.dstCstToken).balanceOf(address(exactSettler)), 0, "escrow fully drained to cellar, not split"
        );
    }

    /// @notice Post-deadline refund reverts if the order's premium already settled (OrderComplete).
    function test_refundPath_premiumAlreadySettled_refundReverts() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Full happy-path execute — order settles atomically, `paymentSettled == true`.
        _executeRollover(rolloverFillerExact, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertTrue(exactSettler.paymentSettled(orderId), "premium settled");

        vm.warp(order.fillDeadline + 1);
        // Order already Settled → `finaliseAsRefunded` hits the `InvalidOrderStatus` guard at
        // ExactFillSettler.sol:131 (status != Opened). Tightened from bare `vm.expectRevert()`
        // so an OOG or unrelated revert no longer masks a regression here.
        vm.expectRevert(abi.encodeWithSignature("InvalidOrderStatus()"));
        exactSettler.finaliseAsRefunded(orderId, order);
    }
}
