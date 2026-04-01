// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 06_DeployETHBorrowVault
/// @notice Step 6 of 10: Deploy the WETH borrow vault (borrow ETH against USDC and VVV).
///
/// @dev Unit of account = USD (address(840)). Same router as VVV and USDC borrow vaults.
///
///      trailingData = abi.encodePacked(WETH, router, USD)
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/06_DeployETHBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste ETH_BORROW_VAULT=<address> into .env
contract DeployETHBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address ethBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WETH, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: ETH Borrow Vault ===");
        console.log("ETH_BORROW_VAULT=%s", ethBorrowVault);
        console.log("  asset:         WETH (%s)", Addresses.WETH);
        console.log("  oracle:        %s", router);
        console.log("  unitOfAccount: USD (%s)", Addresses.USD);
        console.log("\nPaste into .env, then run 07_DeployCollateralVaults.s.sol");
    }
}
