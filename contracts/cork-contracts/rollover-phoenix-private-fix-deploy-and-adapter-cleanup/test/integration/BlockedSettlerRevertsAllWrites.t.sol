// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RolloverLifecycleTest} from "test/integration/RolloverLifecycle.t.sol";

import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

import {CellarIntent} from "cellar/ICorkCellar.sol";
import {CorkCellarFactory} from "cellar/CorkCellarFactory.sol";

/// @title BlockedSettlerRevertsAllWrites
/// @notice Integration coverage for the atomic-revert invariant documented on
///         `BaseSettler._forwardToFactory` (closes #64 / Integ M4). The factory's
///         `blockedSettlers` gate fires atomically inside `executeIntentHooks`; the settler has
///         zero awareness. Safety therefore rests on every state-modifying write in the fill
///         path running BEFORE the forward, so the factory's revert unwinds them.
/// @dev Exercises both concrete settlers:
///      - Partial's `_onRolloverLegFill` writes `dstCstToken[orderDigest]` BEFORE the forward,
///        so the invariant has visible pre-forward state to roll back.
///      - Exact's `_onRolloverLegFill` writes its bookkeeping AFTER the forward, so the test
///        instead asserts that no post-forward state leaked — the forward reverts first.
contract BlockedSettlerRevertsAllWritesTest is RolloverLifecycleTest {
    // ═══════════════════════════════════════════════════════════════
    //  Partial — pre-forward write (`dstCstToken[orderDigest]`) rolls back
    // ═══════════════════════════════════════════════════════════════

    function test_blockedSettler_partial_revertsAllPriorWrites() public {
        uint256 S = 1000e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, S, false);

        _openPartial(order);

        address dstBefore = partialSettler.dstCstToken(orderDigest);
        uint256 partBefore = partialSettler.participantCount(orderDigest);
        uint256 cumBefore = partialSettler.cumulativeFilled(orderId);
        uint256 escrowBalBefore = IERC20(od.dstCstToken).balanceOf(address(partialSettler));

        // Block the settler AFTER open. Open touches the factory (`cellarOf` lookup) but does
        // not route through `executeIntentHooks`, so the block only fires on the next fill.
        vm.prank(bravo);
        factory.blockSettler(address(partialSettler));

        bytes memory fd = _partialRolloverFD(filler1, od, intent);
        vm.prank(filler1);
        vm.expectRevert(CorkCellarFactory.CorkCellarFactory__SettlerBlocked.selector);
        partialSettler.fill(orderId, abi.encode(order), fd);

        // Every write in `_onRolloverLegFill` — pre- AND post-forward — must be unreachable.
        assertEq(partialSettler.dstCstToken(orderDigest), dstBefore, "dstCstToken[digest] persisted despite revert");
        assertEq(partialSettler.participantCount(orderDigest), partBefore, "participantCount persisted");
        assertEq(partialSettler.cumulativeFilled(orderId), cumBefore, "cumulativeFilled persisted");

        IPartialFillSettler.FillerRollover memory record = partialSettler.fillerRollovers(orderDigest, filler1);
        assertEq(record.srcCstProvided, 0, "FillerRollover.srcCstProvided written despite revert");
        assertEq(record.dstCstProduced, 0, "FillerRollover.dstCstProduced written despite revert");
        assertEq(record.destination, address(0), "FillerRollover.destination written despite revert");
        assertFalse(record.premiumSettled, "FillerRollover.premiumSettled written despite revert");
        assertFalse(record.finalised, "FillerRollover.finalised written despite revert");
        assertFalse(record.refunded, "FillerRollover.refunded written despite revert");

        assertEq(
            IERC20(od.dstCstToken).balanceOf(address(partialSettler)),
            escrowBalBefore,
            "settler balance drifted despite revert"
        );
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Opened), "orderStatus drifted");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Exact — post-forward bookkeeping never reached
    // ═══════════════════════════════════════════════════════════════

    function test_blockedSettler_exact_revertsAllPriorWrites() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes32 orderId,) =
            _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        _openExact(order);

        address dstBefore = exactSettler.dstCstToken(orderId);
        bool paidBefore = exactSettler.paymentSettled(orderId);
        uint256 escrowBalBefore = IERC20(od.dstCstToken).balanceOf(address(exactSettler));

        vm.prank(bravo);
        factory.blockSettler(address(exactSettler));

        bytes memory fd = _rolloverFD(filler1);
        vm.prank(filler1);
        vm.expectRevert(CorkCellarFactory.CorkCellarFactory__SettlerBlocked.selector);
        exactSettler.fill(orderId, abi.encode(order), fd);

        assertEq(exactSettler.dstCstToken(orderId), dstBefore, "Exact.dstCstToken[id] persisted despite revert");
        assertEq(exactSettler.paymentSettled(orderId), paidBefore, "Exact.paymentSettled persisted despite revert");
        assertEq(
            IERC20(od.dstCstToken).balanceOf(address(exactSettler)),
            escrowBalBefore,
            "Exact settler balance drifted despite revert"
        );
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Opened), "Exact orderStatus drifted");
    }
}
