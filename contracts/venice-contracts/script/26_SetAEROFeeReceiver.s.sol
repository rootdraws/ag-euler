// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
}

/// @title 26_SetAEROFeeReceiver
/// @notice Step 26: Set fee receiver on AERO borrow vault.
///
/// @dev Prerequisites: AERO_BORROW_VAULT, FEE_RECEIVER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/26_SetAEROFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract SetAEROFeeReceiver is Script {
    function run() external {
        address aeroBorrowVault = vm.envAddress("AERO_BORROW_VAULT");
        address feeReceiver     = vm.envAddress("FEE_RECEIVER");

        vm.startBroadcast();

        IEVault(aeroBorrowVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("\n=== STEP 26 COMPLETE: AERO Fee Receiver Set ===");
        console.log("AERO Borrow Vault: %s", aeroBorrowVault);
        console.log("Fee Receiver:      %s", feeReceiver);
        console.log("\n=== AERO DEPLOYMENT TO VVV CLUSTER COMPLETE ===");
        console.log("Next: update labels (products.json, vaults.json, entities.json)");
    }
}
