// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved. Only used in tests — not shipped as part of
// the deployed contracts.
/// @dev Forked from cellar-private@e194384/test/lib/LibAuthenticatedHooksCalldataProxy.sol.
///      Re-sync on lib/cellar bumps that classify as rollover-affecting (see
///      plan/implementation-plan.md → Mid-plan submodule bump procedure).

import {CellarIntent} from "cellar/ICorkCellar.sol";
import {Call, LibAuthenticatedHooks} from "cellar/LibAuthenticatedHooks.sol";

/// @dev wrapper contract since the LibAuthenticatedHooks library only accepts
///      `calldata` params, not `memory` params.
contract LibAuthenticatedHooksCalldataProxy {
    function executeHooksMessageHash(Call[] calldata calls, bytes32 nonce, uint256 deadline)
        external
        pure
        returns (bytes32)
    {
        return LibAuthenticatedHooks.executeHooksMessageHash(calls, nonce, deadline);
    }

    function hashToSign(Call[] calldata calls, bytes32 nonce, uint256 deadline, bytes32 domainSeparator)
        external
        pure
        returns (bytes32)
    {
        return LibAuthenticatedHooks.hashToSign(calls, nonce, deadline, domainSeparator);
    }

    function callsHash(Call[] calldata calls) external pure returns (bytes32) {
        return LibAuthenticatedHooks.callsHash(calls);
    }

    function callHash(Call calldata cll) external pure returns (bytes32) {
        return LibAuthenticatedHooks.callHash(cll);
    }

    function decodeEOASignature(bytes calldata signature) external pure returns (bytes32 r, bytes32 s, uint8 v) {
        return LibAuthenticatedHooks.decodeEOASignature(signature);
    }

    function cellarIntentStructHash(CellarIntent calldata intent) external pure returns (bytes32) {
        return LibAuthenticatedHooks.cellarIntentStructHash(intent);
    }

    function cellarIntentHashToSign(CellarIntent calldata intent, bytes32 domainSeparator)
        external
        pure
        returns (bytes32)
    {
        return LibAuthenticatedHooks.cellarIntentHashToSign(intent, domainSeparator);
    }

    function authenticateCellarIntent(
        CellarIntent calldata intent,
        address user,
        bytes calldata signature,
        bytes32 domainSeparator
    ) external view returns (bool) {
        return LibAuthenticatedHooks.authenticateCellarIntent(intent, user, signature, domainSeparator);
    }
}
