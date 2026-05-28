// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IBaseSettlerPremium
/// @notice Minimal view into `BaseSettler`'s public immutable premium-ledger accessor. Used by
///         shared-singleton fillers to authorise `debitFrom` against `msg.sender` before handing
///         off to the settler (Pashov A2 caller-side dual-auth check).
/// @dev Only the shared-singleton reference fillers (`ExactRolloverFiller`,
///      `PartialRolloverFiller`) need this shape. The EVC adapters authenticate via
///      `getCurrentOnBehalfOfAccount` and never do A2, so they do not import this interface.
interface IBaseSettlerPremium {
    /// @notice Returns the ERC-6909 premium ledger bound to this settler.
    /// @return premium Address of the `ERC6909Premium` contract.
    function erc6909Premium() external view returns (address premium);
}
