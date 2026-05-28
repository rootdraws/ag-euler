// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IEvcPartialFillAdapter
/// @notice EVC-aware Partial-bound reference adapter for rollover orders. Per-subaccount threat
///         model: one deployed instance per `AUTHORIZED_CALLER` (curator subaccount), bound at
///         deploy time through an EVC `onBehalfOfAccount` check inside `execute`.
/// @dev Drives `PartialFillSettler.fill(orderId, ...)` from inside an `EthereumVaultConnector`
///      batch or call. Shares the `execute` signature with `IEvcExactFillAdapter` (DP-B parity)
///      and the same caller-resolution / pre-balance-seeding / no-sweep-of-leftovers policies.
///      See RFC 003 §7.3 and the contract-level NatSpec on `IEvcExactFillAdapter` for the full
///      trust model.
///
///      Partial-specific note: `PartialFillSettler` keys per-filler state on `msg.sender` (the
///      adapter). Because each subaccount deploys its own adapter, per-filler accounting is
///      naturally partitioned — a shared Partial adapter would collapse every subaccount into
///      one slot and revert on the second fill.
interface IEvcPartialFillAdapter {
    /// @notice `destination` was `address(0)`. Fails before EVC caller resolution.
    error EvcPartialFillAdapter__ZeroDestination();

    /// @notice Raised on any invalid-caller branch of the EVC auth check. Also raised by the
    ///         constructor when `authorizedCaller_` is `address(0)`.
    error EvcPartialFillAdapter__InvalidCaller();

    /// @notice The adapter's pre-entry balance of `token` was below `required`. A prior batch
    ///         item was expected to seed the adapter.
    error EvcPartialFillAdapter__InsufficientTokens(address token, uint256 required, uint256 available);

    /// @notice Constructor-time guard: the supplied `settler_` did not match the Partial shape.
    error EvcPartialFillAdapter__SettlerMismatch();

    /// @notice Constructor-time guard: the `expectedFactory_` argument did not match
    ///         `settler_.factory()`. Forcing the caller to name the factory makes misconfigured
    ///         settlers visible at deploy time rather than on first cellar interaction.
    error EvcPartialFillAdapter__FactoryMismatch(address expected, address actual);

    /// @notice Constructor-time guard: `evc_` was `address(0)`.
    error EvcPartialFillAdapter__ZeroEvc();

    /// @notice The adapter's deployment-time `AUTHORIZED_CALLER` — the one EVC subaccount this
    ///         adapter will accept on every `execute`.
    function AUTHORIZED_CALLER() external view returns (address);

    /// @notice Execute both legs of a Partial rollover order atomically from within an EVC frame.
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external;
}
