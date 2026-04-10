// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title GenericRotator
/// @notice Stateless multicall executor used as an EIP-7702 delegation target for
///         the compromised deployer EOA. When installed via 7702, calling
///         `rotate(calls)` on the delegated EOA executes each call with
///         `msg.sender == EOA` — exactly the authority needed to transfer
///         governance on all previously-deployed contracts.
///
/// @dev Permissionless by design. Once governance has been rotated off the
///      compromised EOA, there is nothing left to protect, so the absence of
///      access control is acceptable.
contract GenericRotator {
    struct Call {
        address target;
        bytes data;
    }

    function rotate(Call[] calldata calls) external {
        uint256 len = calls.length;
        for (uint256 i; i < len; ) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                // bubble up revert reason
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            unchecked { ++i; }
        }
    }
}
