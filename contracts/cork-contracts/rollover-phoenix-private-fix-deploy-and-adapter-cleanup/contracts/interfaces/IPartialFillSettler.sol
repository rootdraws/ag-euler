// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IDestinationSettler} from "contracts/interfaces/IDestinationSettler.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title IPartialFillSettler
/// @notice Cork rollover settler for partial-fill (cumulative multi-filler) orders. Extends the
///         ERC-7683 origin + destination settler surface with terminal entry points keyed by
///         `orderDigest` plus caller-supplied `address[] fillers`, and with per-filler view
///         getters.
/// @dev Per partial-fill extension §5.4, the Partial path maintains per-filler state keyed by
///      `(orderDigest, filler)` and an `address[]` fillers list supplied at finalise time (the D3
///      model — no on-chain filler enumeration). Each settle/refund entry is idempotent via the
///      `finalised` / `refunded` flags on `FillerRollover`; order-level completeness is tracked
///      by `totalDstCstEscrowed[orderDigest] == 0`. Shared errors live in `RolloverTypes.sol`.
interface IPartialFillSettler is IOriginSettler, IDestinationSettler {
    /// @notice Per-filler rollover state — one struct per `(orderDigest, filler)` pair. See
    ///         partial-fill extension §5.4.
    /// @param srcCstProvided srcCST amount this filler pushed during their rollover-leg fill.
    /// @param dstCstProduced dstCST escrowed for this filler, awaiting premium-leg settlement or
    ///        refund.
    /// @param destination The filler's chosen dstCST recipient at `finaliseAsSettled` time.
    /// @param premiumSettled Set on successful premium-leg `_settle()` for this filler.
    /// @param finalised Set on `finaliseAsSettled` for this filler — idempotency latch.
    /// @param refunded Set on `finaliseAsRefunded` for this filler — idempotency latch.
    struct FillerRollover {
        uint256 srcCstProvided;
        uint256 dstCstProduced;
        address destination;
        bool premiumSettled;
        bool finalised;
        bool refunded;
    }

    /// @notice Emitted on a successful per-filler leg fill. Partial-fill mirror of the Exact
    ///         settler's `Fill`; keyed by the rollover-leg filler so off-chain infra can
    ///         reconstruct per-filler participation from events.
    /// @param orderId Canonical order identifier.
    /// @param outputIndex 0 = rollover leg, 1 = premium leg.
    /// @param outputHash `keccak256(abi.encode(Output))` for the filled leg.
    /// @param filler The `msg.sender` that executed the fill.
    event Fill(bytes32 indexed orderId, uint8 indexed outputIndex, bytes32 outputHash, address filler);

    /// @notice Emitted when an individual filler is settled or refunded. One event per filler per
    ///         terminal transition.
    /// @param orderDigest Order binding digest (RFC 003 §A.8).
    /// @param filler The filler whose entry was finalised.
    /// @param dstCstProduced dstCST released to the filler's destination (Settled) or returned to
    ///        the cellar (Refunded — may be 0 if the filler never held escrow).
    event FillerFinalised(bytes32 indexed orderDigest, address indexed filler, uint256 dstCstProduced);

