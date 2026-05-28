// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CellarIntent, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";

/// @dev Minimal view interface for the I3 / #60 write-order probe — the public `paymentSettled`
///      mapping getter on `ExactFillSettler` is not exposed on `IExactFillSettler`, so we declare
///      the selector locally.
interface IExactFillSettlerPaymentSettledView {
    function paymentSettled(bytes32 orderId) external view returns (bool);
}

/// @dev Minimal view of `BaseSettler.premiumFillerSlot()` used by the #63 transient-slot probe.
///      Cross-repo ABI element — cellar-side `_runPremiumPhase` uses the same selector.
interface IBaseSettlerPremiumFillerSlot {
    function premiumFillerSlot() external view returns (address);
}

/// @title MockSettlerFactory
/// @notice Minimal factory mock for ExactFillSettler unit tests. Simulates token transfers
///         during executeIntentHooks so balance-delta assertions work without a real cellar stack.
contract MockSettlerFactory {
    mapping(address => address) public cellars;

    address public dstToken;
    uint256 public produceAmount;

    address public srcToken;
    uint256 public leftoverAmount;

    bool public shouldRevert;
    bytes public revertData;

    // Phase-selective revert. When `phaseRevertActive` is true, reverts occur only on the matching
    // `phase` (0 = rollover, 1 = premium). Lets PR 7 tests force a phase-1 revert without tripping
    // the phase-0 rollover leg.
    bool public phaseRevertActive;
    uint8 public phaseRevertPhase;
    bytes public phaseRevertData;

    // I3 / #60 write-order probe — when `probeActive` is true, the mock re-enters the settler
    // during `executeIntentHooks` and records `paymentSettled(probeOrderId)` into
    // `probedPaymentSettled`. Tests read the probed value to assert the latch had not yet been
    // written at forward-time (forward-then-write ordering).
    bool public probeActive;
    bytes32 public probeOrderId;
    bool public probedPaymentSettled;
    bool public probeObserved;

    // #61 / I4 state-parity mirror — mirrors the cellar-side `premiumFiredFor[d][f]` mapping.
    // On a successful phase-1 forward the mock latches this unless `suppressPremiumLatch` is set,
    // matching the live cellar's `_runPremiumPhase` behaviour.
    mapping(bytes32 => mapping(address => bool)) public premiumFiredForMap;
    bool public suppressPremiumLatch;

    // #63 / Integ M1 transient-slot probe — during `executeIntentHooks(phase=1)` the mock calls
    // the settler's `premiumFillerSlot()` view and records the returned address. Mirrors the
    // cross-repo handshake cellar-side `_runPremiumPhase` will use once its companion lands.
    bool public slotProbeActive;
    address public observedPremiumFillerSlot;
    bool public slotProbeObserved;

    function setCellar(address owner, address cellar) external {
        cellars[owner] = cellar;
    }

    function cellarOf(address owner) external view returns (address) {
        return cellars[owner];
    }

    function setRolloverBehavior(address dstToken_, uint256 amount) external {
        dstToken = dstToken_;
        produceAmount = amount;
    }

    function setLeftoverBehavior(address srcToken_, uint256 amount) external {
        srcToken = srcToken_;
        leftoverAmount = amount;
    }

    function setRevertBehavior(bool shouldRevert_, bytes calldata data) external {
        shouldRevert = shouldRevert_;
        revertData = data;
    }

    /// @notice Force a revert only on the specified `phase`. When `active == false`, disables the
    ///         phase-selective revert.
    function setPhaseRevert(bool active, uint8 phase, bytes calldata data) external {
        phaseRevertActive = active;
        phaseRevertPhase = phase;
        phaseRevertData = data;
    }

    /// @notice Arm the I3 / #60 write-order probe. While `active == true` the mock re-enters
    ///         `paymentSettled(orderId)` on the settler during `executeIntentHooks` and records
    ///         the value. Tests read back `probedPaymentSettled` to assert the settler had not
    ///         yet flipped the latch at forward-time (proving forward-then-write ordering).
    function armPaymentSettledProbe(bool active, bytes32 orderId) external {
        probeActive = active;
        probeOrderId = orderId;
        probedPaymentSettled = false;
        probeObserved = false;
    }

    /// @notice #61 / I4 — when `suppress == true`, stop latching `premiumFiredForMap` on a
    ///         successful phase-1 forward, simulating a masquerading/buggy cellar. This exercises
    ///         the settler's `StateDivergence` revert path on the success branch.
    function setSuppressPremiumLatch(bool suppress) external {
        suppressPremiumLatch = suppress;
    }

    /// @notice #61 / I4 — directly override the `premiumFiredFor` latch without running a
    ///         forward. Used to set up negative/positive parity fixtures.
    function setPremiumFiredFor(bytes32 orderDigest, address filler, bool value) external {
        premiumFiredForMap[orderDigest][filler] = value;
    }

    /// @notice #61 / I4 — cellar-side view mirrored from the live `CorkCellar.premiumFiredFor`.
    ///         Settler's success-branch parity check reads this during `_onPremiumLegFill`.
    function premiumFiredFor(bytes32 orderDigest, address filler) external view returns (bool) {
        return premiumFiredForMap[orderDigest][filler];
    }

    /// @notice #63 / Integ M1 — arm the transient-slot probe.
    function armPremiumFillerSlotProbe(bool active) external {
        slotProbeActive = active;
        observedPremiumFillerSlot = address(0);
        slotProbeObserved = false;
    }

    // Revert-knob precedence (checked top-down, first match wins):
    //   1. Global `setRevertBehavior(true, data)` — unconditional revert on every phase. Wins
    //      over `setPhaseRevert` when both are armed.
    //   2. Phase-selective `setPhaseRevert(true, phase, data)` — revert only on the matching
    //      `phase`. Isolates a phase-1 revert without tripping the phase-0 rollover leg.
    // Tests should avoid arming both knobs simultaneously — keep intent unambiguous.
    function executeIntentHooks(
        address,
        bytes32 orderDigest,
        uint8 phase,
        CellarIntent calldata,
        bytes calldata,
        uint256,
        address filler
    ) external returns (uint256) {
        // I3 / #60 write-order probe — must run on phase-1 BEFORE any revert knob fires so the
        // observation captures settler state at the forward boundary. Covers both success and
        // catch scenarios (probe fires either way; revert knobs fire afterward).
        if (probeActive && phase == 1) {
            probedPaymentSettled = IExactFillSettlerPaymentSettledView(msg.sender).paymentSettled(probeOrderId);
            probeObserved = true;
        }
        // #63 / Integ M1 transient-slot probe — call the settler's `premiumFillerSlot()` view;
        // transient storage is scoped per-contract (EIP-1153) so we must go through the settler.
        if (slotProbeActive && phase == 1) {
            observedPremiumFillerSlot = IBaseSettlerPremiumFillerSlot(msg.sender).premiumFillerSlot();
            slotProbeObserved = true;
        }
        if (shouldRevert) {
            bytes memory d = revertData;
            if (d.length == 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(0, 0)
                }
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        if (phaseRevertActive && phase == phaseRevertPhase) {
            bytes memory d = phaseRevertData;
            if (d.length == 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(0, 0)
                }
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        if (phase == 0) {
            if (produceAmount > 0) {
                ERC20Mock(payable(dstToken)).mint(msg.sender, produceAmount);
            }
            if (leftoverAmount > 0) {
                ERC20Mock(payable(srcToken)).mint(msg.sender, leftoverAmount);
            }
        }
        // #61 / I4 — mirror the live cellar: on a successful phase-1 forward, latch
        // `premiumFiredFor[orderDigest][filler] = true` unless suppressed. Exact settlers use
        // `rolloverRec.filler` as the `filler` arg, matching the settler-side parity check.
        if (phase == 1 && !suppressPremiumLatch) {
            premiumFiredForMap[orderDigest][filler] = true;
        }
        return produceAmount;
    }

    // Satisfy ICorkCellarFactory-like interface
    function validateModuleForForwarding(address) external pure {}

    function originatingSettler() external pure returns (address) {
        return address(0);
    }
}
