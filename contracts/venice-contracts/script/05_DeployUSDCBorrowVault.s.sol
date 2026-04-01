// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 05_DeployUSDCBorrowVault
/// @notice Step 5 of 10: Deploy the USDC borrow vault (Market 2: borrow USDC against VVV + WETH).
///
/// @dev Unit of account = USD (address(840)). Same router as the VVV borrow vault.
///
///      trailingData = abi.encodePacked(USDC, router, USD)
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/05_DeployUSDCBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste USDC_BORROW_VAULT=<address> into .env
contract DeployUSDCBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address usdcBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDC, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: USDC Borrow Vault ===");
        console.log("USDC_BORROW_VAULT=%s", usdcBorrowVault);
        console.log("  asset:         USDC (%s)", Addresses.USDC);
        console.log("  oracle:        %s", router);
        console.log("  unitOfAccount: USD (%s)", Addresses.USD);
        console.log("\nPaste into .env, then run 06_DeployETHBorrowVault.s.sol");
    }
}
