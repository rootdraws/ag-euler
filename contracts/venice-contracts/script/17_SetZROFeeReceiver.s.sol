// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
}

/// @title 17_SetZROFeeReceiver
/// @notice Step 17: Set fee receiver on ZRO borrow vault.
///
/// @dev Prerequisites: ZRO_BORROW_VAULT, FEE_RECEIVER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/17_SetZROFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract SetZROFeeReceiver is Script {
    function run() external {
        address zroBorrowVault = vm.envAddress("ZRO_BORROW_VAULT");
        address feeReceiver    = vm.envAddress("FEE_RECEIVER");

        vm.startBroadcast();

        IEVault(zroBorrowVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("\n=== STEP 17 COMPLETE: ZRO Fee Receiver Set ===");
        console.log("ZRO Borrow Vault: %s", zroBorrowVault);
        console.log("Fee Receiver:     %s", feeReceiver);
        console.log("\n=== ZRO DEPLOYMENT TO VVV CLUSTER COMPLETE ===");
        console.log("Next: update labels (products.json, vaults.json, entities.json)");
    }
}
