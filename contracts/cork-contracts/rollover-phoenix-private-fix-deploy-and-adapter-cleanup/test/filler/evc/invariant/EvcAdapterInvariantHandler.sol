// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {BaseTestEvcFillerAdapter} from "test/filler/BaseTestEvcFillerAdapter.sol";
import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IEvcPartialFillAdapter} from "contracts/interfaces/IEvcPartialFillAdapter.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {TestMintModule} from "test/harness/TestMintModule.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {AttestationRequest, ModuleType} from "registry/DataTypes.sol";

/// @dev Shape interface: both EVC adapters share an identical `execute` + `SETTLER` surface. The
///      handler uses this polymorphically so actions can alternate between the two adapters
///      without branching on the concrete type for every call.
interface IEvcAdapterShape {
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external;
    function SETTLER() external view returns (address);
}

/// @title EvcAdapterInvariantHandler
/// @notice Invariant fuzz handler for `EvcExactFillAdapter` / `EvcPartialFillAdapter` covering
///         INV-F1, F2, F4, F5, F6, F7, F8 (F3 dropped — the reference adapter does not sweep
///         leftovers). Exposes a bounded action surface that drives both the Exact-bound and
///         Partial-bound adapters through happy-path and revert-path `execute` calls — each
///         happy-path action wraps the adapter call in `evc.batch([executeItem])` with
///         `onBehalfOfAccount = subaccount` so `getCurrentOnBehalfOfAccount` resolves inside the
///         adapter. Ghost state separates per-adapter ledgers.
/// @dev Inherits `BaseTestEvcFillerAdapter` to reuse the real EVC + settler + cellar + ERC-6909
///      + Phoenix harness. Each action builds a fresh order per invocation — the settlers' per-
///      `(orderId, filler)` keying makes stale orders unusable after a single happy-path run, so
///      per-action fresh orders are simpler and more realistic than a shared pool. Subaccount,
///      actor, and third-party addresses are pulled from a fixed roster to keep fuzz seeds
///      deterministic.
contract EvcAdapterInvariantHandler is BaseTestEvcFillerAdapter {
    // ─── Constants ───────────────────────────────────────────────────────────────────────
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;
    uint256 internal constant ACTOR_COUNT = 4;

    // ─── Shared fixtures ─────────────────────────────────────────────────────────────────
    TestMintModule internal testMintModule;
    DummyERC20 internal premTokenExact;
    DummyERC20 internal dstCstExact;
    DummyERC20 internal premTokenPartial;
    DummyERC20 internal dstCstPartial;

    address[ACTOR_COUNT] internal subaccounts;

    /// @dev Per-subaccount adapter instances. Index 0 is the base-harness `evcAdapterExact` /
    ///      `evcAdapterPartial` pair (bound to `AUTHORIZED_CALLER` == subaccounts[0] after the
    ///      setUp override below). Indices 1..N host dedicated per-subaccount deployments so
    ///      each actor can drive their own EVC frame through the adapter's `AUTHORIZED_CALLER`
    ///      gate. Written once in the constructor; read read-only during actions.
    mapping(address => EvcExactFillAdapter) internal exactAdapterOf;
    mapping(address => EvcPartialFillAdapter) internal partialAdapterOf;

    // ─── Ghost state ─────────────────────────────────────────────────────────────────────
    /// @dev Ghost: callers' pre-action srcCST balance. Mirrors the `ghost_callerPreBalance` field
    ///      called out in plan §PR 3a Task 7. Kept as a scalar snapshot of the most recent happy
    ///      action; invariant assertions read the committed adapter ledger.
    uint256 public ghost_callerPreBalance;

    /// @dev Tracked srcCST excess retained on each adapter. Keyed by `adapter` and `token` so the
    ///      per-adapter ledger is unambiguous. Updated after every successful happy-path run:
    ///        ghost_adapterSrcCstExcess[adapter][token] = adapter.balanceOf(token) post-run.
    ///      INV-F1 asserts the live balance equals this tracked value (balance <= excess).
    mapping(address => mapping(address => uint256)) public ghost_adapterSrcCstExcess;

    /// @dev Set of dstCST tokens seen by each adapter. INV-F1 asserts balance == 0 for each.
    mapping(address => address[]) internal _ghost_adapterDstCstSeen;
    mapping(address => mapping(address => bool)) internal _ghost_adapterDstCstFlag;

    /// @dev (token, spender) allowance pairs touched by each adapter. INV-F2 asserts zero.
    mapping(address => address[]) internal _ghost_adapterAllowanceTokens;
    mapping(address => mapping(address => bool)) internal _ghost_adapterAllowanceTokenFlag;
    mapping(address => address[]) internal _ghost_adapterAllowanceSpenders;
    mapping(address => mapping(address => bool)) internal _ghost_adapterAllowanceSpenderFlag;

    /// @dev Adapters registered at setup for invariant iteration.
    address[] public ghost_adapters;

    /// @dev Finaliser tracking: ghost_fillerFinalised[digest][adapter] == true after a successful
    ///      run against that (digest, adapter) pair. Not used by INV directly but records the
    ///      positive-path progress for sanity checks.
    mapping(bytes32 => mapping(address => bool)) public ghost_fillerFinalised;

    /// @dev Tokens seen by each adapter — both src and dst variants. Iterated by INV-F1.
    mapping(address => address[]) internal _ghost_adapterTokensSeen;
    mapping(address => mapping(address => bool)) internal _ghost_adapterTokenFlag;

    /// @dev ERC-6909 token-ids seen by each adapter. INV-F4 asserts zero balance.
    mapping(address => uint256[]) internal _ghost_adapterErc6909Ids;
    mapping(address => mapping(uint256 => bool)) internal _ghost_adapterErc6909IdFlag;

    /// @dev Actors considered as potential operator-of candidates. INV-F5 asserts
    ///      `isOperator(adapter, actor) == false` — the adapter itself never calls `setOperator`.
    address[] public ghost_actors;

    /// @dev Count of adapter-side events observed across the campaign. INV-F8 asserts zero.
    uint256 public ghost_adapterEventCount;

    /// @dev Atomic-revert parity failure counter. INV-F7 asserts zero.
    ///
    ///      All increments are made AFTER the in-memory snapshot/compare returns — no
    ///      `vm.revertToState` is used, so the counter survives the handler call. The prior
    ///      implementation (PR 3a) used `vm.revertToState` inside `_assertAdapterAtomicRevertParity`
    ///      which rewound the counter writes themselves and made "adapter reverts but leaves dirty
    ///      state" unobservable. Strengthened in PR 3b (C2) to snapshot-and-compare in memory.
    uint256 public ghost_atomicFailures;

    /// @dev Counter for "adapter reverted but post-call state is dirty". Distinct from
    ///      `ghost_atomicFailures` (which primarily tracks "adapter unexpectedly succeeded") so the
    ///      split invariant in `EvcAdapterInvariant.t.sol` can report breaches independently.
    ///      Increments once per dirty slot discovered in `_assertAdapterStateUnchanged` — a single
    ///      reverting action may push this counter by more than one if multiple observed slots
    ///      (e.g. dstCST balance AND allowance AND ERC-6909 balance) diverged from their pre-call
    ///      snapshot. The invariant asserts the counter stays at zero, so any divergence trips it.
    uint256 public ghost_atomicDirtyStateFailures;

    /// @dev Successful happy-path action counter. Incremented in each happy-path try-branch after
    ///      the adapter call returns.
    uint256 public ghost_settledCount;

    /// @dev INV-F6 (liveness counter only). Bumped in lockstep with `ghost_settledCount` on every
    ///      happy-path action. Preserved so downstream tooling can read per-action debit provenance,
    ///      but the strong RFC §7.5 property is now expressed via
    ///      `ghost_settlerObservedAdapterCount` below. See §INV-F6 assertion in
    ///      `EvcAdapterInvariant.t.sol` for the definition-fidelity explanation.
    uint256 public ghost_resolvedCallerDebitCount;

    /// @dev INV-F6 strengthened (C1 fix): counts happy-path actions where POST-call settler-side
    ///      observation confirms (a) `msg.sender` on the rollover-leg fill was the adapter itself
    ///      (via `fillRecords[orderId][rolloverOH].filler == address(adapter)` on Exact, or
    ///      `_fillerRollovers[digest][adapter].srcCstProvided != 0` on Partial), AND (b) the order
    ///      reached `OrderStatus.Settled`. This verifies the RFC §7.5 property that the settler sees
    ///      the adapter as its caller (not the EVC), independent of the in-handler bookkeeping.
    ///      Invariant F6 asserts `ghost_settlerObservedAdapterCount == ghost_settledCount`.
    uint256 public ghost_settlerObservedAdapterCount;

    /// @dev INV-F6 strengthened (C1 fix): counts happy-path actions where the ERC-6909 premium
    ///      balance of `debitFrom` decreased (or stayed equal when the premium Output amount was 0)
    ///      post-call. Proves settler-side `_settle()` drew from the resolved subaccount. Kept
    ///      separate from `ghost_settlerObservedAdapterCount` so breaches can be attributed to
    ///      either observation independently.
    uint256 public ghost_settlerDebitedDebitorCount;

    /// @dev INV-F9 (B1): counts happy-path executions of `actionExecuteCrossCallerTheft` where the
    ///      attacker's batch *succeeded* — which it MUST NEVER do, because the adapter's
    ///      `onBehalfOfAccount == AUTHORIZED_CALLER` guard rejects cross-caller theft attempts.
    ///      `invariant_F9_noCrossCallerTheft` asserts this counter stays at zero.
    uint256 public ghost_crossCallerTheftSucceeded;

    constructor() {
        // Run full harness once — BaseTestEvcFillerAdapter's setUp is virtual-public on the
        // inherited Test chain so we can invoke it from constructor.
        setUp();

        testMintModule = new TestMintModule();
        premTokenExact = new DummyERC20("PremExact", "PEX", 18);
        dstCstExact = new DummyERC20("DstExact", "DEX", 18);
        premTokenPartial = new DummyERC20("PremPartial", "PPA", 18);
        dstCstPartial = new DummyERC20("DstPartial", "DPA", 18);

        _registerTestModule(address(testMintModule));

        // Slot 0 is the base-harness pair, bound to AUTHORIZED_CALLER. Remaining actors get
        // dedicated per-subaccount adapters so every happy-path action can satisfy
        // `onBehalfOfAccount == adapter.AUTHORIZED_CALLER`.
        subaccounts[0] = AUTHORIZED_CALLER;
        ghost_actors.push(AUTHORIZED_CALLER);
        exactAdapterOf[AUTHORIZED_CALLER] = evcAdapterExact;
        partialAdapterOf[AUTHORIZED_CALLER] = evcAdapterPartial;
        ghost_adapters.push(address(evcAdapterExact));
        ghost_adapters.push(address(evcAdapterPartial));

        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            address sub = makeAddr(string(abi.encodePacked("sub-", bytes1(uint8(0x30 + i)))));
            subaccounts[i] = sub;
            ghost_actors.push(sub);
            EvcExactFillAdapter exactAdapter_ =
                new EvcExactFillAdapter(address(exactSettler), address(0), address(evc), sub);
            EvcPartialFillAdapter partialAdapter_ =
                new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), sub);
            exactAdapterOf[sub] = exactAdapter_;
            partialAdapterOf[sub] = partialAdapter_;
            ghost_adapters.push(address(exactAdapter_));
            ghost_adapters.push(address(partialAdapter_));
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Abstract implementations inherited from BaseTestSettler
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    function _signOrderWithSmartWallet(IOriginSettler.GaslessCrossChainOrder memory, address, address)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signCancel(bytes32 orderId, uint256 cancelDeadline, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 cancelDigest = keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, cancelDeadline));
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), cancelDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        return abi.encodePacked(cancelDeadline, abi.encodePacked(r, s, v));
    }

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory s) {
        return s;
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}

    // ═══════════════════════════════════════════════════════════════
    //  Action surface (weighted across Exact + Partial bindings)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Exact-binding happy path. Wraps the adapter call in `evc.batch`. Updates per-
    ///         adapter ghost ledgers for INV-F1/F2/F4 and observes settler-side state post-call to
    ///         drive the strengthened INV-F6 counters (C1 fix).
    /// @param debitFromSelector Fuzz input chooses the ERC-6909 debit source:
    ///        - `debitFromSelector % 4 == 0` → third-party subaccount (not the resolved caller),
    ///        - otherwise → `debitFrom == sub` (the resolved caller — majority path per C3).
    function actionExecuteExactHappy(uint256 subSeed, uint256 destSeed, uint256 debitFromSelector) external {
        address sub = _selectSub(subSeed);
        address dest = _selectSub(destSeed);
        address debitFrom = _selectDebitFrom(sub, debitFromSelector);
        EvcExactFillAdapter adapter = exactAdapterOf[sub];

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildExactOrder();

        _authoriseAdapterOperatorRaw(sub, address(adapter));
        _prepareAdapterErc6909(sub, adapter, od.premiumToken, PREMIUM_DEPOSIT);
        if (debitFrom != sub) {
            // Third-party debitFrom: only the ERC-6909 operator bits are flipped for the premium
            // identity. `_authoriseAdapterOperator` (EVC operator) is intentionally NOT called for
            // `debitFrom` because the EVC operator is scoped to `onBehalfOfAccount`, which is
            // still `sub` in this batch item — `debitFrom` is just an ERC-6909 premium identity.
            _prepareAdapterErc6909(debitFrom, adapter, od.premiumToken, PREMIUM_DEPOSIT);
        }
        _seedAdapterSrcCst(adapter, od.srcCstToken, ORDER_SIZE);

        _trackAdapterToken(address(adapter), od.srcCstToken);
        _trackAdapterToken(address(adapter), od.dstCstToken);
        _trackAdapterDstCst(address(adapter), od.dstCstToken);
        _trackAdapterAllowancePair(address(adapter), od.srcCstToken, address(exactSettler));
        _trackAdapterAllowancePair(address(adapter), od.dstCstToken, address(exactSettler));
        _trackAdapterErc6909Id(address(adapter), od.premiumToken);

        ghost_callerPreBalance = IERC20(od.srcCstToken).balanceOf(sub);
        uint256 premBalBefore = premium.balanceOf(debitFrom, uint256(uint160(od.premiumToken)));

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapter)), sub, abi.encode(order), sig, ofd, ORDER_SIZE, debitFrom, dest
        ) {
            _harvestLogs(address(adapter));
            uint256 bal = IERC20(od.srcCstToken).balanceOf(address(adapter));
            ghost_adapterSrcCstExcess[address(adapter)][od.srcCstToken] = bal;
            ghost_settledCount += 1;
            ghost_resolvedCallerDebitCount += 1;
            bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
            ghost_fillerFinalised[digest][address(adapter)] = true;
            _observeExactSettlerState(orderId, od, debitFrom, premBalBefore, address(adapter));
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice Partial-binding happy path. Wraps the adapter call in `evc.batch`. Observes settler-
    ///         side state post-call (C1 fix) and optionally routes `debitFrom` through a third-party
    ///         subaccount (C3 fix).
    function actionExecutePartialHappy(uint256 subSeed, uint256 destSeed, uint256 debitFromSelector) external {
        address sub = _selectSub(subSeed);
        address dest = _selectSub(destSeed);
        address debitFrom = _selectDebitFrom(sub, debitFromSelector);
        EvcPartialFillAdapter adapter = partialAdapterOf[sub];

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildPartialOrder();

        _authoriseAdapterOperatorRaw(sub, address(adapter));
        _prepareAdapterErc6909(sub, adapter, od.premiumToken, PREMIUM_DEPOSIT);
        if (debitFrom != sub) {
            // Third-party debitFrom: only the ERC-6909 operator bits are flipped for the premium
            // identity. `_authoriseAdapterOperator` (EVC operator) is intentionally NOT called for
            // `debitFrom` because the EVC operator is scoped to `onBehalfOfAccount`, which is
            // still `sub` in this batch item — `debitFrom` is just an ERC-6909 premium identity.
            _prepareAdapterErc6909(debitFrom, adapter, od.premiumToken, PREMIUM_DEPOSIT);
        }
        _seedAdapterSrcCst(adapter, od.srcCstToken, ORDER_SIZE);

        _trackAdapterToken(address(adapter), od.srcCstToken);
        _trackAdapterToken(address(adapter), od.dstCstToken);
        _trackAdapterDstCst(address(adapter), od.dstCstToken);
        _trackAdapterAllowancePair(address(adapter), od.srcCstToken, address(partialSettler));
        _trackAdapterAllowancePair(address(adapter), od.dstCstToken, address(partialSettler));
        _trackAdapterErc6909Id(address(adapter), od.premiumToken);

        ghost_callerPreBalance = IERC20(od.srcCstToken).balanceOf(sub);
        uint256 premBalBefore = premium.balanceOf(debitFrom, uint256(uint160(od.premiumToken)));

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);

        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapter)), sub, abi.encode(order), sig, ofd, ORDER_SIZE, debitFrom, dest
        ) {
            _harvestLogs(address(adapter));
            uint256 bal = IERC20(od.srcCstToken).balanceOf(address(adapter));
            ghost_adapterSrcCstExcess[address(adapter)][od.srcCstToken] = bal;
            ghost_settledCount += 1;
            ghost_resolvedCallerDebitCount += 1;
            ghost_fillerFinalised[digest][address(adapter)] = true;
            _observePartialSettlerState(digest, od, debitFrom, premBalBefore, address(adapter));
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice `destination == address(0)` revert path (INV-F7 parity). Alternates adapters.
    /// @dev C2 fix: uses in-memory `_AdapterSnapshot` rather than `vm.snapshotState` /
    ///      `vm.revertToState`. `vm.revertToState` would rewind the handler's own ghost writes
    ///      inside the parity check, making "adapter reverts but leaves dirty state" unobservable.
    ///      C5 fix: logs are harvested BEFORE the state check — the earlier `vm.revertToState`
    ///      ordering cleared the Vm log buffer before `_harvestLogs` could scan it.
    function actionExecuteZeroDestination(uint256 subSeed, uint256 adapterSeed) external {
        address sub = _selectSub(subSeed);
        bool useExact = (adapterSeed & 1) == 0;
        IEvcAdapterShape adapter = useExact
            ? IEvcAdapterShape(address(exactAdapterOf[sub]))
            : IEvcAdapterShape(address(partialAdapterOf[sub]));

        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder() : _buildPartialOrder();

        _AdapterSnapshot memory pre = _snapshotAdapterState(address(adapter));
        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapter)), sub, abi.encode(order), sig, ofd, ORDER_SIZE, sub, address(0)
        ) {
            _harvestLogs(address(adapter));
            // Unexpected success: adapter should have reverted `ZeroDestination`.
            ghost_atomicFailures += 1;
        } catch {
            _harvestLogs(address(adapter));
            _assertAdapterStateUnchanged(address(adapter), pre);
        }
    }

    /// @notice Insufficient-balance revert path: skip the srcCST seed. Alternates adapters.
    /// @dev If a prior happy-path action left residual srcCST on the adapter such that the live
    ///      balance is already >= ORDER_SIZE, the adapter's pre-balance guard would NOT revert —
    ///      which would convert this action into a happy-path success and break INV-F7's
    ///      revert-parity accounting. Skip in that case so the action remains revert-only.
    ///      C2/C5 fixes: snapshot/compare in memory; harvest logs before the state check.
    function actionExecuteInsufficientBalance(uint256 subSeed, uint256 adapterSeed) external {
        address sub = _selectSub(subSeed);
        bool useExact = (adapterSeed & 1) == 0;
        IEvcAdapterShape adapter = useExact
            ? IEvcAdapterShape(address(exactAdapterOf[sub]))
            : IEvcAdapterShape(address(partialAdapterOf[sub]));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder() : _buildPartialOrder();

        if (IERC20(od.srcCstToken).balanceOf(address(adapter)) >= ORDER_SIZE) {
            return;
        }

        _AdapterSnapshot memory pre = _snapshotAdapterState(address(adapter));
        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapter)), sub, abi.encode(order), sig, ofd, ORDER_SIZE, sub, sub
        ) {
            _harvestLogs(address(adapter));
            ghost_atomicFailures += 1;
        } catch {
            _harvestLogs(address(adapter));
            _assertAdapterStateUnchanged(address(adapter), pre);
        }
    }

    /// @notice Direct-call revert path: invoke `adapter.execute` directly (no EVC frame), which
    ///         the adapter rejects with `EvcExactFillAdapter__InvalidCaller_or_Partial`. Alternates adapters.
    /// @dev C2/C5 fixes: snapshot/compare in memory; harvest logs before the state check.
    function actionExecuteDirectCall(uint256 subSeed, uint256 adapterSeed) external {
        address sub = _selectSub(subSeed);
        bool useExact = (adapterSeed & 1) == 0;
        IEvcAdapterShape adapter = useExact
            ? IEvcAdapterShape(address(exactAdapterOf[sub]))
            : IEvcAdapterShape(address(partialAdapterOf[sub]));

        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder() : _buildPartialOrder();

        _AdapterSnapshot memory pre = _snapshotAdapterState(address(adapter));
        vm.recordLogs();
        vm.prank(sub);
        try adapter.execute(abi.encode(order), sig, ofd, ORDER_SIZE, sub, sub) {
            _harvestLogs(address(adapter));
            ghost_atomicFailures += 1;
        } catch {
            _harvestLogs(address(adapter));
            _assertAdapterStateUnchanged(address(adapter), pre);
        }
    }

    /// @notice Over-funded happy path: seed adapter with srcCST > srcCstAmount. Verifies INV-F1
    ///         accommodates the retained excess (no leftover sweep). Also exercises INV-F6
    ///         strengthened observations (C1) and the third-party-debitFrom variant (C3).
    function actionExecuteOverFunded(uint256 subSeed, uint256 destSeed, uint256 overfundSeed, uint256 debitFromSelector)
        external
    {
        address sub = _selectSub(subSeed);
        address dest = _selectSub(destSeed);
        uint256 overfund = ORDER_SIZE + bound(overfundSeed, 1, 100e18);

        bool useExact = (overfundSeed & 1) == 0;
        IEvcAdapterShape adapter = useExact
            ? IEvcAdapterShape(address(exactAdapterOf[sub]))
            : IEvcAdapterShape(address(partialAdapterOf[sub]));
        address settler_ = adapter.SETTLER();
        address debitFrom = _selectDebitFrom(sub, debitFromSelector);

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder() : _buildPartialOrder();

        _authoriseAdapterOperatorRaw(sub, address(adapter));
        _prepareAdapterErc6909(sub, address(adapter), settler_, od.premiumToken, PREMIUM_DEPOSIT);
        if (debitFrom != sub) {
            // Third-party debitFrom: only the ERC-6909 operator bits are flipped for the premium
            // identity. `_authoriseAdapterOperator` (EVC operator) is intentionally NOT called for
            // `debitFrom` because the EVC operator is scoped to `onBehalfOfAccount`, which is
            // still `sub` in this batch item — `debitFrom` is just an ERC-6909 premium identity.
            _prepareAdapterErc6909(debitFrom, address(adapter), settler_, od.premiumToken, PREMIUM_DEPOSIT);
        }
        _seedAdapterSrcCstRaw(address(adapter), od.srcCstToken, overfund);

        _trackAdapterToken(address(adapter), od.srcCstToken);
        _trackAdapterToken(address(adapter), od.dstCstToken);
        _trackAdapterDstCst(address(adapter), od.dstCstToken);
        _trackAdapterAllowancePair(address(adapter), od.srcCstToken, settler_);
        _trackAdapterAllowancePair(address(adapter), od.dstCstToken, settler_);
        _trackAdapterErc6909Id(address(adapter), od.premiumToken);

        uint256 premBalBefore = premium.balanceOf(debitFrom, uint256(uint160(od.premiumToken)));

        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapter)), sub, abi.encode(order), sig, ofd, ORDER_SIZE, debitFrom, dest
        ) {
            _harvestLogs(address(adapter));
            uint256 bal = IERC20(od.srcCstToken).balanceOf(address(adapter));
            ghost_adapterSrcCstExcess[address(adapter)][od.srcCstToken] = bal;
            ghost_settledCount += 1;
            ghost_resolvedCallerDebitCount += 1;
            if (useExact) {
                bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
                _observeExactSettlerState(orderId, od, debitFrom, premBalBefore, address(adapter));
            } else {
                bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
                _observePartialSettlerState(digest, od, debitFrom, premBalBefore, address(adapter));
            }
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice INV-F9 (B1): cross-caller theft attempt. Seeder sub-A has an adapter `adapterA`
    ///         (bound to `AUTHORIZED_CALLER = subA`) pre-seeded with srcCST and ERC-6909 premium
    ///         authorisation. Attacker sub-B dispatches an `evc.batch` targeting `adapterA` with
    ///         `onBehalfOfAccount = subB`. The adapter's `AUTHORIZED_CALLER` gate MUST reject —
    ///         the batch MUST revert. Any success increments `ghost_crossCallerTheftSucceeded`.
    /// @dev This is the handler-level construction of the pashov B1 attack. Before the B1 fix,
    ///      the adapter accepted any non-zero `onBehalfOfAccount`, so subB could drain subA's
    ///      pre-seeded srcCST and debit subA's authorised ERC-6909 premium. Post-fix, the check
    ///      `onBehalfOfAccount == AUTHORIZED_CALLER` blocks the theft at the adapter entry.
    function actionExecuteCrossCallerTheft(uint256 seederSeed, uint256 attackerSeed, uint256 destSeed) external {
        address seeder = _selectSub(seederSeed);
        address attacker = _selectSub(attackerSeed);
        if (attacker == seeder) {
            attacker = subaccounts[(seederSeed + 1) % ACTOR_COUNT];
            if (attacker == seeder) return;
        }
        address dest = _selectSub(destSeed);

        bool useExact = (seederSeed & 1) == 0;
        IEvcAdapterShape adapterA = useExact
            ? IEvcAdapterShape(address(exactAdapterOf[seeder]))
            : IEvcAdapterShape(address(partialAdapterOf[seeder]));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder() : _buildPartialOrder();

        // Seeder's preconditions: adapter is pre-seeded with srcCST and has ERC-6909
        // premium authorisation from the seeder. Attacker passes `debitFrom = seeder` so a
        // pre-B1 adapter would drain seeder's authorised premium.
        _authoriseAdapterOperatorRaw(seeder, address(adapterA));
        _prepareAdapterErc6909(seeder, address(adapterA), adapterA.SETTLER(), od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCstRaw(address(adapterA), od.srcCstToken, ORDER_SIZE);
        // Record the post-seed srcCST balance so INV-F1's upper-bound check tolerates the retained
        // seed on the rejected-batch path. Happy-path actions overwrite this slot after a
        // successful execute; here the execute MUST revert, so the seeded amount stays on the
        // adapter and the ledger must reflect it.
        ghost_adapterSrcCstExcess[address(adapterA)][od.srcCstToken] =
            IERC20(od.srcCstToken).balanceOf(address(adapterA));

        _trackAdapterToken(address(adapterA), od.srcCstToken);
        _trackAdapterToken(address(adapterA), od.dstCstToken);
        _trackAdapterDstCst(address(adapterA), od.dstCstToken);
        _trackAdapterAllowancePair(address(adapterA), od.srcCstToken, adapterA.SETTLER());
        _trackAdapterAllowancePair(address(adapterA), od.dstCstToken, adapterA.SETTLER());
        _trackAdapterErc6909Id(address(adapterA), od.premiumToken);

        _AdapterSnapshot memory pre = _snapshotAdapterState(address(adapterA));
        vm.recordLogs();
        try this.dispatchExecuteViaBatch(
            IEvcAdapterShape(address(adapterA)), attacker, abi.encode(order), sig, ofd, ORDER_SIZE, seeder, dest
        ) {
            _harvestLogs(address(adapterA));
            // Attacker's batch SUCCEEDED — the B1 guard failed.
            ghost_crossCallerTheftSucceeded += 1;
        } catch {
            _harvestLogs(address(adapterA));
            _assertAdapterStateUnchanged(address(adapterA), pre);
        }
    }

    /// @notice External wrapper around a single-item `evc.batch` so the handler can catch reverts
    ///         via try/catch. Solidity `try` requires an external call — calling an internal
    ///         helper bubbles the revert. Assembles the BatchItem inline to avoid the 10-arg
    ///         helper's via-ir stack pressure.
    function dispatchExecuteViaBatch(
        IEvcAdapterShape adapter,
        address subaccount,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external {
        require(msg.sender == address(this), "EvcAdapterInvariantHandler: self-only");
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(adapter),
            onBehalfOfAccount: subaccount,
            value: 0,
            data: abi.encodeWithSelector(
                IEvcAdapterShape.execute.selector,
                orderData,
                signature,
                originFillerData,
                srcCstAmount,
                debitFrom,
                destination
            )
        });
        vm.prank(subaccount);
        evc.batch(items);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Ghost array length getters + public readers
    // ═══════════════════════════════════════════════════════════════

    function ghostAdaptersLen() external view returns (uint256) {
        return ghost_adapters.length;
    }

    function ghostActorsLen() external view returns (uint256) {
        return ghost_actors.length;
    }

    function ghostAdapterTokensLen(address adapter) external view returns (uint256) {
        return _ghost_adapterTokensSeen[adapter].length;
    }

    function ghostAdapterToken(address adapter, uint256 i) external view returns (address) {
        return _ghost_adapterTokensSeen[adapter][i];
    }

    function ghostAdapterDstCstLen(address adapter) external view returns (uint256) {
        return _ghost_adapterDstCstSeen[adapter].length;
    }

    function ghostAdapterDstCst(address adapter, uint256 i) external view returns (address) {
        return _ghost_adapterDstCstSeen[adapter][i];
    }

    function ghostAdapterAllowanceTokensLen(address adapter) external view returns (uint256) {
        return _ghost_adapterAllowanceTokens[adapter].length;
    }

    function ghostAdapterAllowanceToken(address adapter, uint256 i) external view returns (address) {
        return _ghost_adapterAllowanceTokens[adapter][i];
    }

    function ghostAdapterAllowanceSpendersLen(address adapter) external view returns (uint256) {
        return _ghost_adapterAllowanceSpenders[adapter].length;
    }

    function ghostAdapterAllowanceSpender(address adapter, uint256 i) external view returns (address) {
        return _ghost_adapterAllowanceSpenders[adapter][i];
    }

    function ghostAdapterErc6909IdsLen(address adapter) external view returns (uint256) {
        return _ghost_adapterErc6909Ids[adapter].length;
    }

    function ghostAdapterErc6909Id(address adapter, uint256 i) external view returns (uint256) {
        return _ghost_adapterErc6909Ids[adapter][i];
    }

    function premiumContract() external view returns (address) {
        return address(premium);
    }

    function evcContract() external view returns (address) {
        return address(evc);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal helpers — order construction
    // ═══════════════════════════════════════════════════════════════

    function _buildExactOrder()
        internal
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            bytes memory signature,
            bytes memory originFillerData
        )
    {
        // Warp 1 second forward so each invocation produces a fresh nonce + orderId.
        vm.warp(block.timestamp + 1);

        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));

        od.dstCstToken = address(dstCstExact);
        od.premiumToken = address(premTokenExact);
        od.outputs = _twoOutputs(address(dstCstExact), address(premTokenExact), ORDER_SIZE, user.addr);

        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCstExact));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        signature = _signOrderExact(order);
        originFillerData = _buildOriginFillerData(ORDER_SIZE, user.addr);
    }

    function _buildPartialOrder()
        internal
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            bytes memory signature,
            bytes memory originFillerData
        )
    {
        vm.warp(block.timestamp + 1);

        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, true, false, address(partialSettler));

        od.dstCstToken = address(dstCstPartial);
        od.premiumToken = address(premTokenPartial);
        od.outputs = _twoOutputs(address(dstCstPartial), address(premTokenPartial), ORDER_SIZE, user.addr);

        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCstPartial));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), ORDER_SIZE, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        signature = _signOrderPartial(order);
        originFillerData = _buildOriginFillerData(ORDER_SIZE, user.addr);
    }

    function _signOrderExact(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes memory) {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", exactSettler.domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    function _signOrderPartial(IOriginSettler.GaslessCrossChainOrder memory order)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", partialSettler.domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    function _mintHook(address settler_, address dstCstToken) internal view returns (Call[] memory hooks) {
        hooks = new Call[](1);
        hooks[0] = Call({
            target: address(testMintModule),
            value: 0,
            callData: abi.encodeCall(TestMintModule.execute, (dstCstToken, settler_)),
            allowFailure: false,
            isDelegateCall: true
        });
    }

    function _twoOutputs(address dstCstToken, address premTkn, uint256 amt, address recipient)
        internal
        view
        returns (IOriginSettler.Output[] memory outputs)
    {
        outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(dstCstToken))),
            amount: amt,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(premTkn))),
            amount: 0,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
    }

    function _buildIntent(
        bytes32 digest,
        address settler_,
        uint256 orderSize,
        bool partialFills,
        bool underfill,
        Call[] memory rHooks,
        Call[] memory pHooks
    ) internal view returns (CellarIntent memory) {
        return CellarIntent({
            orderDigest: digest,
            expectedCaller: address(factory),
            settler: settler_,
            deadline: uint256(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            orderSize: orderSize,
            allowPartialFills: partialFills,
            allowUnderfill: underfill,
            rolloverHooks: rHooks,
            premiumHooks: pHooks
        });
    }

    function _registerTestModule(address module) internal {
        registry.registerModule(defaultResolverUID, module, "", "");
        ModuleType[] memory mt = new ModuleType[](1);
        mt[0] = ModuleType.wrap(2);
        registry.attest(
            defaultSchemaUID, AttestationRequest({moduleAddress: module, expirationTime: 0, data: "", moduleTypes: mt})
        );
        factory.registerModule(module);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Ghost tracking + atomic-revert parity
    // ═══════════════════════════════════════════════════════════════

    function _selectSub(uint256 seed) internal view returns (address) {
        return subaccounts[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _trackAdapterToken(address adapter, address token) internal {
        if (_ghost_adapterTokenFlag[adapter][token]) return;
        _ghost_adapterTokenFlag[adapter][token] = true;
        _ghost_adapterTokensSeen[adapter].push(token);
    }

    function _trackAdapterDstCst(address adapter, address token) internal {
        if (_ghost_adapterDstCstFlag[adapter][token]) return;
        _ghost_adapterDstCstFlag[adapter][token] = true;
        _ghost_adapterDstCstSeen[adapter].push(token);
    }

    function _trackAdapterAllowancePair(address adapter, address token, address spender) internal {
        if (!_ghost_adapterAllowanceTokenFlag[adapter][token]) {
            _ghost_adapterAllowanceTokenFlag[adapter][token] = true;
            _ghost_adapterAllowanceTokens[adapter].push(token);
        }
        if (!_ghost_adapterAllowanceSpenderFlag[adapter][spender]) {
            _ghost_adapterAllowanceSpenderFlag[adapter][spender] = true;
            _ghost_adapterAllowanceSpenders[adapter].push(spender);
        }
    }

    function _trackAdapterErc6909Id(address adapter, address premiumTkn) internal {
        uint256 id = uint256(uint160(premiumTkn));
        if (_ghost_adapterErc6909IdFlag[adapter][id]) return;
        _ghost_adapterErc6909IdFlag[adapter][id] = true;
        _ghost_adapterErc6909Ids[adapter].push(id);
    }

    function _harvestLogs(address adapterAddr) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == adapterAddr) ghost_adapterEventCount += 1;
        }
    }

    /// @dev In-memory snapshot of every adapter state slot the revert-parity check cares about.
    ///      Captured BEFORE the reverting call; compared AFTER the call returns. No cheatcode-level
    ///      state rollback is used (that would rewind `ghost_atomicDirtyStateFailures` itself).
    struct _AdapterSnapshot {
        uint256[] dstCstBalances;
        uint256[] allowances;
        uint256[] erc6909Balances;
    }

    /// @dev Build a pre-call snapshot of the adapter's observable state: dstCST balances,
    ///      (token, spender) allowances flattened to a linear array with `i*nSpenders + j` index,
    ///      and ERC-6909 balances. Used by `_assertAdapterStateUnchanged` to detect post-revert
    ///      dirty state.
    function _snapshotAdapterState(address adapterAddr) internal view returns (_AdapterSnapshot memory snap) {
        address[] storage dstToks = _ghost_adapterDstCstSeen[adapterAddr];
        snap.dstCstBalances = new uint256[](dstToks.length);
        for (uint256 i; i < dstToks.length; ++i) {
            snap.dstCstBalances[i] = IERC20(dstToks[i]).balanceOf(adapterAddr);
        }

        address[] storage toks = _ghost_adapterAllowanceTokens[adapterAddr];
        address[] storage spenders = _ghost_adapterAllowanceSpenders[adapterAddr];
        snap.allowances = new uint256[](toks.length * spenders.length);
        for (uint256 i; i < toks.length; ++i) {
            for (uint256 j; j < spenders.length; ++j) {
                snap.allowances[i * spenders.length + j] = IERC20(toks[i]).allowance(adapterAddr, spenders[j]);
            }
        }

        uint256[] storage ids = _ghost_adapterErc6909Ids[adapterAddr];
        snap.erc6909Balances = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            snap.erc6909Balances[i] = premium.balanceOf(adapterAddr, ids[i]);
        }
    }

    /// @dev Revert-parity check: after a reverting `execute`, the live adapter state MUST equal the
    ///      pre-call snapshot across every observed slot — dstCST balances, allowances, ERC-6909
    ///      balances. Every divergence increments `ghost_atomicDirtyStateFailures`. No cheatcode
    ///      rollback is used; ghost writes survive the handler action so the invariant driver can
    ///      observe them.
    function _assertAdapterStateUnchanged(address adapterAddr, _AdapterSnapshot memory pre) internal {
        address[] storage dstToks = _ghost_adapterDstCstSeen[adapterAddr];
        for (uint256 i; i < dstToks.length; ++i) {
            if (IERC20(dstToks[i]).balanceOf(adapterAddr) != pre.dstCstBalances[i]) {
                ghost_atomicDirtyStateFailures += 1;
            }
        }

        address[] storage toks = _ghost_adapterAllowanceTokens[adapterAddr];
        address[] storage spenders = _ghost_adapterAllowanceSpenders[adapterAddr];
        for (uint256 i; i < toks.length; ++i) {
            for (uint256 j; j < spenders.length; ++j) {
                if (IERC20(toks[i]).allowance(adapterAddr, spenders[j]) != pre.allowances[i * spenders.length + j]) {
                    ghost_atomicDirtyStateFailures += 1;
                }
            }
        }

        uint256[] storage ids = _ghost_adapterErc6909Ids[adapterAddr];
        for (uint256 i; i < ids.length; ++i) {
            if (premium.balanceOf(adapterAddr, ids[i]) != pre.erc6909Balances[i]) {
                ghost_atomicDirtyStateFailures += 1;
            }
        }
    }

    /// @dev C3 fix: route ~25% of happy-path debitFroms through a third-party subaccount (not the
    ///      resolved caller) so INV-F6 observations aren't restricted to the caller-is-debitor case.
    ///      Picks the subaccount at index `(currentSub + 1) % ACTOR_COUNT` on the third-party path
    ///      for a deterministic, authorised roster member.
    function _selectDebitFrom(address sub, uint256 selector) internal view returns (address) {
        if (selector % 4 != 0) return sub;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            if (subaccounts[i] == sub) {
                return subaccounts[(i + 1) % ACTOR_COUNT];
            }
        }
        return sub;
    }

    /// @dev C1 fix — strengthen INV-F6 for the Exact binding. Post-call observations:
    ///       1. `orderStatus[orderId] == Settled` AND the rollover-leg FillRecord's filler is the
    ///          adapter itself → advance `ghost_settlerObservedAdapterCount`.
    ///       2. Premium ERC-6909 balance of `debitFrom` decreased (or stayed equal for a zero-amount
    ///          premium Output) → advance `ghost_settlerDebitedDebitorCount`.
    function _observeExactSettlerState(
        bytes32 orderId,
        OrderData memory od,
        address debitFrom,
        uint256 premBalBefore,
        address adapter
    ) internal {
        OrderStatus status = exactSettler.orderStatus(orderId);
        bytes32 rolloverOH = LibSettlerHashing.computeOutputHash(od.outputs[0]);
        (address filler,,,) = exactSettler.fillRecords(orderId, rolloverOH);
        if (status == OrderStatus.Settled && filler == adapter) {
            ghost_settlerObservedAdapterCount += 1;
        }
        uint256 premBalAfter = premium.balanceOf(debitFrom, uint256(uint160(od.premiumToken)));
        if (premBalAfter <= premBalBefore) {
            ghost_settlerDebitedDebitorCount += 1;
        }
    }

    /// @dev C1 fix — strengthen INV-F6 for the Partial binding. Post-call observations:
    ///       1. `_fillerRollovers[digest][adapter].srcCstProvided != 0 && .finalised == true` →
    ///          advance `ghost_settlerObservedAdapterCount`. The srcCstProvided field is populated
    ///          inside `fill()` when `msg.sender == targetFiller`, and `finalised` flips in
    ///          `finaliseAsSettled` — combined they are direct evidence the settler saw the adapter
    ///          on both the rollover leg and the finalisation.
    ///       2. Premium ERC-6909 balance monotonicity mirrors the Exact check.
    function _observePartialSettlerState(
        bytes32 digest,
        OrderData memory od,
        address debitFrom,
        uint256 premBalBefore,
        address adapter
    ) internal {
        IPartialFillSettler.FillerRollover memory rec = partialSettler.fillerRollovers(digest, adapter);
        if (rec.srcCstProvided != 0 && rec.finalised) {
            ghost_settlerObservedAdapterCount += 1;
        }
        uint256 premBalAfter = premium.balanceOf(debitFrom, uint256(uint160(od.premiumToken)));
        if (premBalAfter <= premBalBefore) {
            ghost_settlerDebitedDebitorCount += 1;
        }
    }
}
