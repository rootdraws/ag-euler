// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployVIRTUALCollateralVault
/// @notice Step 4: Deploy VIRTUAL collateral vault.
///
/// @dev Collateral vaults set oracle=address(0) and unitOfAccount=address(0).
///      Pricing is handled by the borrow vault's oracle router.
///
/// @dev Run:
///      source .env && forge script script/04_DeployVIRTUALCollateralVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste VIRTUAL_COLLATERAL_VAULT into .env
contract DeployVIRTUALCollateralVault is Script {
    function run() external {
        vm.startBroadcast();

        address virtualCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.VIRTUAL, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: VIRTUAL Collateral Vault ===");
        console.log("VIRTUAL_COLLATERAL_VAULT=%s", virtualCollVault);
        console.log("\nPaste into .env, then run 05_WireVIRTUALOracle.s.sol");
    }
}
