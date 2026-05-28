// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseSettler} from "contracts/settlers/BaseSettler.sol";
import {
    DisproportionateOutput,
    CellarNotBound,
    InvalidFillers,
    ResidualTruncates,
    StateDivergence,
    BalanceFloorViolated
} from "contracts/settlers/BaseSettlerErrors.sol";
import {ICorkCellarPremiumView} from "contracts/interfaces/ICorkCellarPremiumView.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {
    OrderStatus,
    NotMaker,
    InvalidOrderTokenPair,
    InconsistentIntent,
    InvalidOrderStatus,
    IntentNotBoundToOrder,
    DigestMismatch,
    NotExpired,
    OrderHasFills,
    InvalidOriginFillerData
} from "contracts/interfaces/RolloverTypes.sol";
import {OrderData, OriginFillerData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibRolloverOrder} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent, ICorkCellar, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {CorkCellarFactory} from "cellar/CorkCellarFactory.sol";

contract PartialFillSettler is BaseSettler, IPartialFillSettler {
    using SafeERC20 for IERC20;

    mapping(bytes32 orderDigest => mapping(address filler => FillerRollover)) private _fillerRollovers;
    mapping(bytes32 orderDigest => uint256) private _totalDstCstEscrowed;
    mapping(bytes32 orderDigest => bytes32) public orderIdOf;
    mapping(bytes32 orderDigest => address) public cellarOf;
    mapping(bytes32 orderDigest => address) public dstCstToken;
    mapping(bytes32 orderDigest => uint256) public participantCount;
    mapping(bytes32 orderDigest => uint256) public finalisedCount;
    mapping(bytes32 orderDigest => uint256) public refundedCount;
    mapping(bytes32 orderId => address) public repaymentTo;

    /// @notice dstCST credited for a `(orderDigest, filler)` pair when the `finaliseAsSettled`
    ///         payout transfer to `f.destination` reverted (e.g. blacklist-style tokens like USDC
    ///         with a non-compliant destination). The filler's slot still latches `finalised`
    ///         so the order-terminal predicate is not permanently blocked; PR 6's
    ///         `rescueSettled` entry point reads this mapping to let the filler withdraw to a
    ///         new destination. Writes land exclusively from the try/catch branch in
    ///         `finaliseAsSettled`; zero amounts are never booked.
    mapping(bytes32 orderDigest => mapping(address filler => uint256)) private _rescueable;

    /// @notice Cached `premiumToken` per order-digest — populated on the premium-leg fill where
    ///         `_totalDstCstEscrowed[orderDigest]` is written and read at `finaliseAsSettled` to
    ///         emit the ERC-6909 ledger token identity (`uint256(uint160(premiumToken))`) on
    ///         `OrderAttribution.tokenId`. Closes cycle-1 C1 (#47 join-intent): the attribution
    ///         event now carries the same id that `ERC6909Premium.settle` emits, enabling a
    ///         three-way join across settler event, cellar hook, and ERC-6909 settlement
    ///         emissions. One slot per order-digest — overwritten per premium fill with the same
    ///         `od.premiumToken`; all fills for one digest share one premium token.
    mapping(bytes32 orderDigest => address) internal _premiumTokenOf;

    /// @notice Running sum of rollover-leg `output.amount` committed per orderId. Tracks the
    ///         order's cumulative fill progress for AS-22 residual-truncation enforcement (plan
    ///         extension — not RFC §6.2) — the BaseSettler ingress gate reads this value to
    ///         reject fills that would leave residual capacity `0 < r < minFillSize`.
    ///         Incremented after a rollover-leg fill completes so the pre-fill cumulative is
    ///         read via the hook before mutation. Keyed on `orderId` (not `orderDigest`) so
    ///         that two orders differing only in `minFillSize` / `exclusiveFiller` do NOT share
    ///         cumulative state — the pre-PR-2 `computeOrderDigest` omits those fields and would
    ///         collide otherwise.
    mapping(bytes32 orderId => uint256) public cumulativeFilled;

    constructor(address factory_, address erc6909Premium_) BaseSettler(factory_, erc6909Premium_) {}

    // ═══════════════════════════════════════════════════════════════
    //  IPartialFillSettler view getters
    // ═══════════════════════════════════════════════════════════════

    function fillerRollovers(bytes32 orderDigest, address filler) external view returns (FillerRollover memory) {
        return _fillerRollovers[orderDigest][filler];
    }

    function totalDstCstEscrowed(bytes32 orderDigest) external view returns (uint256) {
        return _totalDstCstEscrowed[orderDigest];
    }

    /// @inheritdoc BaseSettler
    /// @dev Partial keys rescueable credits by `(orderDigest, filler)` — matches the native
    ///      per-filler state shape on `_fillerRollovers`.
    function rescueableOf(bytes32 orderDigest, address filler) external view override returns (uint256) {
        return _rescueable[orderDigest][filler];
    }

    // ═══════════════════════════════════════════════════════════════
    //  open (onchain path)
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

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(this), synth, od);
        cellarOf[orderDigest] = CorkCellarFactory(factory).cellarOf(msg.sender);
        orderIdOf[orderDigest] = orderId;
        orderStatus[orderId] = OrderStatus.Opened;
        emit Open(orderId, _buildResolved(synth, od, 0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  resolve (onchain path)
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
    //  resolveFor
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

    /// @inheritdoc IPartialFillSettler
    /// @dev Cycle-1 C2: the per-slot cellar `premiumFiredFor` view read is wrapped in `try/catch`
    ///      so a reverting or gas-griefing cellar cannot permanently strand dstCST payouts at
    ///      finalise. On any caught revert `cellarFiller` falls back to `address(0)` — drift
    ///      signal for off-chain consumers, consistent with the "cellar never latched" semantic
    ///      on the premium-hook catch branch.
    function finaliseAsSettled(bytes32 orderDigest, address[] calldata fillers) external override nonReentrant {
        bytes32 orderId = orderIdOf[orderDigest];
        if (orderId == bytes32(0)) revert InvalidOrderStatus();
        if (orderStatus[orderId] != OrderStatus.Opened) revert InvalidOrderStatus();
        // Empty-fillers griefing guard (Pashov A1): without this revert any caller could invoke
        // the function as a no-op on an opened order. The companion `participantCount > 0` guard
        // in `_transitionIfTerminal` blocks the edge case where an attacker opens then
        // immediately finalises an order with zero fills.
        if (fillers.length == 0) revert InvalidFillers();

        // Phase 1 — bookkeeping: accumulate payouts in memory.
        address token = dstCstToken[orderDigest];
        uint256 len = fillers.length;
        // Parallel arrays indexed by payoutLen; kept flat for payout-loop clarity.
        address[] memory payoutFillers = new address[](len);
        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);
        uint256 payoutLen;
        uint256 skipped;

        for (uint256 i; i < len; ++i) {
            FillerRollover storage f = _fillerRollovers[orderDigest][fillers[i]];
            if (!f.premiumSettled || f.finalised || f.refunded) {
                ++skipped;
                continue;
            }

            f.finalised = true;
            finalisedCount[orderDigest] += 1;
            _totalDstCstEscrowed[orderDigest] -= f.dstCstProduced;

            if (f.dstCstProduced > 0) {
                payoutFillers[payoutLen] = fillers[i];
                recipients[payoutLen] = f.destination;
                amounts[payoutLen] = f.dstCstProduced;
                ++payoutLen;
            }

            emit FillerFinalised(orderDigest, fillers[i], f.dstCstProduced);
        }

        // Phase 2 — terminal check: status committed before any transfer. Shared predicate on
        // BaseSettler (PR 3 / Task 8). Preserves the `participantCount > 0` early-return guard
        // from `fafcf65` (Pashov A1).
        _transitionIfTerminal(orderDigest, orderId);

        // Phase 3 — transfers. Blacklist-safe (Task 17 / closes #39 payout-loop branch): on a
        // per-filler transfer revert (e.g. USDC blacklisted destination) the filler's slot is
        // already latched `finalised = true` in Phase 1, so the order terminal predicate is not
        // blocked; the amount is booked on `_rescueable[orderDigest][filler]` and
        // `FillerRescueCredited` is emitted for the filler to later withdraw via PR 6's
        // `rescueSettled` entry point. The transfer is performed through `externalSafeTransfer`
        // (a `this.` external call) so `SafeERC20` reverts are catchable as `bytes memory`
        // reason — internal `safeTransfer` cannot be wrapped in `try/catch` (Solidity only
        // supports `try` on external / `new` calls).
        //
        // Task 36 (#47) — emit `OrderAttribution` immediately BEFORE the transfer. The event
        // joins settler-side filler identity (`fillerSlot` / `premiumFiller`) with the cellar's
        // `premiumFiredFor` view so off-chain consumers can detect attribution drift independent
        // of the PR 9 / #61 parity check. On Partial, `fillerSlot == premiumFiller` by
        // construction (state is keyed on `filler`); `cellarFiller` resolves to `filler` on the
        // success branch of `_onPremiumLegFill` and to zero on the catch branch.
        // Cycle-1 C2 — the cellar view call is wrapped in `try/catch` so a reverting /
        // gas-griefing cellar cannot strand the batch's dstCST payouts at finalise. A caught
        // revert resolves `cellarFiller` to `address(0)` for that slot — drift signal for
        // off-chain consumers, consistent with the "cellar never latched" semantic.
        address cellar = cellarOf[orderDigest];
        uint256 tokenIdentity = uint256(uint160(_premiumTokenOf[orderDigest]));
        for (uint256 i; i < payoutLen; ++i) {
            address f = payoutFillers[i];
            emit OrderAttribution(orderId, f, f, _cellarFillerOf(cellar, orderDigest, f), tokenIdentity, amounts[i]);
            try this.externalSafeTransfer(token, recipients[i], amounts[i]) {}
            catch (bytes memory reason) {
                _rescueable[orderDigest][f] += amounts[i];
                emit FillerRescueCredited(orderDigest, f, amounts[i], reason);
            }
        }

        // Task 37 (#46) — balance-floor invariant. After the payout loop, the settler's live
        // dstCST balance MUST cover the order's remaining escrow (other fillers not in this
        // batch). Catches silent-siphon refactors — a future change that lets dstCST leak out
        // before finalise completes would surface here. Blacklist-catch amounts stay on the
        // settler as `_rescueable` credits, so they DO count toward `balanceOf` and the floor
        // remains satisfied end-to-end.
        uint256 observed = IERC20(token).balanceOf(address(this));
        uint256 floor = _totalDstCstEscrowed[orderDigest];
        if (observed < floor) revert BalanceFloorViolated(observed, floor);

        emit FinaliseBatch(orderDigest, msg.sender, len - skipped, skipped);
    }

    // ═══════════════════════════════════════════════════════════════
    //  finaliseAsRefunded
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc IPartialFillSettler
    /// @dev The refund payout target is the UW's own `cellar`, which is cellar-bound at open time
    ///      and therefore maker-controlled — a maker who sets an uncooperative cellar blocks
    ///      their own refund, which is not a filler-facing concern. Wrapping this transfer in
    ///      `try/catch` would let a griefed maker silently drift each filler into a rescueable
    ///      credit keyed to the WRONG party (the cellar, not the filler) on a path where no such
    ///      party exists to withdraw — and would still not salvage funds on a cellar that reverts.
    ///      Behaviour is intentionally preserved as the previous bare `safeTransfer` semantics:
    ///      a revert bubbles and the refund batch is atomic. Matches Task 17 carve-out.
    function finaliseAsRefunded(bytes32 orderDigest, GaslessCrossChainOrder calldata order, address[] calldata fillers)
        external
        override
        nonReentrant
    {
        bytes32 orderId = _hashOrder(order);
        if (orderId != orderIdOf[orderDigest]) revert DigestMismatch();
        if (block.timestamp <= order.fillDeadline) revert NotExpired();
        if (orderStatus[orderId] != OrderStatus.Opened) revert InvalidOrderStatus();

        address cellar = cellarOf[orderDigest];
        address token = dstCstToken[orderDigest];

        // Phase 1 — bookkeeping: accumulate payouts in memory.
        uint256 len = fillers.length;
        uint256[] memory amounts = new uint256[](len);
        uint256 payoutLen;
        uint256 skipped;

        for (uint256 i; i < len; ++i) {
            FillerRollover storage f = _fillerRollovers[orderDigest][fillers[i]];
            if (f.premiumSettled || f.refunded || f.finalised) {
                ++skipped;
                continue;
            }

            f.refunded = true;
            refundedCount[orderDigest] += 1;
            _totalDstCstEscrowed[orderDigest] -= f.dstCstProduced;

            if (f.dstCstProduced > 0) {
                amounts[payoutLen] = f.dstCstProduced;
                ++payoutLen;
            }

            emit FillerFinalised(orderDigest, fillers[i], f.dstCstProduced);
        }

        // Phase 2 — terminal check: status committed before any transfer. Shared predicate on
        // BaseSettler (PR 3 / Task 8). Preserves the `participantCount > 0` early-return guard
        // from `fafcf65` (Pashov A1).
        _transitionIfTerminal(orderDigest, orderId);

        // Phase 3 — transfers (all go to cellar).
        for (uint256 i; i < payoutLen; ++i) {
            IERC20(token).safeTransfer(cellar, amounts[i]);
        }

        emit FinaliseBatch(orderDigest, msg.sender, len - skipped, skipped);
    }

    // ═══════════════════════════════════════════════════════════════
    //  rescueSettled (PR 6 — closes #44)
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc IPartialFillSettler
    /// @dev Thin external wrapper — `nonReentrant` on the entry point; the shared core on
    ///      `BaseSettler._rescueSettled` runs sig verification, CEI zeroing via
    ///      `_consumeRescueable`, and the dstCST transfer. Partial's `_rescueable` is keyed by
    ///      `orderDigest` so `orderId` is only carried for the EIP-712 pre-image.
    function rescueSettled(
        bytes32 orderDigest,
        bytes32 orderId,
        address filler,
        address fallbackDestination,
        bytes calldata sig
    ) external override nonReentrant {
        address token = dstCstToken[orderDigest];
        uint256 amount = _rescueSettled(orderDigest, orderId, filler, fallbackDestination, sig, token);
        emit FillerRescueWithdrawn(orderDigest, filler, fallbackDestination, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //  finaliseAsCancelled
    // ═══════════════════════════════════════════════════════════════

    function finaliseAsCancelled(bytes32 orderDigest, GaslessCrossChainOrder calldata order, bytes calldata cancelSig)
        external
        override
        nonReentrant
    {
        bytes32 orderId = orderIdOf[orderDigest];
        if (orderId == bytes32(0)) revert InvalidOrderStatus();
        if (_hashOrder(order) != orderId) revert DigestMismatch();
        if (orderStatus[orderId] != OrderStatus.Opened) revert InvalidOrderStatus();

        if (participantCount[orderDigest] != 0 || _totalDstCstEscrowed[orderDigest] != 0) {
            revert OrderHasFills();
        }

        if (msg.sender != order.user) {
            _recoverCancel(orderId, cancelSig, order.user);
        }

        orderStatus[orderId] = OrderStatus.Cancelled;
        emit OrderFinalised(orderId, OrderStatus.Cancelled, orderDigest);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Shared-primitive overrides (PR 3 — Task 8)
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc BaseSettler
    /// @dev Writes the per-filler rollover entry keyed on `(orderDigest, filler)` — Partial's
    ///      native storage shape. Increments `participantCount` and `totalDstCstEscrowed` so the
    ///      shared `_transitionIfTerminal` predicate observes the new participant and its escrow.
    function _recordFillerEscrow(
        bytes32 orderKey,
        address filler,
        uint256 srcCstProvided,
        uint256 dstCstProduced,
        address destination
    ) internal override {
        _fillerRollovers[orderKey][filler] = FillerRollover({
            srcCstProvided: srcCstProvided,
            dstCstProduced: dstCstProduced,
            destination: destination,
            premiumSettled: false,
            finalised: false,
            refunded: false
        });
        _totalDstCstEscrowed[orderKey] += dstCstProduced;
        participantCount[orderKey] += 1;
    }

    /// @inheritdoc BaseSettler
    function _lookupFillerEscrow(bytes32 orderKey, address filler)
        internal
        view
        override
        returns (FillerEscrow memory escrow)
    {
        FillerRollover storage f = _fillerRollovers[orderKey][filler];
        escrow = FillerEscrow({
            filler: f.srcCstProvided == 0 ? address(0) : filler,
            destination: f.destination,
            srcCstProvided: f.srcCstProvided,
            dstCstProduced: f.dstCstProduced,
            filledAt: 0,
            premiumSettled: f.premiumSettled,
            finalised: f.finalised,
            refunded: f.refunded
        });
    }

    /// @inheritdoc BaseSettler
    /// @dev Partial keys `_rescueable` by `orderDigest` — the second `orderId` parameter is the
    ///      EIP-712 pre-image carrier and is ignored here.
    function _consumeRescueable(
        bytes32 orderDigest,
        bytes32,
        /* orderId */
        address filler
    )
        internal
        override
        returns (uint256 amount)
    {
        amount = _rescueable[orderDigest][filler];
        if (amount != 0) {
            _rescueable[orderDigest][filler] = 0;
        }
    }

    /// @inheritdoc BaseSettler
    function _participantCountOf(bytes32 orderDigest) internal view override returns (uint256) {
        return participantCount[orderDigest];
    }

    /// @inheritdoc BaseSettler
    function _finalisedCountOf(bytes32 orderDigest) internal view override returns (uint256) {
        return finalisedCount[orderDigest];
    }

    /// @inheritdoc BaseSettler
    function _refundedCountOf(bytes32 orderDigest) internal view override returns (uint256) {
        return refundedCount[orderDigest];
    }

    /// @inheritdoc BaseSettler
    function _totalDstCstEscrowedOf(bytes32 orderDigest) internal view override returns (uint256) {
        return _totalDstCstEscrowed[orderDigest];
    }

    /// @inheritdoc BaseSettler
    function _hookPhase0Done(bytes32 orderDigest) internal view override returns (bool) {
        return (ICorkCellar(cellarOf[orderDigest]).hookNonces(orderDigest) & 1) != 0;
    }

    /// @inheritdoc BaseSettler
    function _emitOrderFinalised(bytes32 orderId, OrderStatus status, bytes32 orderDigest) internal override {
        emit OrderFinalised(orderId, status, orderDigest);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Virtual hook overrides
    // ═══════════════════════════════════════════════════════════════

    function _validateOpen(OrderData memory od) internal pure override {
        if (od.srcCstToken == od.premiumToken) revert InvalidOrderTokenPair();
        if (!od.allowPartialFills) revert InconsistentIntent();
    }

    /// @inheritdoc BaseSettler
    /// @dev AS-22 residual-truncation gate — plan extension, NOT part of RFC §6.2. Called from
    ///      `BaseSettler.fill` only on the rollover leg and only when `od.minFillSize != 0`.
    ///      Reverts iff the incoming fill would leave residual capacity
    ///      `0 < residual < minFillSize`, which would force any follow-up fill to be dust. A
    ///      fill that closes the order exactly (`residual == 0`) is allowed regardless of
    ///      `minFillSize`. An over-fill (`cumulative + fillAmount > orderSize`) is left to the
    ///      downstream cellar ceiling check — the gate short-circuits it here so the residual
    ///      subtraction is unsigned-safe. Cumulative state is keyed on `orderId` to avoid the
    ///      pre-PR-2 digest collision across orders differing only in `minFillSize` /
    ///      `exclusiveFiller`.
    function _enforceResidualTruncates(OrderData memory od, bytes32 orderId, uint256 fillAmount)
        internal
        view
        override
    {
        uint256 cumulative = cumulativeFilled[orderId];
        // Overfill is handled by the cellar; skip the residual check if the fill would exceed
        // `orderSize` so the unsigned subtraction below cannot underflow.
        if (cumulative + fillAmount > od.orderSize) return;
        uint256 residual = od.orderSize - (cumulative + fillAmount);
        if (residual != 0 && residual < od.minFillSize) revert ResidualTruncates();
    }

    function _validateOriginFillerData(bytes calldata originFillerData) internal pure override {
        if (originFillerData.length == 0) revert InvalidOriginFillerData();
    }

    function _onOpenForDecoded(bytes32 orderId, OriginFillerData memory fd) internal override {
        repaymentTo[orderId] = fd.repaymentTo;
    }

    function _onOpenTransitionToOpened(bytes32 orderId, bytes32 orderDigest, address user_) internal override {
        cellarOf[orderDigest] = CorkCellarFactory(factory).cellarOf(user_);
        orderIdOf[orderDigest] = orderId;
    }

    function _onRolloverLegFill(
        GaslessCrossChainOrder memory order,
        OrderData memory od,
        Output memory output,
        bytes calldata legData
    ) internal override {
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(this), order, od);
        PartialFillerData memory pfd = LibRolloverOrder.decodePartialFillerData(legData);

        if (pfd.targetFiller != msg.sender) revert TargetFillerMismatch();
        _requireDestination(pfd.destination);
        if (keccak256(abi.encode(pfd.intent)) != od.cellarIntentHash) {
            revert IntentNotBoundToOrder();
        }
        if (_fillerRollovers[orderDigest][msg.sender].srcCstProvided != 0) {
            revert AlreadyFilledByFiller();
        }

        address cellar = cellarOf[orderDigest];

        IERC20 dstCst = IERC20(od.dstCstToken);
        IERC20 srcCst = IERC20(od.srcCstToken);
        uint256 dstBefore = dstCst.balanceOf(address(this));
        uint256 srcBefore = srcCst.balanceOf(address(this));

        if (dstCstToken[orderDigest] == address(0)) {
            dstCstToken[orderDigest] = od.dstCstToken;
        }

        uint256 actualRolled =
            _forwardToFactory(cellar, pfd.intent.orderDigest, 0, pfd.intent, pfd.cellarSig, output.amount, msg.sender);
        if (actualRolled == 0) revert ZeroRollover();

        uint256 dstDelta = dstCst.balanceOf(address(this)) - dstBefore;
        uint256 srcLeftover = srcCst.balanceOf(address(this)) - srcBefore;

        if (dstDelta + 1 < actualRolled - srcLeftover) revert DisproportionateOutput();

        // Shared write primitive (PR 3 — Task 8). Writes the per-filler record and increments
        // `participantCount` / `_totalDstCstEscrowed` so the shared `_transitionIfTerminal`
        // predicate observes the new participant.
        _recordFillerEscrow(orderDigest, msg.sender, actualRolled, dstDelta, pfd.destination);

        if (srcLeftover > 0) {
            srcCst.safeTransfer(msg.sender, srcLeftover);
        }

        bytes32 orderId = _hashOrder(order);
        // AS-22 ledger (plan extension — not RFC §6.2). Tracks the rollover-leg cumulative in
        // the same units the ingress gate compares against `orderSize`. Stored post-fill so the
        // gate (read pre-fill) sees the prior total. Keyed on `orderId` so semantically distinct
        // orders do not share the slot (pre-PR-2 `orderDigest` omits the gate fields).
        cumulativeFilled[orderId] += output.amount;

        bytes32 outputHash = LibSettlerHashing.computeOutputHash(output);
        emit Fill(orderId, 0, outputHash, msg.sender);
    }

    /// @dev AS-10 / #58 + I3 / #60 — the phase-1 cellar callback is isolated in a try/catch so
    ///      UW-controlled premium hooks cannot brick the filler's settle path. The ERC-6909 debit
    ///      via `_settlePremium` stays BEFORE the forward because the forward reads the debited
    ///      state. The `f.premiumSettled` latch now flips AFTER the forward in BOTH branches
    ///      (success and catch) — mirroring the forward-then-write convention already used on
    ///      `_onRolloverLegFill`. End-state is identical to PR 7: the latch is `true` whether the
    ///      hooks succeed or revert. On revert the premium tokens sit at the cellar; the UW owner
    ///      recovers them out-of-band via `executeHooks(Call[])`.
    function _onPremiumLegFill(
        GaslessCrossChainOrder memory order,
        OrderData memory od,
        Output memory output,
        bytes calldata legData
    ) internal override {
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(this), order, od);
        PartialFillerData memory pfd = LibRolloverOrder.decodePartialFillerData(legData);

        // Symmetric with `_onRolloverLegFill`: the premium caller must BE `targetFiller`. Without
        // this check any caller could post a premium leg naming another filler as `targetFiller`
        // and drive that filler's bookkeeping to `premiumSettled`, unlocking the payout to the
        // attacker-controlled `pfd.destination` on the rollover leg or arbitrarily delaying the
        // terminal transition for the real filler (Pashov A3 — see audit report).
        if (pfd.targetFiller != msg.sender) revert TargetFillerMismatch();

        FillerRollover storage f = _fillerRollovers[orderDigest][pfd.targetFiller];
        if (f.srcCstProvided == 0) revert NoRolloverLegForFiller();
        if (f.premiumSettled) revert AlreadySettled();
        if (keccak256(abi.encode(pfd.intent)) != od.cellarIntentHash) {
            revert IntentNotBoundToOrder();
        }

        _requireDebitFromAuthorized(pfd.debitFrom);

        uint256 premium = Math.mulDiv(f.dstCstProduced, od.minPremiumPerShare, 1e18, Math.Rounding.Ceil);

        address cellar = cellarOf[orderDigest];
        if (cellar == address(0)) revert CellarNotBound();

        uint256 tokenId = uint256(uint160(od.premiumToken));
        _settlePremium(tokenId, premium, pfd.debitFrom, msg.sender, cellar);
        // Cycle-1 C1 (#47) — cache `premiumToken` for the finalise-time `OrderAttribution.tokenId`
        // emission. All premium fills for one `orderDigest` share `od.premiumToken` (digest binds
        // the full order), so the write is idempotent across the batch — unconditional write
        // pays the 20k fresh-slot cost once on the first premium leg and 2.9k warm-slot cost on
        // subsequent fills; no gate branch needed.
        _premiumTokenOf[orderDigest] = od.premiumToken;

        // #63 / Integ M1 — publish the settler-side filler identity to the `PREMIUM_FILLER_SLOT`
        // transient slot BEFORE forwarding. The cellar's `_runPremiumPhase` reads this slot via
        // `tload` to cross-check the filler identity against the `filler` arg the factory
        // relays. Writing post-debit-pre-forward matches the CEI window: state is settled on
        // the settler side, and the slot latches the value the cellar consumes during the
        // forward. The slot is transient — it resets on transaction end, so no clean-up is
        // needed on either the success or catch branch.
        bytes32 slot = PREMIUM_FILLER_SLOT;
        address _filler = pfd.targetFiller;
        assembly {
            tstore(slot, _filler)
        }

        // AS-10 / #58 + I3 / #60 — isolate UW-controlled phase-1 hooks, with forward-then-write
        // ordering symmetric to `_onRolloverLegFill`. The `f.premiumSettled` latch flips AFTER
        // the forward in BOTH branches: end-state is identical to PR 7 whether the hooks succeed
        // or revert. On revert we emit the signal event; `finaliseAsSettled` can still route
        // dstCST to the filler because the latch is set. The premium sits at the cellar; UW owner
        // recovers it via `executeHooks`.
        //
        // #61 / I4 — on the success branch, cross-check `premiumFiredFor[orderDigest][targetFiller]`
        // on the cellar. The forward is supposed to flip that latch inside `_runPremiumPhase`; if
        // it returns success without doing so, settler and cellar state have diverged (e.g. a
        // masquerading cellar that no-ops). Revert with `StateDivergence` so the settler-side
        // latch is NOT committed on top of a cellar that never latched. On the catch branch the
        // hook didn't run — the cellar was never expected to latch, so no assertion is made.
        try ICorkCellarFactory(factory)
            .executeIntentHooks(cellar, pfd.intent.orderDigest, 1, pfd.intent, pfd.cellarSig, 0, pfd.targetFiller) {
            if (!ICorkCellarPremiumView(cellar).premiumFiredFor(orderDigest, pfd.targetFiller)) {
                revert StateDivergence();
            }
            f.premiumSettled = true;
        } catch (bytes memory err) {
            emit PremiumHooksReverted(orderDigest, pfd.targetFiller, err);
            f.premiumSettled = true;
        }

        bytes32 orderId = _hashOrder(order);
        bytes32 outputHash = LibSettlerHashing.computeOutputHash(output);
        emit Fill(orderId, 1, outputHash, msg.sender);
    }
}
