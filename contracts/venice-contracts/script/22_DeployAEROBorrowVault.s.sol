// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 22_DeployAEROBorrowVault
/// @notice Step 22: Deploy AERO borrow vault using the VVV cluster's shared EulerRouter.
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env (from step 3)
///
/// @dev Run:
///      source .env && forge script script/22_DeployAEROBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste AERO_BORROW_VAULT into .env
contract DeployAEROBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address aeroBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.AERO, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 22 COMPLETE: AERO Borrow Vault ===");
        console.log("AERO_BORROW_VAULT=%s", aeroBorrowVault);
        console.log("  Asset:          AERO (%s)", Addresses.AERO);
        console.log("  Oracle:         %s (shared VVV router)", router);
        console.log("  UnitOfAccount:  USD");
        console.log("\nPaste into .env, then run 23_DeployAEROCollateralVault.s.sol");
    }
}
