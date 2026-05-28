// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IEvcExactFillAdapter
/// @notice EVC-aware Exact-bound reference adapter for rollover orders. Per-subaccount threat
///         model: one deployed instance per `AUTHORIZED_CALLER` (curator subaccount), bound at
///         deploy time through an EVC `onBehalfOfAccount` check inside `execute`.
/// @dev Drives `ExactFillSettler.fill(orderId, ...)` from inside an `EthereumVaultConnector`
///      batch or call. Exposes the same `execute` signature as `IExactRolloverFiller` (DP-B
///      parity) but resolves the real caller via the EVC's authenticated execution context and
///      assumes srcCST is seeded on the adapter by a prior batch item rather than pulled from
///      `msg.sender`.
///
///      ## Caller resolution
///      Two guards inside `execute`:
///       1. `msg.sender == EVC` — reject direct calls up front.
///       2. `IEVC(EVC).getCurrentOnBehalfOfAccount(address(0)) == AUTHORIZED_CALLER` — reject any
///          subaccount other than the one this adapter was deployed for.
///
///      Deploying one adapter per subaccount (DP-EVC-A) prevents cross-caller theft: a shared
///      adapter would let any EVC user drain srcCST pre-seeded by another curator or debit any
///      premium source that authorised the adapter. See RFC 003 §7.3.
///
///      ## Pre-balance seeding & no-sweep-of-leftovers
///      The adapter does NOT pull srcCST from `msg.sender`; a prior batch item must have seeded
///      `balanceOf(adapter) >= srcCstAmount`. Leftover srcCST is retained on the adapter —
///      curators compose a sibling batch item to sweep. See `IEvcPartialFillAdapter` for the
///      identical policy on the Partial path.
interface IEvcExactFillAdapter {
    /// @notice `destination` was `address(0)`. Fails before EVC caller resolution.
    error EvcExactFillAdapter__ZeroDestination();

    /// @notice Raised on any invalid-caller branch of the EVC auth check. Also raised by the
    ///         constructor when `authorizedCaller_` is `address(0)`.
    error EvcExactFillAdapter__InvalidCaller();

    /// @notice The adapter's pre-entry balance of `token` was below `required`. A prior batch
    ///         item was expected to seed the adapter.
    error EvcExactFillAdapter__InsufficientTokens(address token, uint256 required, uint256 available);

    /// @notice Constructor-time guard: the supplied `settler_` did not match the Exact shape.
    error EvcExactFillAdapter__SettlerMismatch();

    /// @notice Constructor-time guard: the Exact path does not use `FACTORY`, so the caller MUST
    ///         pass `address(0)`. Any other value would silently bind a stale factory.
    error EvcExactFillAdapter__FactoryMustBeZero(address supplied);

    /// @notice Constructor-time guard: `evc_` was `address(0)`. A null EVC dependency would leave
    ///         the adapter unable to authenticate its caller.
    error EvcExactFillAdapter__ZeroEvc();

    /// @notice The adapter's deployment-time `AUTHORIZED_CALLER` — the one EVC subaccount this
    ///         adapter will accept on every `execute`.
    function AUTHORIZED_CALLER() external view returns (address);

    /// @notice Execute both legs of an Exact rollover order atomically from within an EVC frame.
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external;
}
