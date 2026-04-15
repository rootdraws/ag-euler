// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployCollateralVaults
/// @notice Step 4 of 7: Deploy passive collateral vaults for USDT and BNB.
///
/// @dev Collateral vaults have oracle=address(0), unitOfAccount=address(0).
///      Pricing is handled by the borrow vault's router.
///
/// @dev Run:
///      source .env && forge script script/04_DeployCollateralVaults.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
contract DeployCollateralVaults is Script {
    function run() external {
        vm.startBroadcast();

        address usdtCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDT, address(0), address(0))
        );

        address bnbCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WBNB, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: Collateral Vaults ===");
        console.log("USDT_COLLATERAL_VAULT=%s", usdtCollVault);
        console.log("BNB_COLLATERAL_VAULT=%s",  bnbCollVault);
        console.log("\nPaste into .env, then run 05_WireOracle.s.sol");
    }
}
