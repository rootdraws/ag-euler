// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ICorkCellarPremiumView
/// @notice Narrow view of the per-`(orderDigest, filler)` premium-phase latch on the Cork
///         cellar. The full `ICorkCellar` interface lives in the cellar-private submodule and
///         does not declare `premiumFiredFor`, even though the concrete `CorkCellar`
///         implementation exposes it as `function premiumFiredFor(bytes32, address) view returns
///         (bool)`. This local interface is declared here so `BaseSettler` can assert
///         settler-cellar state parity on the premium-leg success branch (#61 / I4) without
///         editing the cross-repo interface. If/when `ICorkCellar` upstream adopts
///         `premiumFiredFor`, this interface can be replaced by that import.
/// @dev This is a cross-repo ABI element — the selector of `premiumFiredFor(bytes32, address)`
///      must match the cellar-side implementation. Do not rename.
interface ICorkCellarPremiumView {
    /// @notice Returns true iff the cellar has latched the premium-phase firing for
    ///         `(orderDigest, filler)`. Flipped inside `_runPremiumPhase` of the live
    ///         `CorkCellar` implementation once the filler's `premiumHooks` succeed.
    function premiumFiredFor(bytes32 orderDigest, address filler) external view returns (bool);
}
