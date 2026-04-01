// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
    function feeReceiver() external view returns (address);
}

/// @title 07_SetFeeReceiver
/// @notice Step 7 of 7: Set the fee receiver on the ZRO borrow vault.
///   The USDC vault's fee receiver is managed by the co-worker.
///
/// @dev Usage:
///   source .env
///   forge script script/07_SetFeeReceiver.s.sol:SetFeeReceiver \
///     --rpc-url base --broadcast -vvvv
contract SetFeeReceiver is Script {
    function run() external {
        address zroVault    = vm.envAddress("ZRO_BORROW_VAULT");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");

        require(feeReceiver != address(0), "FEE_RECEIVER not set");

        vm.startBroadcast();

        IEVault(zroVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("=== STEP 7 COMPLETE: Fee Receiver Set ===");
        console.log("Fee receiver: %s", feeReceiver);
        console.log("  ZRO vault: %s", zroVault);
        console.log("\nDeployment complete! Post-deploy:");
        console.log("  1. Verify oracle prices resolve correctly");
        console.log("  2. Add labels (products.json, vaults.json, entities.json)");
        console.log("  3. Transfer governance to multisig");
    }
}
