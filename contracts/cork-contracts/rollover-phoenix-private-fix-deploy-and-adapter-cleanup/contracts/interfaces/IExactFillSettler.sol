// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IDestinationSettler} from "contracts/interfaces/IDestinationSettler.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title IExactFillSettler
/// @notice Cork rollover settler for exact-fill (one-fill-per-order) orders. Extends the ERC-7683
///         origin + destination settler surface with three terminal-transition entry points
///         (settle / refund / cancel) keyed by `orderId`.
/// @dev Authorization and state invariants follow RFC 003 §3.2 and §6.4.1:
///       - `finaliseAsSettled` is permissionless, requires `orderStatus == Opened` and
///         `paymentSettled == true`.
///       - `finaliseAsRefunded` is permissionless after `order.fillDeadline`, rejects orders
///         whose premium has already been settled.
///       - `finaliseAsCancelled` requires maker authorization (either `msg.sender == order.user`
///         or a valid maker cancel signature) and reverts if any fill record exists.
///      Shared lifecycle errors (`NotMaker`, `InvalidOrderStatus`, `InvalidSignature`,
///      `OrderIdMismatch`, `FillAfterDeadline`, `OrderInTerminalState`, `InvalidOutputIndex`,
///      `IntentNotBoundToOrder`, `DigestMismatch`, `NotExpired`, `OrderHasFills`,
///      `InvalidOrderTokenPair`, `InconsistentIntent`) are declared in `RolloverTypes.sol`. Only
///      Exact-specific errors and events live on this interface.
interface IExactFillSettler is IOriginSettler, IDestinationSettler {
    /// @notice Emitted on a successful single-leg fill. Cork records the concrete `outputHash`
    ///         (RFC 003 §A.6) and the filler address so off-chain infra can reconstruct the
    ///         fill ledger from events alone.
    /// @param orderId Canonical order identifier.
    /// @param outputIndex 0 = rollover leg, 1 = premium leg.
    /// @param outputHash `keccak256(abi.encode(Output))` for the filled leg.
    /// @param filler The `msg.sender` that executed the fill.
    event Fill(bytes32 indexed orderId, uint8 indexed outputIndex, bytes32 outputHash, address filler);

    /// @notice Emitted on every terminal transition (settle / refund / cancel) and is the
    ///         canonical off-chain signal that an order's lifecycle has closed.
    /// @param orderId Canonical order identifier.
    /// @param status The terminal `OrderStatus` assigned by the finalise call.
    /// @param orderDigest Order binding digest (always `bytes32(0)` for Exact).
    event OrderFinalised(bytes32 indexed orderId, OrderStatus status, bytes32 orderDigest);

    /// @notice Emitted when a `finaliseAsSettled` payout transfer reverts for the single Exact
    ///         filler and the amount is credited to `rescueableOf(orderId, filler)` for later
    ///         withdrawal. Closes the §39 blacklist-stuck-Opened state on Exact: the order still
    ///         transitions `Opened → Settled` so the lifecycle progresses, but the payout is
    ///         deferred.
    /// @param orderId Canonical order identifier.
    /// @param filler Filler whose payout reverted.
    /// @param amount dstCST credited for later rescue withdrawal.
    /// @param reason Raw revert data bubbled from the caught `safeTransfer` call (verbatim).
    /// @dev `reason` is attacker-influenceable revert data from the filler-destination transfer.
    ///      MUST NOT be used for control-flow decisions off-chain.
    event FillerRescueCredited(bytes32 indexed orderId, address indexed filler, uint256 amount, bytes reason);

    /// @notice Emitted when the Exact filler pulls a previously-stranded dstCST credit via
    ///         `rescueSettled`. The `(orderId, filler)` slot in `_rescueable` is zeroed in the
    ///         same call under CEI, so every emission corresponds to a one-shot withdrawal of the
    ///         credited amount to `fallbackDestination`.
    /// @param orderId Canonical order identifier (Exact's `_rescueable` key).
    /// @param filler Filler whose credit was consumed.
    /// @param fallbackDestination dstCST recipient chosen by the filler's signature.
    /// @param amount dstCST released on this withdrawal (equals the prior credited amount).
    event FillerRescueWithdrawn(
        bytes32 indexed orderId, address indexed filler, address indexed fallbackDestination, uint256 amount
    );

