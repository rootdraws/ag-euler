// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

/// @title EvcRolloverAdapter_RefundPath
/// @notice Covers the refund/atomic-revert surface of the Exact-binding adapter:
///           A. Premium leg fails mid-`execute` (short ERC-6909 balance) → whole `evc.batch`
///              reverts atomically; adapter + settler + user balances unchanged.
///           B. Rollover leg lands via a direct (non-adapter) settler call; fill deadline passes
///              without premium settlement; keeper invokes `finaliseAsRefunded` and the UW cellar
///              receives the escrowed dstCST.
contract EvcRolloverAdapter_RefundPath is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    address internal subaccount;

    function setUp() public override {
        super.setUp();
        subaccount = AUTHORIZED_CALLER;
    }

    /// @notice Premium leg reverts `InsufficientBalance` inside `execute` → whole batch rolls back.
    function test_refundPath_premiumFailureRevertsWholeBatch() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Force a non-zero premium debit but skip the deposit.
        od.minPremiumPerShare = 1e18;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        sig = _signOrder(order, user, address(exactSettler));

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        // Authorise settler + adapter as ERC-6909 operators but SKIP the deposit.
        vm.prank(subaccount);
        premium.setOperator(address(exactSettler), true);
        vm.prank(subaccount);
        premium.setOperator(address(evcAdapterExact), true);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        uint8 statusBefore = uint8(exactSettler.orderStatus(orderId));
        uint256 adapterSrcBefore = IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact));

        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        assertEq(uint8(exactSettler.orderStatus(orderId)), statusBefore, "order status unchanged");
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact)), adapterSrcBefore, "adapter srcCST unchanged"
        );
        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 allowance zero post-revert"
        );
    }

    /// @notice Post-deadline refund returns escrowed dstCST to the UW cellar, keeper-invoked.
    ///         Rollover lands outside the adapter via a direct settler call so the order reaches
    ///         "rollover landed, premium pending" without the adapter finalising it atomically.
    function test_refundPath_postDeadlineRefund_returnsDstCstToCellar() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Open + rollover-only fill via third party (not through adapter).
        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", thirdParty, ORDER_SIZE));
        require(ok, "srcCst mint failed");
        vm.startPrank(thirdParty);
        IERC20(od.srcCstToken).approve(address(exactSettler), ORDER_SIZE);
        bytes memory rolloverFD =
            bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: thirdParty})));
        exactSettler.fill(orderId, abi.encode(order), rolloverFD);
        vm.stopPrank();

        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), ORDER_SIZE, "dstCST escrow pre-refund");

        vm.warp(order.fillDeadline + 1);
        uint256 cellarBalBefore = IERC20(od.dstCstToken).balanceOf(userCellarAddr);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        exactSettler.finaliseAsRefunded(orderId, order);

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Refunded), "order refunded");
        assertEq(IERC20(od.dstCstToken).balanceOf(userCellarAddr) - cellarBalBefore, ORDER_SIZE, "dstCST to UW cellar");
        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), 0, "escrow drained to cellar");
    }
}
