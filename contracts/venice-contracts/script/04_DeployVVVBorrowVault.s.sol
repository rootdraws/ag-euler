// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployVVVBorrowVault
/// @notice Step 4 of 10: Deploy the VVV borrow vault (Market 1: borrow VVV against USDC + WETH).
///
/// @dev Unit of account = USD (address(840)). Both VVV and USDC have Chainlink USD feeds,
///      so USD is the natural unit of account for cross-pricing.
///
///      trailingData = abi.encodePacked(VVV, router, USD)
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/04_DeployVVVBorrowVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste VVV_BORROW_VAULT=<address> into .env
contract DeployVVVBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address vvvBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.VVV, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: VVV Borrow Vault ===");
        console.log("VVV_BORROW_VAULT=%s", vvvBorrowVault);
        console.log("  asset:         VVV (%s)", Addresses.VVV);
        console.log("  oracle:        %s", router);
        console.log("  unitOfAccount: USD (%s)", Addresses.USD);
        console.log("\nPaste into .env, then run 05_DeployUSDCBorrowVault.s.sol");
    }
}
