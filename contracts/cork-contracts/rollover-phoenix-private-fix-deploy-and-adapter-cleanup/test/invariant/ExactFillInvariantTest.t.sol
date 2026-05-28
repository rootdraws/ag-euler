// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SettlerInvariantHandler, OrderRecord} from "test/invariant/SettlerInvariantHandler.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";

/// @notice Invariant tests for ExactFillSettler — 10 SINV properties.
contract ExactFillInvariantTest is Test {
    SettlerInvariantHandler internal handler;

    function setUp() public {
        handler = new SettlerInvariantHandler();
        targetContract(address(handler));
    }

    /// SINV-1: Escrow accounting — for non-terminal orders, fill record dstCstProduced == ghost escrow.
    function invariant_S1_escrowAccounting() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            OrderStatus status = handler.ghost_orderStatus(oid);
            if (_isTerminal(status)) continue;

            bytes32 roh = LibSettlerHashing.computeOutputHash(rec.od.outputs[0]);
            (,, uint256 dstCstProduced,) = handler.exactSettler().fillRecords(oid, roh);

            assertEq(uint256(dstCstProduced), handler.ghost_exactDstEscrow(oid));
        }
    }

    /// SINV-2: Per-token solvency — settler balance >= sum of unsettled escrow.
    function invariant_S2_perTokenSolvency() public view {
        uint256 totalUnsettled;
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;
            totalUnsettled += handler.ghost_exactDstEscrow(rec.orderId);
        }
        uint256 bal = IERC20(address(handler.dstToken())).balanceOf(address(handler.exactSettler()));
        assertGe(bal, totalUnsettled);
    }

    /// SINV-3: Fill-once-per-output — rollover filledAt is 0 or set exactly once.
    function invariant_S3_fillOncePerOutput() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            bytes32 roh = LibSettlerHashing.computeOutputHash(rec.od.outputs[0]);
            (,,, uint64 filledAt) = handler.exactSettler().fillRecords(oid, roh);

            if (handler.ghost_rolloverFilled(oid)) {
                assertGt(filledAt, 0);
            } else {
                assertEq(filledAt, 0);
            }
        }
    }

    /// SINV-3b: Rollover-first ordering — premium fill requires rollover fill.
    function invariant_S3_rolloverFirstOrdering() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            if (handler.ghost_premiumFilled(oid)) {
                assertTrue(handler.ghost_rolloverFilled(oid));
            }
        }
    }

    /// SINV-4: Fill before deadline — no fill has filledAt > fillDeadline.
    function invariant_S4_fillBeforeDeadline() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            bytes32 roh = LibSettlerHashing.computeOutputHash(rec.od.outputs[0]);
            (,,, uint64 filledAt) = handler.exactSettler().fillRecords(oid, roh);

            if (filledAt != 0) {
                assertLe(uint256(filledAt), handler.ghost_fillDeadline(oid));
            }
        }
    }

    /// SINV-5: Refund after deadline — no refunded order had timestamp <= fillDeadline.
    function invariant_S5_refundAfterDeadline() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            if (handler.ghost_orderStatus(oid) == OrderStatus.Refunded) {
                assertGt(handler.ghost_refundedTimestamp(oid), handler.ghost_fillDeadline(oid));
            }
        }
    }

    /// SINV-6: Cancel pre-fill — no cancelled order has a fill record.
    function invariant_S6_cancelPreFill() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            if (handler.ghost_orderStatus(oid) == OrderStatus.Cancelled) {
                assertFalse(handler.ghost_rolloverFilled(oid));
                assertFalse(handler.ghost_premiumFilled(oid));
            }
        }
    }

    /// SINV-7: Status monotone — transitions are forward-only.
    function invariant_S7_statusMonotone() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            OrderStatus current = handler.ghost_orderStatus(oid);
            OrderStatus prev = handler.ghost_prevStatus(oid);

            if (current == OrderStatus.None) {
                assertEq(uint8(prev), uint8(OrderStatus.None));
            }
            if (current == OrderStatus.Opened) {
                assertTrue(prev == OrderStatus.None || prev == OrderStatus.Opened);
            }
            if (_isTerminal(current)) {
                assertTrue(prev == OrderStatus.Opened || prev == OrderStatus.None);
            }
        }
    }

    /// SINV-11: Fill record integrity — every Settled order has both fills.
    function invariant_S11_fillRecordIntegrity() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            if (handler.ghost_orderStatus(oid) == OrderStatus.Settled) {
                assertTrue(handler.ghost_rolloverFilled(oid));
                assertTrue(handler.ghost_premiumFilled(oid));
            }
        }
    }

    /// SINV-15: Token distinctness — srcCstToken != premiumToken for every opened order.
    function invariant_S15_tokenDistinctness() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;
            assertNotEq(rec.od.srcCstToken, rec.od.premiumToken);
        }
    }

    /// SINV-AS19: No rollover fill below `minFillSize` — if a fill was recorded, the stored leg
    ///            amount must be at least the order's declared `minFillSize`. Vacuous when
    ///            `minFillSize == 0`.
    function invariant_S_noFillBelowMinFillSize() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;
            if (rec.od.minFillSize == 0) continue;
            if (!handler.ghost_rolloverFilled(rec.orderId)) continue;
            // Exact path: output.amount must equal orderSize (partial fills rejected); so if a
            // rollover fill exists the leg amount is orderSize, which is >= minFillSize.
            assertGe(rec.od.outputs[0].amount, rec.od.minFillSize);
        }
    }

    /// SINV-attributionEventParity (Task 38 / #47): every Settled Exact order MUST have emitted
    /// exactly one `OrderAttribution` event keyed on `(orderId, rolloverFiller)`. On Exact the
    /// single-participant rollover filler is the attribution subject; the handler records
    /// emissions after each successful `finaliseAsSettled` call.
    function invariant_S_attributionEventParity() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;
            bytes32 oid = rec.orderId;
            if (handler.ghost_orderStatus(oid) != OrderStatus.Settled) continue;
            // A Settled Exact order with non-zero dstCstProduced emits attribution once; the
            // single rollover filler is the attribution subject (same as `fillRecords[oid][roh].filler`).
            bytes32 roh = LibSettlerHashing.computeOutputHash(rec.od.outputs[0]);
            (address rolloverFiller,, uint256 dstProduced,) = handler.exactSettler().fillRecords(oid, roh);
            if (dstProduced == 0) continue;
            uint256 emissions = handler.ghost_attributionEmitted(oid, rolloverFiller);
            assertEq(emissions, 1, "attribution emission count mismatch");
        }
    }

    /// SINV-AS21: Non-exclusive fills blocked — if an order has a rollover fill and an exclusive
    ///            filler is set, the filler on record must match `exclusiveFiller`.
    function invariant_S_noFillByNonExclusive() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (rec.isPartial) continue;
            if (rec.od.exclusiveFiller == address(0)) continue;
            if (!handler.ghost_rolloverFilled(rec.orderId)) continue;

            bytes32 roh = LibSettlerHashing.computeOutputHash(rec.od.outputs[0]);
            (address fillerAddr,,,) = handler.exactSettler().fillRecords(rec.orderId, roh);
            assertEq(fillerAddr, rec.od.exclusiveFiller);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _isTerminal(OrderStatus s) internal pure returns (bool) {
        return s == OrderStatus.Settled || s == OrderStatus.Refunded || s == OrderStatus.Cancelled;
    }
}
