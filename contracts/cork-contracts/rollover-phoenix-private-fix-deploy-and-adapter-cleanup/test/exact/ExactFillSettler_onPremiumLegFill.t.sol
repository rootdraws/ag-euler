// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {StateDivergence} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

/// @title ExactFillSettler_onPremiumLegFill
/// @notice BTT coverage for the AS-10 / #58 try/catch around the phase-1 cellar forward. Closes
///         the exact-settler windfall seam: UW-controlled `premiumHooks` that revert no longer
///         brick the filler's settle path.
contract ExactFillSettler_onPremiumLegFill_test is ExactFillSettlerTestBase {
    address internal filler;
    address internal destination;
    DummyERC20 internal premiumERC20;
    DummyERC20 internal dstToken;

    function setUp() public override {
        super.setUp();
        filler = makeAddr("filler");
        destination = makeAddr("destination");
        premiumERC20 = new DummyERC20("Premium", "PRM", 18);
        dstToken = new DummyERC20("DstCST", "DST", 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _rolloverFD(address dest) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: dest})));
    }

    function _premiumFD(address debitFrom) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
    }

    function _createAndOpenOrderWithPremiumRate(uint256 minPremiumPerShare)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrderWithPremium(user, DEFAULT_ORDER_SIZE, minPremiumPerShare);
        od.premiumToken = address(premiumERC20);
        od.dstCstToken = address(dstToken);
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForExact(order, user, filler);
    }

    function _doRolloverAndSettlePremiumWithRevert(uint256 premiumPerShare, bytes memory errData)
        internal
        returns (bytes32 orderId, bytes32 orderDigest, uint256 expectedPremium)
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(premiumPerShare);

        orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        expectedPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        if (expectedPremium > 0) {
            _depositPremium(filler, address(premiumERC20), expectedPremium);
        }

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setPhaseRevert(true, 1, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));

        orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1: emits PremiumHooksReverted with err, orderDigest, targetFiller
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsWithNon_emptyErrBytes() external {
        // it should emit PremiumHooksReverted with the bubbled err bytes and orderDigest and targetFiller
        bytes memory errData = hex"cafebabe";

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setPhaseRevert(true, 1, errData);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.expectEmit(true, true, false, true, address(settler));
        emit IExactFillSettler.PremiumHooksReverted(orderDigest, filler, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: paymentSettled stays true (committed)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsAfterSettler_stateWrites() external {
        // it should leave paymentSettled committed as true
        (bytes32 orderId,,) = _doRolloverAndSettlePremiumWithRevert(0.1e18, hex"deadbeef");

        assertTrue(settler.paymentSettled(orderId), "paymentSettled latched despite phase-1 revert");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: finaliseAsSettled routes dstCST normally on a later call
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsAndTheCallerLaterInvokesFinaliseAsSettled() external {
        // it should route dstCST to the filler's destination normally
        (bytes32 orderId,,) = _doRolloverAndSettlePremiumWithRevert(0, hex"deadbeef");

        // Clear the phase-selective revert so `finaliseAsSettled`'s own transfers execute cleanly.
        mockFactory.setPhaseRevert(false, 0, "");

        uint256 balBefore = dstToken.balanceOf(destination);
        settler.finaliseAsSettled(orderId);
        uint256 balAfter = dstToken.balanceOf(destination);

        assertEq(balAfter - balBefore, DEFAULT_PRODUCE_AMOUNT, "dstCST routed to filler destination");
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order Settled");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 4: order-of-writes — success path
    //
    //  I3 / #60 — paymentSettled[orderId] must flip AFTER the phase-1 forward returns, not before.
    //  Technique: the mock factory is armed with a write-order probe. During
    //  `executeIntentHooks(phase=1)` the mock re-enters `settler.paymentSettled(orderId)` and
    //  snapshots the value. If the settler wrote BEFORE calling forward (the PR-7 ordering) the
    //  probe sees `true`; if the settler writes AFTER the forward returns (the PR-8 ordering) the
    //  probe sees `false`. Post-call we also assert `probeObserved == true` to distinguish a
    //  silent failure from a meaningful observation.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenForwardSucceeds() external {
        // it should write paymentSettled AFTER forward returns (order-of-writes assertion)
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.armPaymentSettledProbe(true, orderId);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));

        assertTrue(mockFactory.probeObserved(), "probe must fire during phase-1 forward");
        assertFalse(
            mockFactory.probedPaymentSettled(), "paymentSettled must be false at forward-time (forward-then-write)"
        );
        assertTrue(settler.paymentSettled(orderId), "paymentSettled latched after successful forward");

        // C1 — the premium-leg `FillRecord` is the `AlreadyFilled` guard's storage (line 406);
        // asserting `filledAt > 0` post-success catches a mutation that drops the write.
        bytes32 premiumOH = LibSettlerHashing.computeOutputHash(od.outputs[1]);
        (,,, uint64 filledAt) = settler.fillRecords(orderId, premiumOH);
        assertGt(filledAt, 0, "premium-leg FillRecord written via success branch");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 5: order-of-writes — catch path
    //
    //  I3 / #60 — on phase-1 revert the `paymentSettled[orderId] = true` write (and the premium-leg
    //  `FillRecord` write) must occur INSIDE the catch branch (PR 8) rather than before the try
    //  (PR 7). Evidence:
    //    1. `PremiumHooksReverted` event emits — proves the catch branch was taken.
    //    2. `paymentSettled == true` post-call — the latch was written.
    //  Since the forward reverts, a storage probe in the mock is not usable (the revert rolls
    //  back the probe's own storage). Instead we rely on the combined signal: catch branch
    //  taken + latch committed => the commit happened inside catch. A mutation that removes
    //  `paymentSettled[orderId] = true` from the catch branch would flip this assertion to false.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenForwardCatches() external {
        // it should write paymentSettled AFTER forward returns (order-of-writes assertion)
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        bytes memory errData = hex"deadbeef";
        mockFactory.setPhaseRevert(true, 1, errData);

        vm.expectEmit(true, true, false, true, address(settler));
        emit IExactFillSettler.PremiumHooksReverted(orderDigest, filler, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));

        assertTrue(settler.paymentSettled(orderId), "paymentSettled latched via catch branch");

        // C1 — the premium-leg `FillRecord` is the `AlreadyFilled` guard's storage (line 406);
        // asserting `filledAt > 0` post-catch catches a mutation that drops the catch-branch
        // write, which would otherwise enable a duplicate premium fill after a caught revert.
        bytes32 premiumOH = LibSettlerHashing.computeOutputHash(od.outputs[1]);
        (,,, uint64 filledAt) = settler.fillRecords(orderId, premiumOH);
        assertGt(filledAt, 0, "premium-leg FillRecord written via catch branch");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 6: #61 / I4 — state-parity assertion, divergence path
    //
    //  Mock armed with `suppressPremiumLatch = true`: phase-1 forward returns without setting
    //  `premiumFiredFor[orderDigest][rolloverRec.filler]`. Settler's post-forward parity check
    //  reads `false` and must revert `StateDivergence`, preventing `paymentSettled` from
    //  committing on top of a cellar that never latched.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCellarPremiumFiredForIsFalseAfterSuccessfulForward() external {
        // it should revert StateDivergence
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setSuppressPremiumLatch(true);

        vm.expectRevert(StateDivergence.selector);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 7: #61 / I4 — state-parity assertion, happy path
    //
    //  Default mock latches `premiumFiredFor[d][rolloverRec.filler] = true` on a successful
    //  phase-1 forward. Settler's parity check reads `true`, commits `paymentSettled`, and the
    //  fill succeeds.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCellarPremiumFiredForIsTrueAfterSuccessfulForward() external {
        // it should accept and latch paymentSettled
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));

        assertTrue(settler.paymentSettled(orderId), "paymentSettled latched on happy path");
        assertTrue(mockFactory.premiumFiredFor(orderDigest, filler), "cellar latch mirror is true");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 8: #63 / Integ M1 — PREMIUM_FILLER_SLOT transient-storage write
    //
    //  Mock armed with the transient-slot probe: during the phase-1 forward it reads
    //  `tload(PREMIUM_FILLER_SLOT)`. Exact writes `rolloverRec.filler` to the slot before the
    //  forward, so the probe must observe that address. Verifies the cross-repo ABI element the
    //  cellar-side `_runPremiumPhase` will rely on once the companion PR lands.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSettlerWritesPREMIUM_FILLER_SLOTBeforeForward() external {
        // it should expose rolloverRec.filler via tload during phase-1 forward
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithPremiumRate(0);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(destination));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.armPremiumFillerSlotProbe(true);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler));

        assertTrue(mockFactory.slotProbeObserved(), "slot probe must fire during phase-1 forward");
        assertEq(
            mockFactory.observedPremiumFillerSlot(),
            filler,
            "settler must write rolloverRec.filler to PREMIUM_FILLER_SLOT before forward"
        );
    }
}
