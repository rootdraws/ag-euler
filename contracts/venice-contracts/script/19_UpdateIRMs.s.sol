// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setInterestRateModel(address irm) external;
}

/// @title 19_UpdateIRMs
/// @notice Step 19: Update the interest rate models on the USDC and ETH borrow vaults.
///
/// @dev Prerequisites (must be set in .env):
///      USDC_IRM, ETH_IRM (deployed in step 18)
///      USDC_BORROW_VAULT, ETH_BORROW_VAULT
///
/// @dev Run:
///      source .env && forge script script/19_UpdateIRMs.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract UpdateIRMs is Script {
    function run() external {
        address usdcIrm         = vm.envAddress("USDC_IRM");
        address ethIrm          = vm.envAddress("ETH_IRM");
        address usdcBorrowVault = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault  = vm.envAddress("ETH_BORROW_VAULT");

        vm.startBroadcast();

        IEVault(usdcBorrowVault).setInterestRateModel(usdcIrm);
        IEVault(ethBorrowVault).setInterestRateModel(ethIrm);

        vm.stopBroadcast();

        console.log("\n=== STEP 19 COMPLETE: IRMs Updated ===");
        console.log("USDC Borrow Vault %s -> IRM %s", usdcBorrowVault, usdcIrm);
        console.log("ETH Borrow Vault  %s -> IRM %s", ethBorrowVault, ethIrm);
    }
}
