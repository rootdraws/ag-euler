// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseSettler} from "contracts/settlers/BaseSettler.sol";
import {
    DisproportionateOutput,
    CellarNotBound,
    ZeroRollover,
    StateDivergence
} from "contracts/settlers/BaseSettlerErrors.sol";
import {ICorkCellarPremiumView} from "contracts/interfaces/ICorkCellarPremiumView.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {
    OrderStatus,
    NotMaker,
    InvalidOrderTokenPair,
    InconsistentIntent,
    InvalidOrderStatus,
    OrderInTerminalState,
    IntentNotBoundToOrder,
    DigestMismatch,
    NotExpired,
    OrderHasFills,
    InvalidOriginFillerData
} from "contracts/interfaces/RolloverTypes.sol";
import {OrderData, OriginFillerData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibRolloverOrder} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {CorkCellarFactory} from "cellar/CorkCellarFactory.sol";

contract ExactFillSettler is BaseSettler, IExactFillSettler {
    using SafeERC20 for IERC20;

    /// @notice Per-order rollover fill record.
    /// @dev `dstCstProduced` is `uint256` (PR 3 / #53) — previously `uint128`, which silently
    ///      narrowed on large rolls. Unified with `PartialFillSettler.FillerRollover.dstCstProduced`
    ///      on the same `uint256` width; the common view shape is `BaseSettler.FillerEscrow`.
    struct FillRecord {
        address filler;
        address destination;
        uint256 dstCstProduced;
        uint64 filledAt;
    }

    mapping(bytes32 orderId => mapping(bytes32 outputHash => FillRecord)) public fillRecords;
    mapping(bytes32 orderId => bool) public paymentSettled;
    mapping(bytes32 orderId => address) public repaymentTo;
    mapping(bytes32 orderId => address) public dstCstToken;
    mapping(bytes32 orderId => address) public cellarOf;

    mapping(bytes32 orderId => bytes32) internal _rolloverOutputHash;

    /// @notice Cached order binding digest for an Exact order — populated on the rollover-leg fill
    ///         and read at `finaliseAsSettled` to resolve `premiumFiredFor(orderDigest, filler)`
    ///         for the `OrderAttribution` event's `cellarFiller` field. Exact's state is otherwise
    ///         `orderId`-keyed (single-participant), so the digest is not needed for core lookups;
    ///         this slot is a lookup-cache to avoid reconstructing the digest at finalise time
    ///         (which would require re-passing the full `GaslessCrossChainOrder`, breaking the
    ///         `finaliseAsSettled(bytes32)` entry signature).
    mapping(bytes32 orderId => bytes32) internal _orderDigestOf;

    /// @notice Cached `premiumToken` per Exact order — populated on the premium-leg fill alongside
    ///         `_orderDigestOf` and read at `finaliseAsSettled` to emit the ERC-6909 ledger token
    ///         identity (`uint256(uint160(premiumToken))`) on `OrderAttribution.tokenId`. Closes
    ///         cycle-1 C1 (#47 join-intent): the attribution event now carries the same id that
    ///         `ERC6909Premium.settle` emits, enabling a three-way join across settler event,
    ///         cellar hook, and ERC-6909 settlement emissions. The slot is written pre-forward in
    ///         `_onPremiumLegFill` so both the success and catch branches surface a valid token
    ///         identity to the finalise-time emitter.
    mapping(bytes32 orderId => address) internal _premiumTokenOf;

    /// @notice dstCST credited for a `(orderId, filler)` pair when the `finaliseAsSettled`
    ///         payout transfer to the filler's destination reverted (e.g. blacklist-style tokens
    ///         like USDC with a non-compliant destination). The order still transitions
    ///         `Opened → Settled` so the lifecycle progresses; PR 6's `rescueSettled` entry point
    ///         reads this mapping to let the filler withdraw to a new destination. Zero amounts
    ///         are never booked.
    mapping(bytes32 orderId => mapping(address filler => uint256)) private _rescueable;

    constructor(address factory_, address erc6909Premium_) BaseSettler(factory_, erc6909Premium_) {}

    // ═══════════════════════════════════════════════════════════════
    //  open (override Base — onchain path)
    // ═══════════════════════════════════════════════════════════════

    function open(OnchainCrossChainOrder calldata order) external override(BaseSettler, IOriginSettler) {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        if (msg.sender != od.receiver) revert NotMaker();
        _validateOpen(od);

        GaslessCrossChainOrder memory synth = _toGasless(order);
        bytes32 orderId = _hashOrder(synth);

        OrderStatus status = orderStatus[orderId];
        if (status == OrderStatus.Opened) return;
        if (status != OrderStatus.None) revert InvalidOrderStatus();

        cellarOf[orderId] = CorkCellarFactory(factory).cellarOf(msg.sender);
        orderStatus[orderId] = OrderStatus.Opened;
        emit Open(orderId, _buildResolved(synth, od, 0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  resolve (override Base — onchain path)
    // ═══════════════════════════════════════════════════════════════

    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        override(BaseSettler, IOriginSettler)
        returns (ResolvedCrossChainOrder memory)
    {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _validateOpen(od);
        return _buildResolved(_toGasless(order), od, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  resolveFor (override Base — add validation)
    // ═══════════════════════════════════════════════════════════════

    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        override(BaseSettler, IOriginSettler)
        returns (ResolvedCrossChainOrder memory resolved)
    {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _validateOpen(od);
        resolved = _resolveFor(order, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  finaliseAsSettled
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc IExactFillSettler
    /// @dev Cycle-1 C2: the cellar `premiumFiredFor` view read is wrapped in `try/catch` so a
    ///      reverting or gas-griefing cellar cannot permanently strand dstCST at finalise. On any
    ///      caught revert `cellarFiller` falls back to `address(0)` — drift signal for off-chain
    ///      consumers, consistent with the "cellar never latched" semantic on the premium-hook
    ///      catch branch.
    function finaliseAsSettled(bytes32 orderId) external override nonReentrant {
        if (orderStatus[orderId] != OrderStatus.Opened) {
            revert InvalidOrderStatus();
        }
        if (!paymentSettled[orderId]) revert PaymentNotSettled();

        // Shared read primitive (PR 3 — Task 8 wiring, cycle-1 C1). The Exact override maps from
        // `fillRecords[orderId][_rolloverOutputHash[orderId]]` — the canonical single-participant
        // rollover entry. `filler` argument is ignored by the Exact override.
        FillerEscrow memory escrow = _lookupFillerEscrow(orderId, address(0));
        if (escrow.filledAt == 0) revert InvalidFillRecord();

        orderStatus[orderId] = OrderStatus.Settled;
        emit OrderFinalised(orderId, OrderStatus.Settled, bytes32(0));

        // Blacklist-safe (Task 17 / closes #39 payout branch): on a transfer revert (e.g. USDC
        // blacklisted destination) the order is already `Settled` above, so the lifecycle is
        // not stuck; the amount is booked on `_rescueable[orderId][filler]` and
        // `FillerRescueCredited` is emitted for later withdrawal via PR 6's `rescueSettled`
        // entry point. The transfer is routed through the shared `externalSafeTransfer`
        // trampoline on `BaseSettler` so `SafeERC20` reverts are catchable as `bytes memory`
        // reason (Solidity's `try` cannot wrap in-contract calls).
        //
        // Task 36 (#47) — emit `OrderAttribution` immediately BEFORE the transfer. On Exact
        // `fillerSlot == premiumFiller == rolloverRec.filler` (single-participant by
        // construction); `cellarFiller` resolves to the same filler on the `_onPremiumLegFill`
        // success branch (cellar latched `premiumFiredFor`) and to zero on the catch branch
        // (hook reverted, cellar never latched).
        // Cycle-1 C2 — the cellar view call is wrapped in `try/catch` so a reverting / gas-griefing
        // cellar cannot strand dstCST at finalise. A caught revert resolves `cellarFiller` to
        // `address(0)` — the event's purpose is drift detection, and a reverting cellar IS drift.
        address token = dstCstToken[orderId];
        if (escrow.dstCstProduced > 0) {
            emit OrderAttribution(
                orderId,
                escrow.filler,
                escrow.filler,
                _cellarFillerOf(cellarOf[orderId], _orderDigestOf[orderId], escrow.filler),
                uint256(uint160(_premiumTokenOf[orderId])),
                escrow.dstCstProduced
            );
            try this.externalSafeTransfer(token, escrow.destination, escrow.dstCstProduced) {}
            catch (bytes memory reason) {
                _rescueable[orderId][escrow.filler] += escrow.dstCstProduced;
                emit FillerRescueCredited(orderId, escrow.filler, escrow.dstCstProduced, reason);
            }

            // Task 37 (#46) — balance-floor invariant. On Exact the residual-escrow floor is
            // zero by construction (single-participant, single-payout) so an explicit
            // `balanceOf(settler) >= 0` assertion would be dead code (uint256 comparison).
            // The payout catch branch keeps the funds on the settler as `_rescueable` credit;
            // the token-choreography table on `BaseSettler` documents which party holds what at
            // finalise time. Partial carries the active assertion for the multi-filler residual.
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  finaliseAsRefunded
    // ═══════════════════════════════════════════════════════════════

    function finaliseAsRefunded(bytes32 orderId, GaslessCrossChainOrder calldata order) external override nonReentrant {
        if (_hashOrder(order) != orderId) revert DigestMismatch();
        if (block.timestamp <= order.fillDeadline) revert NotExpired();

        OrderStatus status = orderStatus[orderId];
        if (status != OrderStatus.Opened) revert InvalidOrderStatus();
        if (paymentSettled[orderId]) revert OrderComplete();

        orderStatus[orderId] = OrderStatus.Refunded;
        emit OrderFinalised(orderId, OrderStatus.Refunded, bytes32(0));

        // Shared read primitive (PR 3 — Task 8 wiring, cycle-1 C1). The Exact override maps from
        // `fillRecords[orderId][_rolloverOutputHash[orderId]]` and reports `false` for Partial-only
        // latches — harmless here because this path only reads `filledAt` and `dstCstProduced`.
        FillerEscrow memory escrow = _lookupFillerEscrow(orderId, address(0));
        if (escrow.filledAt != 0 && escrow.dstCstProduced > 0) {
            IERC20(dstCstToken[orderId]).safeTransfer(cellarOf[orderId], escrow.dstCstProduced);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  rescueSettled (PR 6 — closes #44)
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc IExactFillSettler
    /// @dev Thin external wrapper — `nonReentrant` on the entry point; the shared core on
    ///      `BaseSettler._rescueSettled` runs sig verification, CEI zeroing via
    ///      `_consumeRescueable`, and the dstCST transfer. Exact's `_rescueable` is keyed by
    ///      `orderId` so `orderDigest` is only carried for the EIP-712 pre-image.
    function rescueSettled(
        bytes32 orderDigest,
        bytes32 orderId,
        address filler,
        address fallbackDestination,
        bytes calldata sig
    ) external override nonReentrant {
        address token = dstCstToken[orderId];
        uint256 amount = _rescueSettled(orderDigest, orderId, filler, fallbackDestination, sig, token);
        emit FillerRescueWithdrawn(orderId, filler, fallbackDestination, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //  finaliseAsCancelled
    // ═══════════════════════════════════════════════════════════════

    function finaliseAsCancelled(bytes32 orderId, GaslessCrossChainOrder calldata order, bytes calldata cancelSig)
        external
        override
        nonReentrant
    {
        if (_hashOrder(order) != orderId) revert DigestMismatch();
        if (orderStatus[orderId] != OrderStatus.Opened) {
            revert InvalidOrderStatus();
        }

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        bytes32 roh = LibSettlerHashing.computeOutputHash(od.outputs[0]);
        bytes32 poh = LibSettlerHashing.computeOutputHash(od.outputs[1]);
        if (fillRecords[orderId][roh].filledAt != 0 || fillRecords[orderId][poh].filledAt != 0) {
            revert OrderHasFills();
        }

        if (msg.sender != order.user) {
            _recoverCancel(orderId, cancelSig, order.user);
        }

        orderStatus[orderId] = OrderStatus.Cancelled;
        emit OrderFinalised(orderId, OrderStatus.Cancelled, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Rescue-view
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc BaseSettler
    /// @dev Exact keys rescueable credits by `(orderId, filler)` — single-participant; `filler`
    ///      is the rollover-leg filler recorded on `fillRecords[orderId][rolloverOutputHash]`.
    function rescueableOf(bytes32 orderId, address filler) external view override returns (uint256) {
        return _rescueable[orderId][filler];
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact keys `_rescueable` by `orderId` — the first `orderDigest` parameter is the
    ///      EIP-712 pre-image carrier and is ignored here.
    function _consumeRescueable(
        bytes32,
        /* orderDigest */
        bytes32 orderId,
        address filler
    )
        internal
        override
        returns (uint256 amount)
    {
        amount = _rescueable[orderId][filler];
        if (amount != 0) {
            _rescueable[orderId][filler] = 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Shared-primitive overrides (PR 3 — Task 8)
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc BaseSettler
    /// @dev Exact is single-participant — `orderKey == orderId`. Writes into
    ///      `fillRecords[orderId][_rolloverOutputHash[orderId]]` so the entry is discoverable via
    ///      the same `(orderId, outputHash)` key the finalise path reads. Caller MUST have already
    ///      populated `_rolloverOutputHash[orderId]` for the write to hit the canonical slot.
    function _recordFillerEscrow(
        bytes32 orderKey,
        address filler,
        uint256, /* srcCstProvided — Exact does not store this field */
        uint256 dstCstProduced,
        address destination
    ) internal override {
        bytes32 outputHash = _rolloverOutputHash[orderKey];
        fillRecords[orderKey][outputHash] = FillRecord({
            filler: filler, destination: destination, dstCstProduced: dstCstProduced, filledAt: uint64(block.timestamp)
        });
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact is single-participant — `orderKey == orderId`. The `filler` argument is ignored:
    ///      every Exact order has exactly one rollover-leg record, keyed by
    ///      `(orderId, _rolloverOutputHash[orderId])`.
    function _lookupFillerEscrow(
        bytes32 orderKey,
        address /* filler */
    )
        internal
        view
        override
        returns (FillerEscrow memory escrow)
    {
        bytes32 outputHash = _rolloverOutputHash[orderKey];
        FillRecord memory rec = fillRecords[orderKey][outputHash];
        escrow = FillerEscrow({
            filler: rec.filler,
            destination: rec.destination,
            srcCstProvided: 0,
            dstCstProduced: rec.dstCstProduced,
            filledAt: rec.filledAt,
            premiumSettled: paymentSettled[orderKey],
            finalised: false,
            refunded: false
        });
    }

    // ═══════════════════════════════════════════════════════════════
    //  Virtual hook overrides
    // ═══════════════════════════════════════════════════════════════

    function _validateOpen(OrderData memory od) internal pure override {
        if (od.srcCstToken == od.premiumToken) {
            revert InvalidOrderTokenPair();
        }
        if (od.allowPartialFills) revert InconsistentIntent();
    }

    function _validateOriginFillerData(bytes calldata originFillerData) internal pure override {
        if (originFillerData.length == 0) {
            revert InvalidOriginFillerData();
        }
    }

    function _onOpenForDecoded(bytes32 orderId, OriginFillerData memory fd) internal override {
        repaymentTo[orderId] = fd.repaymentTo;
    }

    function _onOpenTransitionToOpened(bytes32 orderId, bytes32, address user_) internal override {
        cellarOf[orderId] = CorkCellarFactory(factory).cellarOf(user_);
    }

    function _onRolloverLegFill(
        GaslessCrossChainOrder memory order,
        OrderData memory od,
        Output memory output,
        bytes calldata legData
    ) internal override {
        if (output.amount != od.orderSize) revert PartialFillNotAllowed();

        bytes32 orderId = _hashOrder(order);
        bytes32 outputHash = LibSettlerHashing.computeOutputHash(output);
        if (fillRecords[orderId][outputHash].filledAt != 0) {
            revert AlreadyFilled();
        }

        (CellarIntent memory intent, bytes memory cellarSig) =
            LibRolloverOrder.extractCellarIntentFromOrderData(od, order, address(this), factory);
        if (keccak256(abi.encode(intent)) != od.cellarIntentHash) {
            revert IntentNotBoundToOrder();
        }

        RolloverFillerData memory rfd = LibRolloverOrder.decodeRolloverFillerData(legData);
        _requireDestination(rfd.destination);
        address cellar = cellarOf[orderId];

        IERC20 dstCst = IERC20(od.dstCstToken);
        IERC20 srcCst = IERC20(od.srcCstToken);
        uint256 dstBefore = dstCst.balanceOf(address(this));
        uint256 srcBefore = srcCst.balanceOf(address(this));

        uint256 actualRolled =
            _forwardToFactory(cellar, intent.orderDigest, 0, intent, cellarSig, output.amount, msg.sender);
        // Symmetric with `PartialFillSettler._onRolloverLegFill`: defense-in-depth against a
        // slot-squatting cellar that signals success but rolls zero principal (Pashov A6).
        if (actualRolled == 0) revert ZeroRollover();

        uint256 dstDelta = dstCst.balanceOf(address(this)) - dstBefore;
        uint256 srcLeftover = srcCst.balanceOf(address(this)) - srcBefore;

        if (dstDelta + 1 < output.amount - srcLeftover) {
            revert DisproportionateOutput();
        }

        dstCstToken[orderId] = od.dstCstToken;
        _rolloverOutputHash[orderId] = outputHash;
        // PR 3 / #53 — `dstCstProduced` is `uint256` in both settlers; no narrowing cast.
        // Shared write primitive (PR 3 — Task 8 wiring, cycle-1 C1). The Exact override routes
        // the write into `fillRecords[orderId][outputHash]` via the `_rolloverOutputHash[orderId]`
        // entry set above — ordering is load-bearing.
        _recordFillerEscrow(orderId, msg.sender, output.amount, dstDelta, rfd.destination);

        if (srcLeftover > 0) {
            srcCst.safeTransfer(msg.sender, srcLeftover);
        }

        emit Fill(orderId, 0, outputHash, msg.sender);
    }

    /// @dev AS-10 / #58 + I3 / #60 — the phase-1 cellar callback is isolated in a try/catch so
    ///      UW-controlled premium hooks cannot brick the filler's settle path. The ERC-6909 debit
    ///      via `_settlePremium` stays BEFORE the forward because the forward reads the debited
    ///      state. The `paymentSettled[orderId]` latch and the premium-leg `FillRecord` now flip
    ///      AFTER the forward in BOTH branches (success and catch) — mirroring the
    ///      forward-then-write convention already used on `_onRolloverLegFill`. End-state is
    ///      identical to PR 7: the latch is `true` and the premium-leg `FillRecord` is populated
    ///      whether the hooks succeed or revert. On revert the premium tokens sit at the cellar;
    ///      the UW owner recovers them out-of-band via `executeHooks(Call[])`.
    /// @dev The premium-leg `FillRecord` write lives in BOTH try-success and catch branches to
    ///      preserve the `AlreadyFilled` guard (line 406) across caught reverts: dropping the
    ///      catch-branch write would allow a duplicate premium fill after a caught phase-1
    ///      revert. This extends plan Task 28 (which named only the latch) with the same CEI
    ///      rationale; end-state matches PR 7.
    function _onPremiumLegFill(
        GaslessCrossChainOrder memory order,
        OrderData memory od,
        Output memory,
        bytes calldata legData
    ) internal override {
        bytes32 orderId = _hashOrder(order);
        bytes32 rolloverOH = LibSettlerHashing.computeOutputHash(od.outputs[0]);
        bytes32 premiumOH = LibSettlerHashing.computeOutputHash(od.outputs[1]);

        if (fillRecords[orderId][rolloverOH].filledAt == 0) {
            revert PremiumBeforeRollover();
        }
        if (fillRecords[orderId][premiumOH].filledAt != 0) {
            revert AlreadyFilled();
        }

        PremiumFillerData memory pfd = LibRolloverOrder.decodePremiumFillerData(legData);
        _requireDebitFromAuthorized(pfd.debitFrom);

        FillRecord memory rolloverRec = fillRecords[orderId][rolloverOH];
        uint256 premium = Math.mulDiv(rolloverRec.dstCstProduced, od.minPremiumPerShare, 1e18, Math.Rounding.Ceil);

        address cellar = cellarOf[orderId];
        if (cellar == address(0)) revert CellarNotBound();

        uint256 tokenId = uint256(uint160(od.premiumToken));
        _settlePremium(tokenId, premium, pfd.debitFrom, msg.sender, cellar);

        (CellarIntent memory intent, bytes memory cellarSig) =
            LibRolloverOrder.extractCellarIntentFromOrderData(od, order, address(this), factory);
        if (keccak256(abi.encode(intent)) != od.cellarIntentHash) {
            revert IntentNotBoundToOrder();
        }

        // #63 / Integ M1 — publish the settler-side filler identity to the `PREMIUM_FILLER_SLOT`
        // transient slot BEFORE forwarding. On Exact, the canonical filler for the premium-phase
        // forward is the rollover-leg filler (`rolloverRec.filler`), matching the `filler` arg
        // the settler passes to `executeIntentHooks`. The cellar's `_runPremiumPhase` reads this
        // slot via `tload` to cross-check the filler identity against the factory-relayed arg,
        // closing the seam where the cellar would otherwise have to trust the factory blindly.
        // Written post-debit-pre-forward; transient — no clean-up required.
        bytes32 slot = PREMIUM_FILLER_SLOT;
        address _filler = rolloverRec.filler;
        assembly {
            tstore(slot, _filler)
        }

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(this), order, od);
        // Task 36 cache (#47) — persist the digest so `finaliseAsSettled` can resolve the cellar's
        // `premiumFiredFor(digest, filler)` view for the `OrderAttribution.cellarFiller` field
        // without re-passing the `GaslessCrossChainOrder`. Written pre-forward so the catch
        // branch also surfaces a valid digest to the attribution event emitter.
        _orderDigestOf[orderId] = orderDigest;
        // Cycle-1 C1 (#47) — cache the `premiumToken` alongside the digest so `finaliseAsSettled`
        // can emit the ERC-6909 ledger identity on `OrderAttribution.tokenId` without re-passing
        // the order. Pre-forward write mirrors the digest cache so both commit regardless of the
        // hook branch taken.
        _premiumTokenOf[orderId] = od.premiumToken;

        // AS-10 / #58 + I3 / #60 — isolate UW-controlled phase-1 hooks, with forward-then-write
        // ordering symmetric to `_onRolloverLegFill`. `paymentSettled[orderId]` and the premium-leg
        // `FillRecord` flip AFTER the forward in BOTH branches: end-state is identical to PR 7
        // whether the hooks succeed or revert. On revert we emit the signal event; `finaliseAsSettled`
        // can still progress because both commits are set. The premium sits at the cellar; UW owner
        // recovers it via `executeHooks`. `orderDigest` matches the Partial event signature — use
        // the Exact digest reconstructed via `LibSettlerHashing.computeOrderDigest` so off-chain
        // observers can correlate the event with the order even though Exact state is `orderId`-keyed.
        // NatSpec note: on Exact, the emitted `targetFiller` is always the rollover-leg filler
        // (`rolloverRec.filler`), which may differ from `msg.sender` of the premium-leg fill.
        // The RFC permits a third party to post the premium; the informative "stranded" party
        // whose bookkeeping is committed at catch time is the rollover-leg filler, not the
        // premium-leg poster.
        //
        // #61 / I4 — on the success branch, cross-check `premiumFiredFor[orderDigest][rolloverRec.filler]`
        // on the cellar. The forward is supposed to flip that latch inside `_runPremiumPhase`; if it
        // returns success without doing so, settler and cellar state have diverged. Revert with
        // `StateDivergence` so the settler-side latch is NOT committed on top of a cellar that
        // never latched. On the catch branch the hook didn't run — the cellar was never expected
        // to latch, so no assertion is made.
        try ICorkCellarFactory(factory)
            .executeIntentHooks(cellar, intent.orderDigest, 1, intent, cellarSig, 0, rolloverRec.filler) {
            if (!ICorkCellarPremiumView(cellar).premiumFiredFor(orderDigest, rolloverRec.filler)) {
                revert StateDivergence();
            }
            paymentSettled[orderId] = true;
            fillRecords[orderId][premiumOH] = FillRecord({
                filler: msg.sender, destination: address(0), dstCstProduced: 0, filledAt: uint64(block.timestamp)
            });
        } catch (bytes memory err) {
            emit PremiumHooksReverted(orderDigest, rolloverRec.filler, err);
            paymentSettled[orderId] = true;
            fillRecords[orderId][premiumOH] = FillRecord({
                filler: msg.sender, destination: address(0), dstCstProduced: 0, filledAt: uint64(block.timestamp)
            });
        }

        emit Fill(orderId, 1, premiumOH, msg.sender);
    }
}
