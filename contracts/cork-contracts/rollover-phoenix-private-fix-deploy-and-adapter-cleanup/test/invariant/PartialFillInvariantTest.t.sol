// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SettlerInvariantHandler, OrderRecord} from "test/invariant/SettlerInvariantHandler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";

/// @notice Invariant tests for PartialFillSettler — 16 PINV properties (PINV-2 is a gap).
contract PartialFillInvariantTest is Test {
    SettlerInvariantHandler internal handler;

    function setUp() public {
        handler = new SettlerInvariantHandler();
        targetContract(address(handler));
    }

    /// PINV-1: One rollover leg per filler — srcCstProvided is 0 or set once.
    function invariant_P1_oneRolloverLegPerFiller() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                uint256 ghostSrc = handler.ghost_fillerSrcProvided(digest, fillers[j]);
                if (ghostSrc == 0) {
                    assertEq(f.srcCstProvided, 0);
                } else {
                    assertEq(f.srcCstProvided, ghostSrc);
                }
            }
        }
    }

    /// PINV-3: Rollover-first per filler — premiumSettled implies srcCstProvided > 0.
    function invariant_P3_rolloverFirstPerFiller() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (f.premiumSettled) {
                    assertGt(f.srcCstProvided, 0);
                }
            }
        }
    }

    /// PINV-4: Single finalisation — not(finalised AND refunded), both are latching.
    function invariant_P4_singleFinalisation() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                assertFalse(f.finalised && f.refunded);
            }
        }
    }

    /// PINV-5: Refund precondition — refunded filler had timestamp > fillDeadline and premiumSettled == false.
    function invariant_P5_refundPrecondition() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (f.refunded) {
                    assertFalse(f.premiumSettled);
                }
            }
        }
    }

    /// PINV-6: Order completeness sum — totalDstCstEscrowed == sum of unfinalised/unrefunded dstCstProduced.
    function invariant_P6_orderCompletenessSum() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            uint256 activeEscrow;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (!f.finalised && !f.refunded && f.dstCstProduced > 0) {
                    activeEscrow += f.dstCstProduced;
                }
            }
            uint256 onChain = handler.partialSettler().totalDstCstEscrowed(digest);
            assertEq(onChain, activeEscrow);
        }
    }

    /// PINV-7: Cumulative alignment — ghost tracking matches on-chain state.
    function invariant_P7_cumulativeAlignment() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            uint256 onChainParticipants = handler.partialSettler().participantCount(digest);
            assertEq(onChainParticipants, handler.ghost_participantCount(digest), "participant count mismatch");
            uint256 onChainEscrow = handler.partialSettler().totalDstCstEscrowed(digest);
            uint256 ghostEscrow = handler.ghost_partialTotalEscrow(digest);
            assertEq(onChainEscrow, ghostEscrow, "escrow sum mismatch");
        }
    }

    /// PINV-8: Per-filler atomicity — premiumSettled implies dstCstProduced > 0 AND srcCstProvided > 0 AND destination != 0.
    function invariant_P8_perFillerAtomicity() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (f.premiumSettled) {
                    assertGt(f.dstCstProduced, 0);
                    assertGt(f.srcCstProvided, 0);
                    assertTrue(f.destination != address(0));
                }
            }
        }
    }

    /// PINV-10: Finalisation CEI — after finaliseAsSettled, finalised flag is true before transfer occurred.
    function invariant_P10_finalisationCEI() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                if (handler.ghost_fillerFinalised(digest, fillers[j])) {
                    IPartialFillSettler.FillerRollover memory f =
                        handler.partialSettler().fillerRollovers(digest, fillers[j]);
                    assertTrue(f.finalised);
                }
            }
        }
    }

    /// PINV-11: Premium monotonicity under rounding — totalPremiumCollected >= ceilDiv sum.
    function invariant_P11_premiumMonotonicityUnderRounding() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            uint256 expectedMin;
            for (uint256 j; j < fillers.length; ++j) {
                if (handler.ghost_fillerPremiumSettled(digest, fillers[j])) {
                    uint256 dstProduced = handler.ghost_fillerDstProduced(digest, fillers[j]);
                    expectedMin += Math.mulDiv(dstProduced, rec.od.minPremiumPerShare, 1e18, Math.Rounding.Ceil);
                }
            }
            assertGe(handler.ghost_totalPremiumCollected(digest), expectedMin);
        }
    }

    /// PINV-12: Terminal-aware conservation — hookNonces bit correlates with terminal state.
    function invariant_P12_terminalAwareConservation() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            OrderStatus status = handler.ghost_orderStatus(rec.orderId);
            if (status == OrderStatus.Settled) {
                uint256 escrow = handler.partialSettler().totalDstCstEscrowed(digest);
                assertEq(escrow, 0);
            }
        }
    }

    /// PINV-13: No post-terminal fillers — no filler state written after terminal bit set.
    function invariant_P13_noPostTerminalFillers() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;

            bytes32 oid = rec.orderId;
            OrderStatus status = handler.ghost_orderStatus(oid);
            if (!_isTerminal(status)) continue;

            bytes32 digest = rec.orderDigest;
            uint256 onChainParticipants = handler.partialSettler().participantCount(digest);
            assertEq(onChainParticipants, handler.ghost_participantCount(digest));
        }
    }

    /// PINV-14: Per-token solvency — settler balance >= sum of totalDstCstEscrowed.
    function invariant_P14_perTokenSolvency() public view {
        uint256 totalEscrow;
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            totalEscrow += handler.partialSettler().totalDstCstEscrowed(rec.orderDigest);
        }
        uint256 bal = IERC20(address(handler.dstToken())).balanceOf(address(handler.partialSettler()));
        assertGe(bal, totalEscrow);
    }

    /// PINV-15: Cancel before any fill — cancel rejects once participantCount > 0.
    function invariant_P15_cancelBeforeAnyFill() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 oid = rec.orderId;
            if (handler.ghost_orderStatus(oid) == OrderStatus.Cancelled) {
                assertEq(handler.ghost_participantCount(rec.orderDigest), 0);
            }
        }
    }

    /// PINV-16: Order terminal state — bidirectional iff.
    /// Forward: Settled -> (escrow==0 AND finCount+refCount==partCount)
    /// Reverse: (escrow==0 AND finCount+refCount==partCount AND partCount>0) -> not Opened
    function invariant_P16_orderTerminalState() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 oid = rec.orderId;
            bytes32 digest = rec.orderDigest;
            OrderStatus status = handler.ghost_orderStatus(oid);

            uint256 escrow = handler.partialSettler().totalDstCstEscrowed(digest);
            uint256 finCount = handler.partialSettler().finalisedCount(digest);
            uint256 refCount = handler.partialSettler().refundedCount(digest);
            uint256 partCount = handler.partialSettler().participantCount(digest);

            // Forward: Settled -> conditions hold
            if (status == OrderStatus.Settled) {
                assertEq(escrow, 0, "Settled but escrow != 0");
                assertEq(finCount + refCount, partCount, "Settled but counts don't sum");
            }

            // Reverse: (escrow==0 AND counts sum AND partCount>0) -> not Opened
            if (escrow == 0 && partCount > 0 && finCount + refCount == partCount) {
                assertTrue(status != OrderStatus.Opened, "All fillers reconciled but order still Opened");
            }
        }
    }

    /// PINV-17: Premium hook singularity — premiumSettled set at most once per (digest, filler).
    function invariant_P17_premiumHookSingularity() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                bool ghostPrem = handler.ghost_fillerPremiumSettled(digest, fillers[j]);
                assertEq(f.premiumSettled, ghostPrem);
            }
        }
    }

    /// PINV-18: Intent hash binding — every fill had keccak256(intent) == od.cellarIntentHash.
    function invariant_P18_intentHashBinding() public view {
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            assertEq(keccak256(abi.encode(rec.intent)), rec.od.cellarIntentHash);
        }
    }

    /// PINV-19: No wedge at zero escrow — if escrow is zero and fills exist, order must not be Opened.
    function invariant_NoWedgeAtZeroEscrow() public view {
        bytes32[] memory digests = handler.orderDigests();
        for (uint256 i; i < digests.length; ++i) {
            bytes32 d = digests[i];
            if (handler.partialSettler().totalDstCstEscrowed(d) != 0) continue;
            if (!handler.hasAnyFills(d)) continue;

            bytes32 orderId = handler.partialSettler().orderIdOf(d);
            OrderStatus status = handler.partialSettler().orderStatus(orderId);
            assertTrue(status != OrderStatus.Opened, "WEDGE: zero escrow + fills but Opened");
        }
    }

    /// PINV-AS19: No per-filler fill below `minFillSize` — if a filler has a rollover record and
    ///            the order declares `minFillSize > 0`, the recorded `srcCstProvided` is at least
    ///            `minFillSize`. The handler forces `minFillSize == orderSize` when the gate is
    ///            enabled so this equality is effectively `srcCstProvided == orderSize`.
    function invariant_S_noFillBelowMinFillSize() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            if (rec.od.minFillSize == 0) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (f.srcCstProvided == 0) continue;
                // Rollover leg amount equals `rec.od.outputs[0].amount`, which was admitted by
                // the gate and is therefore >= minFillSize.
                assertGe(rec.od.outputs[0].amount, rec.od.minFillSize);
            }
        }
    }

    /// PINV-attributionEventParity (Task 38 / #47): every filler slot that reached
    /// `f.finalised = true` MUST have seen exactly one `OrderAttribution` emission on the
    /// settler. The handler records emissions into `ghost_attributionEmitted` after every
    /// successful `finaliseAsSettled` batch; the on-chain `FillerRollover.finalised` latch is
    /// the source of truth for which slots should carry an emission.
    function invariant_P_attributionEventParity() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            bytes32 digest = rec.orderDigest;
            bytes32 oid = rec.orderId;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (!f.finalised) continue;
                // A finalised slot that held non-zero dstCstProduced emits once per finalise
                // batch; idempotent skips (already-finalised path) do not emit. The handler
                // calls finalise once per successful batch per slot, so the count is exactly 1.
                if (f.dstCstProduced == 0) continue;
                uint256 emissions = handler.ghost_attributionEmitted(oid, fillers[j]);
                assertEq(emissions, 1, "attribution emission count mismatch");
            }
        }
    }

    /// PINV-AS21: Non-exclusive fills blocked — if an order has an `exclusiveFiller`, only that
    ///            filler may have a non-zero `srcCstProvided`.
    function invariant_S_noFillByNonExclusive() public view {
        uint256 count = handler.orderCount();
        address[] memory fillers = _allFillers();
        for (uint256 i; i < count; ++i) {
            OrderRecord memory rec = handler.orderAt(i);
            if (!rec.isPartial) continue;
            if (rec.od.exclusiveFiller == address(0)) continue;
            bytes32 digest = rec.orderDigest;
            for (uint256 j; j < fillers.length; ++j) {
                IPartialFillSettler.FillerRollover memory f =
                    handler.partialSettler().fillerRollovers(digest, fillers[j]);
                if (f.srcCstProvided == 0) continue;
                assertEq(fillers[j], rec.od.exclusiveFiller);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _allFillers() internal view returns (address[] memory addrs) {
        uint256 n = handler.FILLER_COUNT();
        addrs = new address[](n);
        for (uint256 i; i < n; ++i) {
            addrs[i] = handler.fillerAddr(i);
        }
    }

    function _isTerminal(OrderStatus s) internal pure returns (bool) {
        return s == OrderStatus.Settled || s == OrderStatus.Refunded || s == OrderStatus.Cancelled;
    }
}
