// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal ERC-1271 mock: returns magic value when the digest matches an authorized value.
contract MockERC1271Signer {
    bytes32 private _authorizedDigest;

    function authorize(bytes32 digest) external {
        _authorizedDigest = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == _authorizedDigest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
