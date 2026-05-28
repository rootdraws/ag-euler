// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTestFiller} from "test/filler/BaseTestFiller.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH} from "contracts/libs/LibSettlerHashing.sol";

import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {TestMintModule} from "test/harness/TestMintModule.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {AttestationRequest, ModuleType} from "registry/DataTypes.sol";

/// @dev Shape interface: both reference fillers expose an identical `execute(bytes, bytes, bytes,
///      uint256, address, address)` selector. The handler treats them polymorphically through
///      this test-only interface to avoid branching per concrete type on every action.
interface IFillerExecuteShape {
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

/// @title FillerInvariantHandler
/// @notice Invariant fuzz handler for `RolloverFiller` covering INV-F1..F5, F7, F8. Exposes a
///         bounded action surface that drives both the Exact-bound and Partial-bound reference
///         fillers through happy-path and revert-path `execute` calls, tracking ghost state so
///         the paired `FillerInvariant.t.sol` can assert properties across the fuzz campaign.
/// @dev Inherits `BaseTestFiller` to reuse the real settler + cellar + ERC-6909 + Phoenix harness.
///      Each action builds a fresh order per invocation — the Exact settler's per-`orderId`
///      keying and the Partial settler's per-`(digest, filler)` keying both make stale orders
///      unusable after a single happy-path run, so a per-action fresh order is simpler and more
///      realistic than shared order pools. Destination, caller, and third-party addresses are
///      pulled from a fixed roster to keep fuzz seeds deterministic.
contract FillerInvariantHandler is BaseTestFiller {
    // ─── Constants ───────────────────────────────────────────────────────────────────────
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;
    uint256 internal constant ACTOR_COUNT = 4;

    // ─── Shared fixtures (mirror the Exact / Partial test bases) ─────────────────────────
    TestMintModule internal testMintModule;
    DummyERC20 internal premTokenExact;
    DummyERC20 internal dstCstExact;
    DummyERC20 internal premTokenPartial;
    DummyERC20 internal dstCstPartial;

    address[ACTOR_COUNT] internal actors;

    // ─── Ghost state ─────────────────────────────────────────────────────────────────────
    /// @dev Snapshot of caller's srcCST balance immediately before each happy-path action.
    uint256 public ghost_callerSrcCstBefore;
    /// @dev Snapshot of caller's srcCST balance immediately after each happy-path action.
    uint256 public ghost_callerSrcCstAfter;
    /// @dev Cumulative srcCST consumed by successful fills (in the mock harness this is always 0).
    uint256 public ghost_actualRolled;
    /// @dev Cumulative srcCstAmount handed to every happy-path `execute` call.
    uint256 public ghost_srcCstSentSum;
    /// @dev Cumulative (balanceBefore - balanceAfter) observed on the caller across happy paths.
    ///      A positive value means net srcCST left the caller and did NOT return — which should
    ///      equal `ghost_actualRolled` if the filler correctly returns leftover.
    uint256 public ghost_callerNetLossSum;
    /// @dev Set of ERC-20 token addresses the filler has interacted with, for post-run INV-F1 scans.
    address[] public ghost_tokensSeen;
    mapping(address => bool) internal _ghost_tokenSeenFlag;
    /// @dev Set of spender addresses (settlers) the filler may have granted allowance to.
    address[] public ghost_spendersSeen;
    mapping(address => bool) internal _ghost_spenderSeenFlag;
    /// @dev Set of ERC-6909 token-ids the filler could ever transiently hold.
    uint256[] public ghost_erc6909IdsSeen;
    mapping(uint256 => bool) internal _ghost_erc6909IdSeenFlag;
    /// @dev Set of actors who might have been ERC-6909 owners of the filler operator bit.
    address[] public ghost_actorsSeen;
    mapping(address => bool) internal _ghost_actorSeenFlag;
    /// @dev Fillers touched by any action; iterated by the invariant contract.
    address[] public ghost_fillersSeen;
    mapping(address => bool) internal _ghost_fillerSeenFlag;
    /// @dev Count of reverting actions that nevertheless left visible post-state residue on the filler.
    uint256 public ghost_atomicFailures;
    /// @dev Cumulative logs observed whose `emitter == filler`. MUST stay zero for INV-F8.
    uint256 public ghost_fillerEventCount;
    /// @dev INV-F9 (liveness). Count of happy-path `execute` calls that returned normally AND
    ///      observably credited the destination with dstCST. If this stays at zero across a campaign,
    ///      the other invariants are vacuously satisfied (a no-op `execute` trivially passes
    ///      F1/F2/F4/F8) — so the invariant contract asserts `ghost_settledCount > 0` at the end.
    uint256 public ghost_settledCount;
    /// @dev INV-F9 companion. Count of happy-path runs where the destination's dstCST balance
    ///      strictly increased across the `execute`. Must equal `ghost_settledCount` in a sound
    ///      filler; if the happy-path branch succeeds without moving dstCST, it's a silent no-op.
    uint256 public ghost_destinationCreditedCount;
    /// @dev Count of `actionExecuteInsufficient6909` invocations that drove the filler through a
    ///      non-zero premium path and observed the expected `InsufficientBalance` revert. Lets the
    ///      invariant suite prove the action is non-vacuous (P26-A5 / DEDUP-1 / CCP-2).
    uint256 public ghost_insufficient6909Reverted;

    constructor() {
        // setUp is virtual-public on the inherited `Test` chain; run the full harness once here
        // so the handler can be instantiated from another test's setUp.
        setUp();

        testMintModule = new TestMintModule();
        premTokenExact = new DummyERC20("PremExact", "PEX", 18);
        dstCstExact = new DummyERC20("DstExact", "DEX", 18);
        premTokenPartial = new DummyERC20("PremPartial", "PPA", 18);
        dstCstPartial = new DummyERC20("DstPartial", "DPA", 18);

        _registerTestModule(address(testMintModule));

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor-", bytes1(uint8(0x30 + i)))));
            _trackActor(actors[i]);
        }

        _trackFiller(address(rolloverFillerExact));
        _trackFiller(address(rolloverFillerPartial));
        _trackSpender(address(exactSettler));
        _trackSpender(address(partialSettler));
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

    /// @notice Exact-binding happy path. Records leftover ghost deltas and filler event count.
    function actionExecuteExactHappy(uint256 actorSeed, uint256 destSeed) external {
        address act = _selectActor(actorSeed);
        address dest = _selectActor(destSeed);

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildExactOrder(ORDER_SIZE, act);

        _preconditionsExact(
            act,
            IFillerExecuteShape(address(rolloverFillerExact)),
            od.srcCstToken,
            ORDER_SIZE,
            od.premiumToken,
            PREMIUM_DEPOSIT
        );
        _trackToken(od.srcCstToken);
        _trackToken(od.dstCstToken);
        _trackToken(od.premiumToken);
        _trackErc6909Id(od.premiumToken);

        ghost_callerSrcCstBefore = IERC20(od.srcCstToken).balanceOf(act);
        uint256 destDstBefore = IERC20(od.dstCstToken).balanceOf(dest);

        vm.recordLogs();
        vm.prank(act);
        try rolloverFillerExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, act, dest) {
            _harvestLogs(address(rolloverFillerExact));
            ghost_callerSrcCstAfter = IERC20(od.srcCstToken).balanceOf(act);
            uint256 netLoss = ghost_callerSrcCstBefore > ghost_callerSrcCstAfter
                ? ghost_callerSrcCstBefore - ghost_callerSrcCstAfter
                : 0;
            ghost_callerNetLossSum += netLoss;
            ghost_srcCstSentSum += ORDER_SIZE;
            // INV-F9: a successful happy-path `execute` must observably credit the destination
            // with dstCST. A no-op `execute` would succeed here without moving dstCST — the two
            // ghosts let the invariant suite prove liveness.
            ghost_settledCount += 1;
            if (IERC20(od.dstCstToken).balanceOf(dest) > destDstBefore) {
                ghost_destinationCreditedCount += 1;
            }
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice Partial-binding happy path. Same ghost tracking as Exact.
    function actionExecutePartialHappy(uint256 actorSeed, uint256 destSeed) external {
        address act = _selectActor(actorSeed);
        address dest = _selectActor(destSeed);

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildPartialOrder(ORDER_SIZE, act);

        _preconditionsPartial(
            act,
            IFillerExecuteShape(address(rolloverFillerPartial)),
            od.srcCstToken,
            ORDER_SIZE,
            od.premiumToken,
            PREMIUM_DEPOSIT
        );
        _trackToken(od.srcCstToken);
        _trackToken(od.dstCstToken);
        _trackToken(od.premiumToken);
        _trackErc6909Id(od.premiumToken);

        ghost_callerSrcCstBefore = IERC20(od.srcCstToken).balanceOf(act);
        uint256 destDstBefore = IERC20(od.dstCstToken).balanceOf(dest);

        vm.recordLogs();
        vm.prank(act);
        try rolloverFillerPartial.execute(abi.encode(order), sig, ofd, ORDER_SIZE, act, dest) {
            _harvestLogs(address(rolloverFillerPartial));
            ghost_callerSrcCstAfter = IERC20(od.srcCstToken).balanceOf(act);
            uint256 netLoss = ghost_callerSrcCstBefore > ghost_callerSrcCstAfter
                ? ghost_callerSrcCstBefore - ghost_callerSrcCstAfter
                : 0;
            ghost_callerNetLossSum += netLoss;
            ghost_srcCstSentSum += ORDER_SIZE;
            // INV-F9: see Exact-side comment.
            ghost_settledCount += 1;
            if (IERC20(od.dstCstToken).balanceOf(dest) > destDstBefore) {
                ghost_destinationCreditedCount += 1;
            }
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice `destination == address(0)` — filler's own guard fires. INV-F7 revert parity.
    function actionExecuteZeroDestination(uint256 actorSeed, uint256 fillerSeed) external {
        address act = _selectActor(actorSeed);
        bool useExact = (fillerSeed & 1) == 0;
        IFillerExecuteShape filler = useExact
            ? IFillerExecuteShape(address(rolloverFillerExact))
            : IFillerExecuteShape(address(rolloverFillerPartial));

        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder(ORDER_SIZE, act) : _buildPartialOrder(ORDER_SIZE, act);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(act);
        try filler.execute(abi.encode(order), sig, ofd, ORDER_SIZE, act, address(0)) {
            vm.getRecordedLogs();
            ghost_atomicFailures += 1;
        } catch {
            _assertAtomicRevertParity(address(filler), snap);
            _harvestLogs(address(filler));
        }
    }

    /// @notice Happy-path variant with `srcCstAmount > ORDER_SIZE`. Verifies overfund leftover-return.
    function actionExecuteOverfund(uint256 actorSeed, uint256 destSeed, uint256 overfundSeed) external {
        address act = _selectActor(actorSeed);
        address dest = _selectActor(destSeed);
        uint256 overfund = ORDER_SIZE + bound(overfundSeed, 1, 100e18);

        bool useExact = (overfundSeed & 1) == 0;
        IFillerExecuteShape filler = useExact
            ? IFillerExecuteShape(address(rolloverFillerExact))
            : IFillerExecuteShape(address(rolloverFillerPartial));
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder(ORDER_SIZE, act) : _buildPartialOrder(ORDER_SIZE, act);

        if (useExact) {
            _preconditionsExact(act, filler, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);
        } else {
            _preconditionsPartial(act, filler, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);
        }
        _trackToken(od.srcCstToken);
        _trackToken(od.dstCstToken);
        _trackToken(od.premiumToken);
        _trackErc6909Id(od.premiumToken);

        ghost_callerSrcCstBefore = IERC20(od.srcCstToken).balanceOf(act);
        uint256 destDstBefore = IERC20(od.dstCstToken).balanceOf(dest);

        vm.recordLogs();
        vm.prank(act);
        try filler.execute(abi.encode(order), sig, ofd, overfund, act, dest) {
            _harvestLogs(address(filler));
            ghost_callerSrcCstAfter = IERC20(od.srcCstToken).balanceOf(act);
            uint256 netLoss = ghost_callerSrcCstBefore > ghost_callerSrcCstAfter
                ? ghost_callerSrcCstBefore - ghost_callerSrcCstAfter
                : 0;
            ghost_callerNetLossSum += netLoss;
            ghost_srcCstSentSum += overfund;
            // INV-F9: see Exact-side comment on actionExecuteExactHappy.
            ghost_settledCount += 1;
            if (IERC20(od.dstCstToken).balanceOf(dest) > destDstBefore) {
                ghost_destinationCreditedCount += 1;
            }
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice Skip ERC-6909 deposit + force `minPremiumPerShare = 1e18` so the premium leg
    ///         actually debits — the settler's premium settle hits `InsufficientBalance` on a
    ///         zero ERC-6909 balance and the whole `execute` reverts atomically. Drives the
    ///         live mid-`execute` revert path for INV-F7 (P26-A5 / DEDUP-1 / CCP-2).
    function actionExecuteInsufficient6909(uint256 actorSeed, uint256 destSeed, uint256 fillerSeed) external {
        address act = _selectActor(actorSeed);
        address dest = _selectActor(destSeed);

        bool useExact = (fillerSeed & 1) == 0;
        IFillerExecuteShape filler = useExact
            ? IFillerExecuteShape(address(rolloverFillerExact))
            : IFillerExecuteShape(address(rolloverFillerPartial));
        address boundSettler = filler.SETTLER();

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder(ORDER_SIZE, act) : _buildPartialOrder(ORDER_SIZE, act);

        // Bump premium-per-share to force a non-zero settle. Digest / intent hash / maker sig all
        // depend on `od.minPremiumPerShare`, so rebuild intent → re-hash → re-sign the cellar
        // intent and the order. Without this the action stays vacuous: the default-zero premium
        // makes the debit zero, and `InsufficientBalance` never fires.
        od.minPremiumPerShare = 1e18;
        bytes32 newDigest = LibSettlerHashing.computeOrderDigest(boundSettler, order, od);
        CellarIntent memory newIntent =
            _buildIntent(newDigest, boundSettler, ORDER_SIZE, !useExact, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(newIntent));
        od.cellarSignature = _signCellarIntent(newIntent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);
        sig = useExact ? _signOrderExact(order) : _signOrderPartial(order);

        // Mint srcCST + approve filler, authorise settler + filler as ERC-6909 operators, but
        // SKIP the ERC-6909 premium deposit. With minPremiumPerShare=1e18 the premium leg debits
        // `ORDER_SIZE * 1 = ORDER_SIZE` units from an empty balance → `InsufficientBalance`.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", act, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(act, address(filler), od.srcCstToken, ORDER_SIZE);
        vm.startPrank(act);
        premium.setOperator(boundSettler, true);
        premium.setOperator(address(filler), true);
        vm.stopPrank();

        _trackToken(od.srcCstToken);
        _trackToken(od.dstCstToken);
        _trackToken(od.premiumToken);
        _trackErc6909Id(od.premiumToken);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(act);
        try filler.execute(abi.encode(order), sig, ofd, ORDER_SIZE, act, dest) {
            _harvestLogs(address(filler));
        } catch {
            _assertAtomicRevertParity(address(filler), snap);
            _harvestLogs(address(filler));
            ghost_insufficient6909Reverted += 1;
        }
    }

    /// @notice `destination` is a contract whose fallback reverts. Currently a no-op on plain
    ///         ERC-20 transfers (no recipient callback) — kept for future hook-token coverage.
    ///         Any revert is expected and verified via INV-F7.
    function actionExecuteRevertingDestination(uint256 actorSeed, uint256 fillerSeed) external {
        address act = _selectActor(actorSeed);
        RevertingDestination rd = new RevertingDestination();

        bool useExact = (fillerSeed & 1) == 0;
        IFillerExecuteShape filler = useExact
            ? IFillerExecuteShape(address(rolloverFillerExact))
            : IFillerExecuteShape(address(rolloverFillerPartial));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            useExact ? _buildExactOrder(ORDER_SIZE, act) : _buildPartialOrder(ORDER_SIZE, act);

        if (useExact) {
            _preconditionsExact(act, filler, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        } else {
            _preconditionsPartial(act, filler, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        }
        _trackToken(od.srcCstToken);
        _trackToken(od.dstCstToken);
        _trackToken(od.premiumToken);
        _trackErc6909Id(od.premiumToken);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(act);
        try filler.execute(abi.encode(order), sig, ofd, ORDER_SIZE, act, address(rd)) {
            _harvestLogs(address(filler));
        } catch {
            _assertAtomicRevertParity(address(filler), snap);
            _harvestLogs(address(filler));
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Ghost array length getters (public storage arrays auto-expose indexers)
    // ═══════════════════════════════════════════════════════════════

    function ghostTokensSeenLen() external view returns (uint256) {
        return ghost_tokensSeen.length;
    }

    function ghostSpendersSeenLen() external view returns (uint256) {
        return ghost_spendersSeen.length;
    }

    function ghostErc6909IdsSeenLen() external view returns (uint256) {
        return ghost_erc6909IdsSeen.length;
    }

    function ghostActorsSeenLen() external view returns (uint256) {
        return ghost_actorsSeen.length;
    }

    function ghostFillersSeenLen() external view returns (uint256) {
        return ghost_fillersSeen.length;
    }

    /// @notice Expose the ERC-6909 premium contract so the invariant test can call `balanceOf`
    ///         and `isOperator` without needing to reach into the inherited `internal` field.
    function premiumContract() external view returns (address) {
        return address(premium);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal helpers — order construction
    // ═══════════════════════════════════════════════════════════════

    function _buildExactOrder(uint256 orderSize, address repaymentTo)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            bytes memory signature,
            bytes memory originFillerData
        )
    {
        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(user, orderSize, false, false, address(exactSettler));

        od.dstCstToken = address(dstCstExact);
        od.premiumToken = address(premTokenExact);
        od.outputs = _twoOutputs(address(dstCstExact), address(premTokenExact), orderSize, user.addr);

        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCstExact));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), orderSize, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        signature = _signOrderExact(order);
        originFillerData = _buildOriginFillerData(orderSize, repaymentTo);
    }

    function _buildPartialOrder(uint256 orderSize, address repaymentTo)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            bytes memory signature,
            bytes memory originFillerData
        )
    {
        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(user, orderSize, true, false, address(partialSettler));

        od.dstCstToken = address(dstCstPartial);
        od.premiumToken = address(premTokenPartial);
        od.outputs = _twoOutputs(address(dstCstPartial), address(premTokenPartial), orderSize, user.addr);

        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCstPartial));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), orderSize, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        signature = _signOrderPartial(order);
        originFillerData = _buildOriginFillerData(orderSize, repaymentTo);
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

    function _preconditionsExact(
        address actor,
        IFillerExecuteShape filler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareFillerState(
            actor, ExactRolloverFiller(address(filler)), srcCstToken, srcCstAmount, premiumToken, premiumAmount
        );
        vm.prank(actor);
        premium.setOperator(address(filler), true);
    }

    function _preconditionsPartial(
        address actor,
        IFillerExecuteShape filler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareFillerState(
            actor, PartialRolloverFiller(address(filler)), srcCstToken, srcCstAmount, premiumToken, premiumAmount
        );
        vm.prank(actor);
        premium.setOperator(address(filler), true);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal helpers — ghost tracking + atomic-revert parity
    // ═══════════════════════════════════════════════════════════════

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _trackToken(address token) internal {
        if (_ghost_tokenSeenFlag[token]) return;
        _ghost_tokenSeenFlag[token] = true;
        ghost_tokensSeen.push(token);
    }

    function _trackSpender(address spender) internal {
        if (_ghost_spenderSeenFlag[spender]) return;
        _ghost_spenderSeenFlag[spender] = true;
        ghost_spendersSeen.push(spender);
    }

    function _trackErc6909Id(address premiumTkn) internal {
        uint256 id = uint256(uint160(premiumTkn));
        if (_ghost_erc6909IdSeenFlag[id]) return;
        _ghost_erc6909IdSeenFlag[id] = true;
        ghost_erc6909IdsSeen.push(id);
    }

    function _trackActor(address act) internal {
        if (_ghost_actorSeenFlag[act]) return;
        _ghost_actorSeenFlag[act] = true;
        ghost_actorsSeen.push(act);
    }

    function _trackFiller(address f) internal {
        if (_ghost_fillerSeenFlag[f]) return;
        _ghost_fillerSeenFlag[f] = true;
        ghost_fillersSeen.push(f);
    }

    function _harvestLogs(address fillerAddr) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == fillerAddr) ghost_fillerEventCount += 1;
        }
    }

    /// @dev Revert-action parity: after a reverting `execute`, the filler MUST hold no tokens,
    ///      no non-zero allowance, and no ERC-6909 balance. `vm.revertToState` rewinds any benign
    ///      side-effects of the reverting call for subsequent actions.
    function _assertAtomicRevertParity(address fillerAddr, uint256 snap) internal {
        for (uint256 i; i < ghost_tokensSeen.length; ++i) {
            address tkn = ghost_tokensSeen[i];
            if (IERC20(tkn).balanceOf(fillerAddr) != 0) ghost_atomicFailures += 1;
            if (IERC20(tkn).allowance(fillerAddr, address(exactSettler)) != 0) ghost_atomicFailures += 1;
            if (IERC20(tkn).allowance(fillerAddr, address(partialSettler)) != 0) ghost_atomicFailures += 1;
        }
        for (uint256 i; i < ghost_erc6909IdsSeen.length; ++i) {
            if (premium.balanceOf(fillerAddr, ghost_erc6909IdsSeen[i]) != 0) ghost_atomicFailures += 1;
        }
        vm.revertToState(snap);
    }
}

/// @dev Minimal destination contract whose fallback reverts; used by
///      `actionExecuteRevertingDestination`. Vanilla ERC-20 does not invoke a recipient callback,
///      so this is a latent guard for future hook-token coverage rather than a live revert driver.
contract RevertingDestination {
    error ForcedRevertingDestination();

    fallback() external payable {
        revert ForcedRevertingDestination();
    }

    receive() external payable {}
}
