// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 13_DeployZROBorrowVault
/// @notice Step 13: Deploy ZRO borrow vault using the VVV cluster's shared EulerRouter.
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env (from step 3)
///
/// @dev Run:
///      source .env && forge script script/13_DeployZROBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste ZRO_BORROW_VAULT into .env
contract DeployZROBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address zroBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.ZRO, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 13 COMPLETE: ZRO Borrow Vault ===");
        console.log("ZRO_BORROW_VAULT=%s", zroBorrowVault);
        console.log("  Asset:          ZRO (%s)", Addresses.ZRO);
        console.log("  Oracle:         %s (shared VVV router)", router);
        console.log("  UnitOfAccount:  USD");
        console.log("\nPaste into .env, then run 14_DeployZROCollateralVault.s.sol");
    }
}
