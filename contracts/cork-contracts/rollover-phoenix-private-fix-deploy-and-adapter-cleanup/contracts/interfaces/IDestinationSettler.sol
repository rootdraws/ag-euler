// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IDestinationSettler
/// @notice ERC-7683 destination-chain settler interface. A filler executes a single leg of an
///         already-opened (or to-be-opened) cross-chain order by calling `fill`.
/// @dev This interface is reproduced verbatim from the ERC-7683 specification. Cork rollover
///      orders are same-chain; the same contract implements both `IOriginSettler` and
///      `IDestinationSettler`. For Cork `originData` is `abi.encode(GaslessCrossChainOrder)` and
///      `fillerData` is prefixed with a `uint8 outputIndex` selecting the target leg (RFC 003
///      §A.9 / §A.10).
interface IDestinationSettler {
    /// @notice Fills a single leg of an order.
    /// @dev Cork implementations require `keccak256` of the decoded order from `originData` to
    ///      reproduce `orderId`; mismatch reverts. `fillerData`'s leading byte selects the leg:
    ///      0 = rollover, 1 = premium. Premium-leg fills require the rollover leg to already be
    ///      filled (rollover-first ordering, RFC 003 §3.2). Implementations MAY accept fills when
    ///      the order has not yet been opened (ERC-7683 permits fill-before-open).
    /// @param orderId Canonical order identifier as produced by `IOriginSettler.resolve` /
    ///        `resolveFor`.
    /// @param originData Application-specific origin-side data. Cork: `abi.encode(order)`.
    /// @param fillerData Application-specific filler-provided data. Cork: `uint8 outputIndex`
    ///        prefix followed by a leg-specific encoded struct (see RFC 003 §A.10).
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}
