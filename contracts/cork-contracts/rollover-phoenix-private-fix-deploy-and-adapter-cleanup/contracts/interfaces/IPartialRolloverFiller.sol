// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPartialRolloverFiller
/// @notice Cork reference Partial-bound filler for rollover orders. Shared-singleton threat model:
///         one deployed instance services every caller, with caller identity bound through an
///         ERC-6909-operator check inside `execute` (Pashov A2).
/// @dev Drives `PartialFillSettler.fill(orderId, ...)` through both legs of a rollover order in
///      one call. `PartialFillSettler` keys per-filler accounting on `msg.sender`, so every
///      caller that shares this filler shares the filler's per-order state; the reference
///      deployment is a canonical binding only, and production callers SHOULD deploy their own
///      filler instance if they want isolated Partial accounting.
///
///      See RFC 003 §7.2 for the shared-singleton threat model and `LibFillerExecute` for the
///      shared orchestration primitives.
interface IPartialRolloverFiller {
    /// @notice `destination` was `address(0)`. The rollover leg requires a non-zero dstCST
    ///         recipient — this guard fails fast before any settler call.
    error PartialRolloverFiller__ZeroDestination();

    /// @notice Constructor-time guard: the supplied `settler_` did not match the Partial shape.
    ///         The filler probes a Partial-only selector at deploy time; the probe must succeed.
    error PartialRolloverFiller__SettlerMismatch();

    /// @notice Constructor-time guard: the `expectedFactory_` argument did not match
    ///         `settler_.factory()`. Forcing the caller to name the factory makes misconfigured
    ///         settlers visible at deploy time rather than on first cellar interaction.
    error PartialRolloverFiller__FactoryMismatch(address expected, address actual);

    /// @notice The `debitFrom` account has not authorised `msg.sender` as an ERC-6909 operator on
    ///         the premium ledger. See `IExactRolloverFiller.DebitFromNotAuthorizedByCaller` for
    ///         the full rationale — identical semantics on the Partial path.
    /// @param debitFrom The premium source the caller tried to debit.
    /// @param caller The `msg.sender` that failed the authorisation check.
    error DebitFromNotAuthorizedByCaller(address debitFrom, address caller);

    /// @notice Execute both legs of a Partial rollover order atomically. The filler submits
    ///         itself as the sole entry of the `fillers[]` array passed to
    ///         `PartialFillSettler.finaliseAsSettled(orderDigest, fillers)`.
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external;
}
