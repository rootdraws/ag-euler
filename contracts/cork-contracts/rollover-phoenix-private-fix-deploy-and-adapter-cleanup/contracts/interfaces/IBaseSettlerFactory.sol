// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IBaseSettlerFactory
/// @notice Exposes the `factory()` immutable accessor that `BaseSettler` (and therefore both
///         `ExactFillSettler` and `PartialFillSettler`) provides. Extracted so fillers and other
///         integrators can read the settler's bound factory without importing the full settler
///         surface.
interface IBaseSettlerFactory {
    /// @notice The `CorkCellarFactory` the settler is bound to at construction.
    function factory() external view returns (address);
}
