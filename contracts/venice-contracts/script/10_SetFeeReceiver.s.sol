// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
    function feeReceiver() external view returns (address);
}

/// @title 10_SetFeeReceiver
/// @notice Step 10 of 10: Set the fee receiver on all three borrow vaults.
///
/// @dev Run:
///      source .env && forge script script/10_SetFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract SetFeeReceiver is Script {
    function run() external {
        address vvvBorrowVault  = vm.envAddress("VVV_BORROW_VAULT");
        address usdcBorrowVault = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault  = vm.envAddress("ETH_BORROW_VAULT");
        address feeReceiver     = vm.envAddress("FEE_RECEIVER");

        require(feeReceiver != address(0), "FEE_RECEIVER not set");

        vm.startBroadcast();

        IEVault(vvvBorrowVault).setFeeReceiver(feeReceiver);
        IEVault(usdcBorrowVault).setFeeReceiver(feeReceiver);
        IEVault(ethBorrowVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("\n=== STEP 10 COMPLETE: Fee Receivers Set ===");
        console.log("Fee receiver: %s", feeReceiver);
        console.log("  VVV borrow vault:  %s", vvvBorrowVault);
        console.log("  USDC borrow vault: %s", usdcBorrowVault);
        console.log("  ETH borrow vault:  %s", ethBorrowVault);
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Next steps:");
        console.log("  1. Add vault addresses to labels (products.json, vaults.json, entities.json)");
        console.log("  2. Transfer governor to multisig");
    }
}