    /// @notice Emitted once per Exact `finaliseAsSettled` call, immediately before the payout
    ///         transfer. Joins three filler identities that SHOULD all match on the happy path:
    ///          - `fillerSlot`     the filler keyed on `_rescueable[orderId][…]` — equals
    ///                             `rolloverRec.filler` (Exact is single-participant).
    ///          - `premiumFiller`  same as `fillerSlot` on Exact — the rollover-leg filler is the
    ///                             settler's canonical attribution target.
    ///          - `cellarFiller`   the filler the cellar latched via `premiumFiredFor` (or zero if
    ///                             the cellar never latched — i.e. the premium hook caught-revert
    ///                             branch fired, see `PremiumHooksReverted`).
    ///         Off-chain consumers MUST treat any drift between these three as an attribution
    ///         anomaly. Closes #47 (M3).
    /// @param orderId Canonical order identifier.
    /// @param fillerSlot Exact's `_rescueable[orderId][…]` key — the rollover-leg filler.
    /// @param premiumFiller Settler-recorded filler identity — equals `fillerSlot` on Exact.
    /// @param cellarFiller Filler identity the cellar latched for this order's premium leg (see
    ///        `premiumFiredFor`). Returns `fillerSlot` on success; `address(0)` when the premium
    ///        hook reverted and the cellar never latched.
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
    ///         reverts. The settler swallows the revert so the `paymentSettled = true` write and
    ///         ERC-6909 debit remain committed — a UW who signs conditionally-reverting
    ///         `premiumHooks` can no longer brick the filler's settle path (AS-10 / #58). The
    ///         premium sits at the cellar until the UW owner recovers it via
    ///         `executeHooks(Call[])`.
    /// @param orderDigest Order binding digest — matches the Partial signature. Exact supplies the
    ///        digest recovered from `_onPremiumLegFill` so off-chain observers can correlate the
    ///        event with the order even though Exact's state is keyed by `orderId`.
    /// @param targetFiller Rollover-leg filler whose premium leg was being settled at catch time.
    ///        On Exact this is always `rolloverRec.filler`, which may differ from `msg.sender`
    ///        of the premium-leg fill (the RFC permits a third party to post the premium). The
    ///        rollover-leg filler is the informative "stranded" party whose `paymentSettled`
    ///        latch and premium-leg `FillRecord` were committed before the caught forward.
    /// @param err Raw revert data bubbled from the caught `executeIntentHooks` call (verbatim).
    /// @dev `err` is attacker-influenceable revert data from UW-controlled cellar hooks. MUST NOT
    ///      be used for control-flow decisions off-chain.
    event PremiumHooksReverted(bytes32 indexed orderDigest, address indexed targetFiller, bytes err);

    /// @notice Second fill against the same `(orderId, outputHash)` pair. INV-S3. Partial-fill
    ///         extension §13.4.
    error AlreadyFilled();

    /// @notice Premium leg attempted before the rollover leg filled. Rollover-first ordering
    ///         (RFC 003 §3.2, INV-S3 second clause).
    error PremiumBeforeRollover();

    /// @notice Rollover leg filler supplied `output.amount != orderSize` — partial fills are not
    ///         permitted under the Exact settler. Partial-fill extension §13.4.
    error PartialFillNotAllowed();

    /// @notice `finaliseAsSettled` called before the premium leg has been settled
    ///         (`paymentSettled == false`). RFC 003 §6.4.1.
    error PaymentNotSettled();

    /// @notice `finaliseAsRefunded` called on an order whose premium has already been settled —
    ///         use the Settled path instead. RFC 003 §6.4.1 (`OrderComplete`).
    error OrderComplete();

