// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
}

/// @title 07_SetVIRTUALFeeReceiver
/// @notice Step 7: Set fee receiver on VIRTUAL borrow vault.
///
/// @dev Prerequisites: VIRTUAL_BORROW_VAULT, FEE_RECEIVER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/07_SetVIRTUALFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract SetVIRTUALFeeReceiver is Script {
    function run() external {
        address virtualBorrowVault = vm.envAddress("VIRTUAL_BORROW_VAULT");
        address feeReceiver        = vm.envAddress("FEE_RECEIVER");

        vm.startBroadcast();

        IEVault(virtualBorrowVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: VIRTUAL Fee Receiver Set ===");
        console.log("VIRTUAL Borrow Vault: %s", virtualBorrowVault);
        console.log("Fee Receiver:         %s", feeReceiver);
        console.log("\n=== VIRTUAL DEPLOYMENT TO VVV CLUSTER COMPLETE ===");
        console.log("Next: update labels (products.json, vaults.json, entities.json)");
    }
}
