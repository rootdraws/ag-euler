// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployVIRTUALBorrowVault
/// @notice Step 3: Deploy VIRTUAL borrow vault using the VVV cluster's shared EulerRouter.
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/03_DeployVIRTUALBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste VIRTUAL_BORROW_VAULT into .env
contract DeployVIRTUALBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address virtualBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.VIRTUAL, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: VIRTUAL Borrow Vault ===");
        console.log("VIRTUAL_BORROW_VAULT=%s", virtualBorrowVault);
        console.log("  Asset:          VIRTUAL (%s)", Addresses.VIRTUAL);
        console.log("  Oracle:         %s (shared VVV router)", router);
        console.log("  UnitOfAccount:  USD");
        console.log("\nPaste into .env, then run 04_DeployVIRTUALCollateralVault.s.sol");
    }
}