    /// @notice Emitted when the order itself transitions to a terminal status (after every
    ///         filler has been finalised and `totalDstCstEscrowed == 0`, or on cancel).
    /// @param orderId Canonical order identifier.
    /// @param status The terminal `OrderStatus`.
    /// @param orderDigest Order binding digest.
    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);

    /// @notice Emitted at the end of each `finaliseAsSettled` / `finaliseAsRefunded` batch call,
    ///         summarising how many fillers were processed vs skipped.
    /// @param orderDigest Order binding digest.
    /// @param caller The `msg.sender` that invoked the batch.
    /// @param processed Number of fillers whose state was mutated.
    /// @param skipped Number of fillers that were no-ops (already finalised/refunded/ineligible).
    event FinaliseBatch(bytes32 indexed orderDigest, address indexed caller, uint256 processed, uint256 skipped);

    /// @notice Emitted when a `finaliseAsSettled` payout transfer reverts for a filler and the
    ///         amount is credited to `rescueableOf(orderDigest, filler)` for later withdrawal.
    ///         Closes the §39 blacklist-stuck-Opened state: the filler's slot still latches
    ///         `finalised = true` so the order terminal predicate can fire, but the payout is
    ///         deferred.
    /// @param orderDigest Order binding digest.
    /// @param filler Filler whose payout reverted.
    /// @param amount dstCST credited for later rescue withdrawal.
    /// @param reason Raw revert data bubbled from the caught `safeTransfer` call (verbatim).
    /// @dev `reason` is attacker-influenceable revert data from the filler-destination transfer.
    ///      MUST NOT be used for control-flow decisions off-chain.
    event FillerRescueCredited(bytes32 indexed orderDigest, address indexed filler, uint256 amount, bytes reason);

    /// @notice Emitted when a filler pulls a previously-stranded dstCST credit via
    ///         `rescueSettled`. The `(orderDigest, filler)` slot in `_rescueable` is zeroed in
    ///         the same call under CEI, so every emission corresponds to a one-shot withdrawal
    ///         of the credited amount to `fallbackDestination`.
    /// @param orderDigest Order binding digest (Partial's `_rescueable` key).
    /// @param filler Filler whose credit was consumed.
    /// @param fallbackDestination dstCST recipient chosen by the filler's signature.
    /// @param amount dstCST released on this withdrawal (equals the prior credited amount).
    event FillerRescueWithdrawn(
        bytes32 indexed orderDigest, address indexed filler, address indexed fallbackDestination, uint256 amount
    );

    /// @notice Emitted once per filler slot at `finaliseAsSettled`, immediately before the payout
    ///         transfer. Joins three filler identities that SHOULD all match on the happy path:
    ///          - `fillerSlot`     the address the `_rescueable` and per-filler state maps key on
    ///          - `premiumFiller`  the filler recorded on the settler's own `FillerRollover` entry
    ///          - `cellarFiller`   the filler the cellar latched via `premiumFiredFor` (or zero if
    ///                             the cellar never latched — i.e. the premium hook caught-revert
    ///                             branch fired, see `PremiumHooksReverted`).
    ///         Off-chain consumers MUST treat any drift between these three as an attribution
    ///         anomaly — pre-PR-3 bookkeeping drift is now blocked by the #61 / I4 parity check
    ///         but the event is load-bearing as a forward-compatible probe for future seams.
    ///         Closes #47 (M3).
    /// @param orderId Canonical order identifier.
    /// @param fillerSlot Partial: the `address` key used on `_fillerRollovers[orderDigest][…]` and
    ///        `_rescueable[orderDigest][…]` — equals `fillers[i]` in the finalise batch.
    /// @param premiumFiller Settler-recorded filler identity from per-slot state. On Partial equals
    ///        `fillerSlot`; a divergence would indicate a cross-slot mix-up.
    /// @param cellarFiller Filler identity the cellar latched for this `(orderDigest, filler)` pair
    ///        via `premiumFiredFor`. Returns `fillerSlot` on the success branch; `address(0)` when
    ///        the premium hook reverted and the cellar never latched (end-state still permits
    ///        payout — `premiumSettled` latches on both branches).
    /// @param tokenId ERC-6909 ledger token id — `uint256(uint160(premiumToken))` — enabling a
    ///        three-way join against the settler event, cellar hook, and `ERC6909Premium.settle`
    ///        emissions. Matches RFC 003 §5 and issue #47 (M3) join intent verbatim.
    /// @param amount dstCST amount being transferred on this payout.
    event OrderAttribution(
        bytes32 indexed orderId,
        address indexed fillerSlot,
        address indexed premiumFiller,
        address cellarFiller,
        uint256 tokenId,
        uint256 amount
    );

    /// @notice Emitted when the phase-1 `executeIntentHooks` forward inside `_onPremiumLegFill`
    ///         reverts. The settler swallows the revert so the filler's `premiumSettled = true`
    ///         write and ERC-6909 debit remain committed — a UW who signs conditionally-reverting
    ///         `premiumHooks` can no longer turn N rollover-leg srcCST burns into a forced-refund
    ///         windfall (AS-10 / #58). The premium sits at the cellar until the UW owner
    ///         recovers it via `executeHooks(Call[])`.
    /// @param orderDigest Order binding digest (RFC 003 §A.8).
    /// @param targetFiller Filler whose premium leg was being settled at catch time.
    /// @param err Raw revert data bubbled from the caught `executeIntentHooks` call (verbatim).
    /// @dev `err` is attacker-influenceable revert data from UW-controlled cellar hooks. MUST NOT
    ///      be used for control-flow decisions off-chain.
    event PremiumHooksReverted(bytes32 indexed orderDigest, address indexed targetFiller, bytes err);

    /// @notice Phase-0 filler supplied `targetFiller != msg.sender`. Self-deal guard — every
    ///         rollover-leg fill must credit the caller. Partial-fill extension §5.4.
    error TargetFillerMismatch();

    /// @notice `PartialFillerData.destination == address(0)` at rollover-leg entry. Partial-fill
    ///         extension §5.4.
    error InvalidDestination();

    /// @notice Same `(orderDigest, filler)` already has a rollover-leg record. INV-P1.
    ///         Partial-fill extension §13.3.
    error AlreadyFilledByFiller();

    /// @notice Cellar returned `actualRolled == 0` from `executeIntentHooks` — slot-squat
    ///         defense-in-depth. Partial-fill extension §13.3.
    error ZeroRollover();

    /// @notice Premium-leg attempted for a filler with no prior rollover-leg record. Partial-fill
    ///         extension §13.3.
    error NoRolloverLegForFiller();

    /// @notice `_settle()` attempted twice for the same `(orderDigest, filler)` — idempotency
    ///         latch on `FillerRollover.premiumSettled`. Partial-fill extension §13.3.
    error AlreadySettled();

    /// @notice `PartialFillerData.debitFrom` is neither `msg.sender` nor an ERC-6909 operator
    ///         authorized by `debitFrom`. Partial-fill extension §5.4.
    error UnauthorizedDebitFrom();

    /// @notice Transitions `FillerRollover` entries for each supplied filler to `finalised = true`
    ///         and releases escrowed dstCST to their chosen destinations.
    /// @dev Per-filler idempotent — already-finalised entries are no-ops. When the last escrowed
    ///      unit is released (`totalDstCstEscrowed[orderDigest] == 0`) the order's own status
    ///      transitions to `Settled`. Reverts with `InvalidOrderStatus` if the order is not
    ///      `Opened` at entry. Callers MUST supply a complete list for order-level settlement;
    ///      partial settlements are permitted and leave the order open.
    /// @param orderDigest Order binding digest (RFC 003 §A.8).
    /// @param fillers Fillers whose entries to settle. Order within the array does not matter.
    function finaliseAsSettled(bytes32 orderDigest, address[] calldata fillers) external;

    /// @notice Callable by anyone after `order.fillDeadline`. The refund path is
    ///         permissionless but unrewarded — off-chain keepers or integrator
    ///         frontends are expected to drive it. Consumers monitoring order
    ///         lifecycle SHOULD watch fill-deadline timers in their indexer rather
    ///         than rely on an on-chain deadline-crossed event.
    /// @dev Transitions `FillerRollover` entries to `refunded = true` after
    ///      `order.fillDeadline` has passed and only for fillers whose premium was never
    ///      settled. Returns escrowed dstCST to the UW's cellar.
    ///      Reverts with `NotExpired` before the deadline and `DigestMismatch` if the
    ///      caller-supplied `order` does not reproduce `orderDigest`. Per-filler idempotent.
    /// @param orderDigest Order binding digest.
    /// @param order The full `GaslessCrossChainOrder` (used to decode `OrderData` and recover the
    ///        cellar address — not trusted; validated against `orderDigest`).
    /// @param fillers Fillers whose entries to refund.
    function finaliseAsRefunded(
        bytes32 orderDigest,
        IOriginSettler.GaslessCrossChainOrder calldata order,
        address[] calldata fillers
    ) external;

    /// @notice Filler-authenticated pull path for stranded dstCST credits booked by
    ///         `finaliseAsSettled` when the payout transfer to `FillerRollover.destination`
    ///         reverted (e.g. USDC-style blacklist on the original destination). Permissionless
    ///         in `msg.sender`; authorisation is the filler's own EIP-712 signature over
    ///         `(orderDigest, orderId, fallbackDestination)` under the settler's domain. The
    ///         caller never chooses destinations — only the filler's signed recipient can receive
    ///         funds, so this entry point cannot be used to redirect another filler's credit.
    ///         Closes #44.
    /// @dev Reverts with `InvalidDestination` when `fallbackDestination == address(0)`,
    ///      `InvalidRescueSignature` when `sig` does not recover to `filler` under the settler's
    ///      EIP-712 domain, and `NothingToRescue` when `_rescueable[orderDigest][filler] == 0`
    ///      (either no prior credit or the slot has already been consumed — the CEI zeroing makes
    ///      signature-replay a no-op revert rather than a silent double-spend). Non-reentrant.
    /// @param orderDigest Order binding digest — partial's `_rescueable` key.
    /// @param orderId Canonical order identifier. Partial ignores this field for state lookups
    ///        but it IS part of the EIP-712 pre-image so the same signed struct shape is valid
    ///        across Partial and Exact settlers.
    /// @param filler Address authorising the withdrawal — the same filler credited on the
    ///        blacklist-catch branch of `finaliseAsSettled`.
    /// @param fallbackDestination dstCST recipient chosen by the filler's signature.
    /// @param sig Filler's EIP-712 signature over
    ///        `keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination))`.
    ///        Verified with `SignatureChecker.isValidSignatureNow` (EOA + ERC-1271).
    function rescueSettled(
        bytes32 orderDigest,
        bytes32 orderId,
        address filler,
        address fallbackDestination,
        bytes calldata sig
    ) external;

    /// @notice Cancels an open partial-fill order. Cancel is digest-keyed to match Partial's
    ///         multi-filler state surface. Requires maker auth and zero fill participation.
    /// @dev Reverts with `InvalidOrderStatus` if the digest has no mapped `orderId` or the order
    ///      is not `Opened`, `DigestMismatch` if the supplied `order` does not reproduce the
    ///      stored `orderId`, `OrderHasFills` if any filler has a record, and `NotMaker` /
    ///      `InvalidSignature` on auth failure.
    /// @param orderDigest Order binding digest (RFC 003 §A.8).
    /// @param order The full `GaslessCrossChainOrder`.
    /// @param cancelSig Maker's cancel signature over `orderId`. Ignored when
    ///        `msg.sender == order.user`.
    function finaliseAsCancelled(
        bytes32 orderDigest,
        IOriginSettler.GaslessCrossChainOrder calldata order,
        bytes calldata cancelSig
    ) external;

    /// @notice Returns the full `FillerRollover` entry for a `(orderDigest, filler)` pair. Zero
    ///         struct if the pair has no rollover-leg record.
    /// @param orderDigest Order binding digest.
    /// @param filler Filler address.
    /// @return rollover The per-filler rollover state.
    function fillerRollovers(bytes32 orderDigest, address filler) external view returns (FillerRollover memory rollover);

    /// @notice Sum of `FillerRollover.dstCstProduced` across all unfinalised fillers for the
    ///         order. Reaches zero iff every filler has been settled or refunded; used by the
    ///         settler to latch the order-level terminal transition.
    /// @param orderDigest Order binding digest.
    /// @return amount Total dstCST currently escrowed for the order.
    function totalDstCstEscrowed(bytes32 orderDigest) external view returns (uint256 amount);
}
