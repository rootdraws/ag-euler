// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title EvcRolloverAdapter_ExactHappyPath
/// @notice End-to-end integration for the Exact-binding `EvcExactFillAdapter` driven through
///         `evc.batch([seed, execute])`. Covers the canonical curator flow RFC 003 §7.3 / §8
///         describes: authorise the adapter as an EVC operator on the curator subaccount,
///         pre-fund the adapter with srcCST, invoke `execute`, assert end-state parity.
/// @dev Mock-env reality (matches the BTT leaves): `TestMintModule` does NOT consume srcCST from
///      the adapter's allowance. Production cellars with a real `RolloverModule` drain the
///      allowance to zero. These integration tests therefore assert the weaker mock-safe invariant
///      (adapter retains seeded srcCST) plus the strict protocol invariants that hold both in
///      mock and production (dstCst == 0, allowance == 0, order == Settled, dstCST at destination).
contract EvcRolloverAdapter_ExactHappyPath is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    address internal subaccount;

    function setUp() public override {
        super.setUp();
        subaccount = AUTHORIZED_CALLER;
    }

    /// @notice Canonical curator happy path: curator authorises adapter, seeds srcCST, invokes
    ///         execute — order settles, destination credited, adapter-side invariants hold.
    function test_exactHappyPath_deliversDstCstAndSettlesOrder() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

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

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled");
        assertTrue(exactSettler.paymentSettled(orderId), "premium leg settled");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }

    /// @notice Post-execute adapter-side invariants hold: INV-F1 (dstCst == 0), INV-F2
    ///         (zero allowance to settler), srcCst retained in the mock env equals the seeded
    ///         amount (not consumed by TestMintModule).
    function test_exactHappyPath_adapterPostStateIsClean() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

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

        // Mock-env carve-out: TestMintModule does not consume the adapter's srcCST approval, so
        // the pre-seeded `ORDER_SIZE` remains on the adapter. Production (real RolloverModule)
        // drains it to 0; see PR 3b for a real-module integration.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE);
        uint256 tokenId = uint256(uint160(od.premiumToken));
        assertEq(premium.balanceOf(address(evcAdapterExact), tokenId), 0, "INV-F4 adapter ERC-6909 == 0");
    }

    /// @notice Third-party `debitFrom` settles premium from a third subaccount while the curator
    ///         subaccount only holds the rollover-side authorisation.
    function test_exactHappyPath_thirdPartyDebitFrom_settlesPremiumFromThirdParty() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Third party funds and authorises premium flow; subaccount holds no premium balance.
        _depositPremium(thirdParty, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(thirdParty);
        premium.setOperator(address(exactSettler), true);
        vm.prank(thirdParty);
        premium.setOperator(address(evcAdapterExact), true);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            thirdParty,
            destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "settled via third-party debit");
        assertTrue(exactSettler.paymentSettled(orderId), "premium settled via thirdParty");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }
}
