// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CellarIntent, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {CorkCellar} from "cellar/CorkCellar.sol";
import {ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";

/// @dev Minimal view of `BaseSettler.premiumFillerSlot()` used by the #63 transient-slot probe.
///      Declared locally because `IPartialFillSettler` does not expose the view and adding it
///      there would pollute the external surface. Cross-repo ABI element — the cellar-side
///      `_runPremiumPhase` uses the same selector.
interface IBaseSettlerPremiumFillerSlot {
    function premiumFillerSlot() external view returns (address);
}

/// @title MockPartialFactory
/// @notice Minimal factory + cellar mock for PartialFillSettler unit tests. Doubles as both
///         the CorkCellarFactory and the CorkCellar — setCellar(user, address(this)) makes the
///         factory serve as cellar so hookNonces / rolled lookups resolve on the same contract.
contract MockPartialFactory {
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

    // Deterministic phase-1 revert oracle — when `phase1ConditionalActive` is true, phase-1
    // forwards revert iff `(block.number & 1) == expectedParity`. AS-10 integration-test hook for
    // simulating a UW whose premium hooks are wired to revert on specific block-number parities.
    bool public phase1ConditionalActive;
    uint8 public phase1ConditionalParity;
    bytes public phase1ConditionalData;

    address public settler_;

    // Cellar-side state: hookNonces and rolled keyed by orderDigest
    mapping(bytes32 => uint256) public hookNoncesMap;
    mapping(bytes32 => uint256) public rolledMap;

    // I3 / #60 write-order probe — when `probeActive` is true, the mock re-enters the settler
    // during `executeIntentHooks` and records `fillerRollovers(probeOrderDigest, probeFiller).premiumSettled`
    // into `probedPremiumSettled`. Tests read the probed value to assert the latch had not yet been
    // written at forward-time (forward-then-write ordering).
    bool public probeActive;
    bytes32 public probeOrderDigest;
    address public probeFiller;
    bool public probedPremiumSettled;
    bool public probeObserved;

    // #61 / I4 state-parity mirror — mirrors the cellar-side `premiumFiredFor[d][f]` mapping.
    // On a successful phase-1 forward the mock latches this unless `suppressPremiumLatch` is set,
    // matching the live cellar's `_runPremiumPhase` behaviour. Tests toggle `suppressPremiumLatch`
    // to simulate a masquerading/buggy cellar that no-ops without latching.
    mapping(bytes32 => mapping(address => bool)) public premiumFiredForMap;
    bool public suppressPremiumLatch;

    // #63 / Integ M1 transient-slot probe — during `executeIntentHooks(phase=1)` the mock calls
    // the settler's `premiumFillerSlot()` view (which `tload`s the slot in the settler's own
    // context, per EIP-1153 per-contract scoping) and records the returned address. Tests read
    // `observedPremiumFillerSlot` to assert the settler wrote `pfd.targetFiller` before the
    // forward.
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

    /// @notice Activates a deterministic phase-1 revert oracle: reverts iff
    ///         `(block.number & 1) == parity`. Simulates a UW-signed premium hook whose body
    ///         reverts on specific block-number parities (AS-10 integration scenario).
    function setPhase1Conditional(bool active, uint8 parity, bytes calldata data) external {
        phase1ConditionalActive = active;
        phase1ConditionalParity = parity;
        phase1ConditionalData = data;
    }

    function setOriginatingSettler(address settler) external {
        settler_ = settler;
    }

    function setHookNonces(bytes32 orderDigest, uint256 nonce) external {
        hookNoncesMap[orderDigest] = nonce;
    }

    /// @notice Arm the I3 / #60 write-order probe. While `active == true` the mock re-enters
    ///         `IPartialFillSettler.fillerRollovers(orderDigest, filler)` during
    ///         `executeIntentHooks` and records `premiumSettled` into storage. Tests read back
    ///         `probedPremiumSettled` to assert the settler had not yet flipped the latch at
    ///         forward-time (proving forward-then-write ordering). `probeObserved` is set to true
    ///         on the first observation so tests can distinguish "probe never ran" from "probe ran
    ///         and saw false".
    function armPremiumSettledProbe(bool active, bytes32 orderDigest, address filler) external {
        probeActive = active;
        probeOrderDigest = orderDigest;
        probeFiller = filler;
        probedPremiumSettled = false;
        probeObserved = false;
    }

    function setRolled(bytes32 orderDigest, uint256 amount) external {
        rolledMap[orderDigest] = amount;
    }

    /// @notice #61 / I4 — when `suppress == true`, the mock stops latching `premiumFiredForMap`
    ///         during a successful phase-1 forward, simulating a masquerading/buggy cellar. This
    ///         exercises the settler's `StateDivergence` revert path on the success branch.
    function setSuppressPremiumLatch(bool suppress) external {
        suppressPremiumLatch = suppress;
    }

    /// @notice #61 / I4 — directly override the `premiumFiredFor` latch without running a
    ///         forward. Used to set up negative/positive parity fixtures in tests.
    function setPremiumFiredFor(bytes32 orderDigest, address filler, bool value) external {
        premiumFiredForMap[orderDigest][filler] = value;
    }

    /// @notice #61 / I4 — cellar-side view mirrored from the live `CorkCellar.premiumFiredFor`.
    ///         Settler's success-branch parity check reads this during `_onPremiumLegFill`.
    function premiumFiredFor(bytes32 orderDigest, address filler) external view returns (bool) {
        return premiumFiredForMap[orderDigest][filler];
    }

    /// @notice #63 / Integ M1 — arm the transient-slot probe. While active, `executeIntentHooks`
    ///         on phase 1 reads `PREMIUM_FILLER_SLOT` via `tload` and records the address. Tests
    ///         assert the recorded value equals `pfd.targetFiller` to prove the settler wrote
    ///         the slot before forwarding.
    function armPremiumFillerSlotProbe(bool active) external {
        slotProbeActive = active;
        observedPremiumFillerSlot = address(0);
        slotProbeObserved = false;
    }

    // ICorkCellarFactory.executeIntentHooks — mints dstToken to settler
    // and returns produceAmount as actualRolled.
    //
    // Revert-knob precedence (checked top-down, first match wins):
    //   1. Cellar-side `SettlerMismatch` — fires when `setOriginatingSettler(x)` is armed to a
    //      non-zero `x` that differs from `intent.settler`. Mirrors the real cellar guard at
    //      CorkCellar.sol:112 and bubbles `CorkCellar__SettlerMismatch.selector` as the revert
    //      bytes so settler-level try/catch handlers observe the same selector the live stack
    //      would produce.
    //   2. Global `setRevertBehavior(true, data)` — unconditional revert with `data` on every
    //      phase. Coarsest knob; wins over both phase-selective knobs below.
    //   3. Phase-selective `setPhaseRevert(true, phase, data)` — revert only on the matching
    //      `phase`. Used to isolate a phase-1 revert without tripping the phase-0 rollover leg.
    //   4. Deterministic `setPhase1Conditional(true, parity, data)` — revert on phase 1 iff
    //      `(block.number & 1) == parity`. AS-10 integration-test oracle.
    // If multiple knobs are armed, the first one to match wins — tests should avoid arming more
    // than one at a time to keep intent unambiguous.
    function executeIntentHooks(
        address,
        bytes32 orderDigest,
        uint8 phase,
        CellarIntent calldata intent,
        bytes calldata,
        uint256,
        address filler
    ) external returns (uint256) {
        if (settler_ != address(0) && settler_ != intent.settler) {
            // Mirror CorkCellar.sol:112-113 — cellar-side SettlerMismatch bubbles to the caller.
            bytes memory d = abi.encodeWithSelector(CorkCellar.CorkCellar__SettlerMismatch.selector);
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        // I3 / #60 write-order probe — must run on phase-1 BEFORE any revert knob fires so the
        // observation captures settler state at the forward boundary. Covers both success and
        // catch scenarios (probe fires either way; revert knobs fire afterward).
        if (probeActive && phase == 1) {
            probedPremiumSettled =
            IPartialFillSettler(msg.sender).fillerRollovers(probeOrderDigest, probeFiller).premiumSettled;
            probeObserved = true;
        }
        // #63 / Integ M1 transient-slot probe — during phase-1 forward, call back into the
        // settler's `premiumFillerSlot()` view to read the value the settler wrote to its own
        // `PREMIUM_FILLER_SLOT`. EIP-1153 scopes transient storage per-contract, so we cannot
        // read the slot directly from the factory's context — we must go through the settler.
        // This mirrors the cross-repo handshake the cellar-side `_runPremiumPhase` is expected
        // to use (via `ICorkCellarFactory(msg.sender).originatingSettler()` + `premiumFillerSlot()`).
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
        if (phase1ConditionalActive && phase == 1 && (block.number & 1) == phase1ConditionalParity) {
            bytes memory d = phase1ConditionalData;
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
        // `premiumFiredFor[orderDigest][filler] = true` unless the test explicitly suppressed it
        // to simulate a masquerading cellar. Happens after all revert knobs so the latch only
        // sets on the success branch, matching `_runPremiumPhase`.
        if (phase == 1 && !suppressPremiumLatch) {
            premiumFiredForMap[orderDigest][filler] = true;
        }
        return produceAmount;
    }

    // ICorkCellarFactory interface
    function validateModuleForForwarding(address) external pure {}

    function originatingSettler() external view returns (address) {
        return settler_;
    }

    // ICorkCellar.hookNonces — cellar-side view
    function hookNonces(bytes32 orderDigest) external view returns (uint256) {
        return hookNoncesMap[orderDigest];
    }

    // ICorkCellar.rolled — cellar-side view
    function rolled(bytes32 orderDigest) external view returns (uint256) {
        return rolledMap[orderDigest];
    }
}
