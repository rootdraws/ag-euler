// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {StateDivergence} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

/// @title PartialFillSettler_onPremiumLegFill
/// @notice BTT coverage for the AS-10 / #58 try/catch around the phase-1 cellar forward. Closes
///         the partial-windfall seam: UW-controlled `premiumHooks` that revert no longer brick
///         the filler's settle path.
contract PartialFillSettler_onPremiumLegFill_test is PartialFillSettlerTestBase {
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
    //  Helpers (duplicated from PartialFillSettler_fill.t.sol to keep
    //  this file self-contained — the test base already carries the
    //  shared signature and order-creation primitives.)
    // ═══════════════════════════════════════════════════════════════

    function _rolloverFD(address filler_, address dest, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: dest, debitFrom: address(0), targetFiller: filler_, intent: intent, cellarSig: ""
                })
            )
        );
    }

    function _premiumFD(address targetFiller_, address debitFrom_, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom_,
                    targetFiller: targetFiller_,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
    }

    function _createAndOpenDistinctOrderWithPremiumRate(uint256 minPremiumPerShare)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, minPremiumPerShare);
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premiumERC20);

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForPartial(order, user, filler);
    }

    function _doRolloverAndSettlePremiumWithRevert(uint256 premiumPerShare, bytes memory errData)
        internal
        returns (bytes32 orderDigest, uint256 expectedPremium)
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        bytes32 orderId = _computeOrderId(order);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        expectedPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        if (expectedPremium > 0) {
            _depositPremium(filler, address(premiumERC20), expectedPremium);
        }

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setPhaseRevert(true, 1, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));

        orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1: emits PremiumHooksReverted with err, orderDigest, targetFiller
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsWithNon_emptyErrBytes() external {
        // it should emit PremiumHooksReverted with the bubbled err bytes and orderDigest and targetFiller
        bytes memory errData = hex"cafebabe";

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setPhaseRevert(true, 1, errData);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.expectEmit(true, true, false, true, address(settler));
        emit IPartialFillSettler.PremiumHooksReverted(orderDigest, filler, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: f.premiumSettled stays true (committed)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsAfterSettler_stateWrites() external {
        // it should leave f.premiumSettled committed as true
        (bytes32 orderDigest,) = _doRolloverAndSettlePremiumWithRevert(0.1e18, hex"deadbeef");

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled latched despite phase-1 revert");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: finaliseAsSettled routes dstCST normally on a later call
    // ═══════════════════════════════════════════════════════════════

    function test_WhenPhase_1ForwardRevertsAndTheCallerLaterInvokesFinaliseAsSettled() external {
        // it should route dstCST to the filler's destination normally
        (bytes32 orderDigest,) = _doRolloverAndSettlePremiumWithRevert(0, hex"deadbeef");

        // Clear the revert so finaliseAsSettled's own transfers execute cleanly.
        mockFactory.setPhaseRevert(false, 0, "");

        // Phase-0 terminal bit on the cellar's `hookNonces` tells `_transitionIfTerminal` that the
        // rollover leg is closed. Without it the order lingers in `Opened` even after every
        // filler finalises — real cellars flip this during `executeIntentHooks`; the mock is inert.
        mockFactory.setHookNonces(orderDigest, 1);

        address[] memory fillers = new address[](1);
        fillers[0] = filler;

        uint256 balBefore = dstToken.balanceOf(destination);
        settler.finaliseAsSettled(orderDigest, fillers);
        uint256 balAfter = dstToken.balanceOf(destination);

        assertEq(balAfter - balBefore, DEFAULT_PRODUCE_AMOUNT, "dstCST routed to filler destination");

        bytes32 orderId = settler.orderIdOf(orderDigest);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order Settled");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 4: order-of-writes — success path
    //
    //  I3 / #60 — premiumSettled must flip AFTER the phase-1 forward returns, not before.
    //  Technique: the mock factory is armed with a write-order probe. During
    //  `executeIntentHooks(phase=1)` the mock re-enters `settler.fillerRollovers(..)` and snapshots
    //  `premiumSettled`. If the settler wrote BEFORE calling forward (the PR-7 ordering) the probe
    //  sees `true`; if the settler writes AFTER the forward returns (the PR-8 ordering) the probe
    //  sees `false`. Post-call we also assert `probeObserved == true` to distinguish a silent
    //  failure from a meaningful observation.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenForwardSucceeds() external {
        // it should write premiumSettled AFTER forward returns (order-of-writes assertion)
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.armPremiumSettledProbe(true, orderDigest, filler);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));

        assertTrue(mockFactory.probeObserved(), "probe must fire during phase-1 forward");
        assertFalse(
            mockFactory.probedPremiumSettled(), "premiumSettled must be false at forward-time (forward-then-write)"
        );
        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled latched after successful forward");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 5: order-of-writes — catch path
    //
    //  I3 / #60 — on phase-1 revert the `premiumSettled = true` write must occur INSIDE the catch
    //  branch (PR 8) rather than before the try (PR 7). Evidence:
    //    1. `PremiumHooksReverted` event emits — proves the catch branch was taken.
    //    2. `premiumSettled == true` post-call — the latch was written.
    //  Since the forward reverts, a storage probe in the mock is not usable (the revert rolls
    //  back the probe's own storage). Instead we rely on the combined signal: catch branch
    //  taken + latch committed => the commit happened inside catch. A mutation that removes
    //  `f.premiumSettled = true` from the catch branch would flip this assertion to false.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenForwardCatches() external {
        // it should write premiumSettled AFTER forward returns (order-of-writes assertion)
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        bytes memory errData = hex"deadbeef";
        mockFactory.setPhaseRevert(true, 1, errData);

        vm.expectEmit(true, true, false, true, address(settler));
        emit IPartialFillSettler.PremiumHooksReverted(orderDigest, filler, errData);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled latched via catch branch");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 6: #61 / I4 — state-parity assertion, divergence path
    //
    //  The mock is armed with `suppressPremiumLatch = true` so a successful phase-1 forward
    //  returns without latching `premiumFiredFor[orderDigest][targetFiller]`. The settler's
    //  post-forward parity check reads `false` and must revert `StateDivergence`, preventing
    //  its own `premiumSettled` latch from committing on top of a cellar that never latched.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCellarPremiumFiredForIsFalseAfterSuccessfulForward() external {
        // it should revert StateDivergence
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.setSuppressPremiumLatch(true);

        vm.expectRevert(StateDivergence.selector);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 7: #61 / I4 — state-parity assertion, happy path
    //
    //  Default mock behaviour latches `premiumFiredFor[d][f] = true` on a successful phase-1
    //  forward, mirroring the live cellar. The settler's parity check reads `true`, commits
    //  `premiumSettled`, and the fill succeeds.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCellarPremiumFiredForIsTrueAfterSuccessfulForward() external {
        // it should accept and latch premiumSettled
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled latched on happy path");
        assertTrue(mockFactory.premiumFiredFor(orderDigest, filler), "cellar latch mirror is true");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 8: #63 / Integ M1 — PREMIUM_FILLER_SLOT transient-storage write
    //
    //  The mock is armed with the transient-slot probe: during the phase-1 forward it calls
    //  `tload(PREMIUM_FILLER_SLOT)` and records the address. The settler writes
    //  `pfd.targetFiller` to the slot post-debit-pre-forward, so the probe must observe the
    //  targetFiller value. This verifies the cross-repo ABI the cellar-side `_runPremiumPhase`
    //  will rely on once the companion PR lands.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSettlerWritesPREMIUM_FILLER_SLOTBeforeForward() external {
        // it should expose targetFiller via tload during phase-1 forward
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        mockFactory.armPremiumFillerSlotProbe(true);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));

        assertTrue(mockFactory.slotProbeObserved(), "slot probe must fire during phase-1 forward");
        assertEq(
            mockFactory.observedPremiumFillerSlot(),
            filler,
            "settler must write pfd.targetFiller to PREMIUM_FILLER_SLOT before forward"
        );
    }
}
