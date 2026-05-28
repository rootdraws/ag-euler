// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IExactRolloverFiller
/// @notice Cork reference Exact-bound filler for rollover orders. Shared-singleton threat model:
///         one deployed instance services every caller. Caller identity is bound through an
///         ERC-6909-operator check inside `execute` (Pashov A2) rather than at deploy time, so
///         the contract MUST NOT assume a trusted caller.
/// @dev Drives `ExactFillSettler.fill(orderId, ...)` through both legs of a rollover order in a
///      single call. See RFC 003 §7.2 for the shared-singleton threat model and `LibFillerExecute`
///      for the shared orchestration primitives. Paired with `IPartialRolloverFiller` — both
///      fillers share this threat model but differ on the settler class they drive.
///
///      ### Custody contract
///      - srcCST: pulled from `msg.sender` via `transferFrom`; any leftover is returned to the
///        caller at the end of `execute`.
///      - Premium: never passes through the filler. Premium flows via the ERC-6909 premium
///        contract; the filler only triggers the premium leg — the settler performs the debit.
///      - Persistent-state invariants (across every `execute`): zero token holdings, zero non-zero
///        approvals.
///
///      All reverts from the underlying settler or cellar bubble through unchanged.
interface IExactRolloverFiller {
    /// @notice `destination` was `address(0)`. The rollover leg requires a non-zero dstCST
    ///         recipient — this guard fails fast before any settler call.
    error ExactRolloverFiller__ZeroDestination();

    /// @notice Constructor-time guard: the supplied `settler_` did not match the Exact shape.
    ///         Both settler classes inherit `factory()`, so a stray `(partialSettler, ...)` would
    ///         otherwise revert only on first `execute`. The filler probes a Partial-only
    ///         selector at deploy time and refuses Partial settlers up front.
    error ExactRolloverFiller__SettlerMismatch();

    /// @notice Constructor-time guard: the Exact path does not use `FACTORY`, so the caller MUST
    ///         pass `address(0)`. Any other value would silently bind a stale factory.
    error ExactRolloverFiller__FactoryMustBeZero(address supplied);

    /// @notice The `debitFrom` account has not authorised `msg.sender` as an ERC-6909 operator on
    ///         the premium ledger. Without this caller-side check a singleton filler would let
    ///         any caller name any `debitFrom` that authorised the filler, draining the victim's
    ///         premium balance into the caller's fill. Pairs with the settler-side dual-auth
    ///         (INV-E2) to enforce the same policy on both sides of the handoff.
    /// @param debitFrom The premium source the caller tried to debit.
    /// @param caller The `msg.sender` that failed the authorisation check.
    error DebitFromNotAuthorizedByCaller(address debitFrom, address caller);

    /// @notice Execute both legs of an Exact rollover order atomically. See `LibFillerExecute`
    ///         for the shared orchestration flow. Either both legs settle and the call returns
    ///         normally, or the whole transaction reverts.
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external;
}
