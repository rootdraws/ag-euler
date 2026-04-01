// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 07_DeployCollateralVaults
/// @notice Step 7 of 10: Deploy all three collateral vaults.
///
/// @dev Collateral vaults set oracle=address(0) and unitOfAccount=address(0).
///      Pricing is handled by the borrow vault's oracle router.
///
///      - USDC collateral vault (collateral for VVV and ETH borrow vaults)
///      - VVV collateral vault  (collateral for USDC and ETH borrow vaults)
///      - WETH collateral vault (collateral for VVV and USDC borrow vaults)
///
/// @dev Run:
///      source .env && forge script script/07_DeployCollateralVaults.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste all three addresses into .env
contract DeployCollateralVaults is Script {
    function run() external {
        vm.startBroadcast();

        address usdcCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDC, address(0), address(0))
        );

        address vvvCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.VVV, address(0), address(0))
        );

        address wethCollVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WETH, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: Collateral Vaults ===");
        console.log("USDC_COLLATERAL_VAULT=%s", usdcCollVault);
        console.log("VVV_COLLATERAL_VAULT=%s", vvvCollVault);
        console.log("WETH_COLLATERAL_VAULT=%s", wethCollVault);
        console.log("\nPaste all into .env, then run 08_WireOracle.s.sol");
    }
}
