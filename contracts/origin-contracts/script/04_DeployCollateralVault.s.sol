// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployCollateralVault
/// @notice Step 4 of 6: Deploy the ARM-WETH-stETH collateral vault.
///
/// @dev Collateral vaults set oracle=address(0) and unitOfAccount=address(0).
///      Pricing happens on the borrow vault side via the EulerRouter.
///
/// @dev Run:
///      source .env && forge script script/04_DeployCollateralVault.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste ARM_COLLATERAL_VAULT=<address> into .env,
///      then run 05_WireOracle.s.sol
contract DeployCollateralVault is Script {
    function run() external {
        vm.startBroadcast();

        address armVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.ARM_WETH_STETH, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: ARM Collateral Vault ===");
        console.log("ARM_COLLATERAL_VAULT=%s", armVault);
        console.log("\nPaste into .env, then run 05_WireOracle.s.sol");
    }
}
