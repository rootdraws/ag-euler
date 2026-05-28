// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployBorrowVault
/// @notice Step 3 of 7: Deploy the USDC borrow vault.
///
/// @dev Unit of account = USDC (matches borrow asset). The collateral oracle
///      (PileInclusiveOracle) returns USDC-denominated quotes directly (6 dec),
///      so no USD/USDC indirection is needed.
///
///      trailingData = abi.encodePacked(asset, oracle, unitOfAccount) = 60 bytes.
///
/// @dev Prerequisites (in .env): EULER_ROUTER
///
/// @dev Run:
///      source .env && forge script script/03_DeployBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste USDC_BORROW_VAULT=<address> into .env, then run 04_DeployCollateralVault.s.sol
contract DeployBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address usdcBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDC, router, Addresses.USDC)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: USDC Borrow Vault ===");
        console.log("USDC_BORROW_VAULT=%s", usdcBorrowVault);
        console.log("  asset:          %s (USDC)", Addresses.USDC);
        console.log("  oracle:         %s (EulerRouter)", router);
        console.log("  unitOfAccount:  %s (USDC)", Addresses.USDC);
        console.log("\nPaste into .env, then run 04_DeployCollateralVault.s.sol");
    }
}
