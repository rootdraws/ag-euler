// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 14_DeployZROCollateralVault
/// @notice Step 14: Deploy ZRO collateral vault.
///
/// @dev Collateral vaults set oracle=address(0) and unitOfAccount=address(0).
///      Pricing is handled by the borrow vault's oracle router.
///
/// @dev Run:
///      source .env && forge script script/14_DeployZROCollateralVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste ZRO_COLLATERAL_VAULT into .env
contract DeployZROCollateralVault is Script {
    function run() external {
        vm.startBroadcast();

        address zroCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.ZRO, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 14 COMPLETE: ZRO Collateral Vault ===");
        console.log("ZRO_COLLATERAL_VAULT=%s", zroCollVault);
        console.log("\nPaste into .env, then run 15_WireZROOracle.s.sol");
    }
}
