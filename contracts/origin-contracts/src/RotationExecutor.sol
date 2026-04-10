// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title RotationExecutor
/// @notice One-shot governance rotation helper for the compromised deployer EOA
///         `0x5304ebB378186b081B99dbb8B6D17d9005eA0448`, via EIP-7702 delegation.
///
/// @dev Usage: install this contract as the 7702 delegation target of
///      `0x5304eb…0448` and call `rotate()` on that address. Since delegated
///      code runs in the EOA's own context, the three sub-calls below execute
///      with `msg.sender == 0x5304eb…0448`, which is still the current
///      governor of all three targets.
///
/// @dev All targets are hardcoded. No params, no owner, no upgrades.
///      Permissionless by design — after rotation there is nothing left to
///      protect at the old governor, and anyone calling `rotate()` just
///      re-executes an idempotent no-op.
contract RotationExecutor {
    address constant EULER_ROUTER    = 0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3;
    address constant COLLATERAL_VAULT = 0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd;
    address constant BORROW_VAULT    = 0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B;
    address constant AG_MULTISIG     = 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C;

    error RouterRotationFailed();
    error CollateralRotationFailed();
    error BorrowRotationFailed();

    function rotate() external {
        (bool ok1, ) = EULER_ROUTER.call(
            abi.encodeWithSignature("transferGovernance(address)", AG_MULTISIG)
        );
        if (!ok1) revert RouterRotationFailed();

        (bool ok2, ) = COLLATERAL_VAULT.call(
            abi.encodeWithSignature("setGovernorAdmin(address)", AG_MULTISIG)
        );
        if (!ok2) revert CollateralRotationFailed();

        (bool ok3, ) = BORROW_VAULT.call(
            abi.encodeWithSignature("setGovernorAdmin(address)", AG_MULTISIG)
        );
        if (!ok3) revert BorrowRotationFailed();
    }
}