    /// @notice `finaliseAsSettled` could not reconstruct a valid fill record for one or more
    ///         outputs (`_validateFillRecords` mismatch). RFC 003 §6.4.1.
    error InvalidFillRecord();

    /// @notice Transitions an `Opened` order to `Settled`, releasing escrowed dstCST to the
    ///         rollover filler's chosen destination. Permissionless; requires both legs filled
    ///         and `paymentSettled == true`.
    /// @dev Reverts with `InvalidOrderStatus` if status is not `Opened`, `PaymentNotSettled` if
    ///      premium was never settled, and `InvalidFillRecord` if the stored fill records do not
    ///      match the caller-supplied solvers. RFC 003 §6.4.1.
    /// @param orderId Canonical order identifier.
    function finaliseAsSettled(bytes32 orderId) external;

    /// @notice Transitions an `Opened` order to `Refunded` after `order.fillDeadline` has passed
    ///         and only when premium was never settled. Returns any escrowed dstCST to the UW's
    ///         cellar; the filler permanently forfeits their srcCST.
    /// @dev Reverts with `NotExpired` before the deadline, `OrderComplete` if premium has been
    ///      settled, and `DigestMismatch` if the caller-supplied `order` does not reproduce
    ///      `orderId`. RFC 003 §6.4.1.
    /// @param orderId Canonical order identifier.
    /// @param order The full `GaslessCrossChainOrder` (used to decode `OrderData` and recover the
    ///        cellar address — not trusted; validated against `orderId`).
    function finaliseAsRefunded(bytes32 orderId, IOriginSettler.GaslessCrossChainOrder calldata order) external;

    /// @notice Filler-authenticated pull path for a stranded dstCST credit booked by
    ///         `finaliseAsSettled` when the payout transfer to `FillRecord.destination` reverted
    ///         (e.g. USDC-style blacklist on the original destination). Permissionless in
    ///         `msg.sender`; authorisation is the filler's own EIP-712 signature over
    ///         `(orderDigest, orderId, fallbackDestination)` under the settler's domain. The
    ///         caller never chooses destinations — only the filler's signed recipient can receive
    ///         funds, so this entry point cannot be used to redirect another filler's credit.
    ///         Closes #44.
    /// @dev Reverts with `InvalidDestination` when `fallbackDestination == address(0)`,
    ///      `InvalidRescueSignature` when `sig` does not recover to `filler` under the settler's
    ///      EIP-712 domain, and `NothingToRescue` when `_rescueable[orderId][filler] == 0`
    ///      (either no prior credit or the slot has already been consumed — the CEI zeroing makes
    ///      signature-replay a no-op revert rather than a silent double-spend). Non-reentrant.
    /// @param orderDigest Order binding digest. Exact ignores this field for state lookups but it
    ///        IS part of the EIP-712 pre-image so the same signed struct shape is valid across
    ///        Partial and Exact settlers. Typically the digest the maker signed at open.
    /// @param orderId Canonical order identifier — Exact's `_rescueable` key.
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

    /// @notice Transitions an `Opened` order to `Cancelled`. Requires maker auth and the absence
    ///         of any fill record against either leg.
    /// @dev Auth model: the settler accepts the call iff `msg.sender == order.user` OR
    ///      `cancelSig` is a valid maker signature over `orderId` (see RFC 003 lines 2380–2400).
    ///      Reverts with `NotMaker` / `InvalidSignature` on auth failure, `OrderHasFills` if any
    ///      fill record exists, and `DigestMismatch` if `order` does not reproduce `orderId`. No
    ///      timestamp check — cancel is available any time before fills arrive.
    /// @param orderId Canonical order identifier.
    /// @param order The full `GaslessCrossChainOrder`.
    /// @param cancelSig Maker's cancel signature over `orderId`. Ignored when
    ///        `msg.sender == order.user`.
    function finaliseAsCancelled(
        bytes32 orderId,
        IOriginSettler.GaslessCrossChainOrder calldata order,
        bytes calldata cancelSig
    ) external;
}
