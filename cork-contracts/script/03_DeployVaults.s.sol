// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {ERC4626EVCCollateralCork} from "../src/vault/ERC4626EVCCollateralCork.sol";

/// @title 03_DeployVaults
/// @notice Step 3 of 7: Deploy the sUSDe borrow vault and both collateral vaults.
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env from step 01.
///
/// @dev Deployment order matters:
///      1. sUSDe borrow vault (standard EVK proxy) — needed as borrowVault arg for both
///         ERC4626EVCCollateralCork instances.
///      2. vbUSDC collateral vault (ERC4626EVCCollateralCork, isRefVault=true)
///      3. cST collateral vault (ERC4626EVCCollateralCork, isRefVault=false)
///
/// @dev Run:
///      source .env && forge script script/03_DeployVaults.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste SUSDE_BORROW_VAULT, VBUSDC_VAULT, CST_VAULT into .env,
///      then run 04_WireRouter.s.sol
contract DeployVaults is Script {
    // Assets
    address constant vbUSDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e; // 6 decimals
    address constant sUSDe  = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // 18 decimals
    address constant cST    = 0x1B42544F897B7Ab236C111A4f800A54D94840688; // 18 decimals
    address constant USD    = address(840);

    // Euler Infrastructure
    address constant EVC           = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant eVaultFactory = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address constant permit2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        address deployer = msg.sender;
        address router   = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        // 3a. Deploy sUSDe borrow vault (standard EVK upgradeable proxy).
        //     Trailing data: abi.encodePacked(asset, oracle, unitOfAccount)
        address sUSDeBorrowVault = address(
            GenericFactory(eVaultFactory).createProxy(
                address(0), // use factory's current EVault implementation
                true,       // upgradeable
                abi.encodePacked(sUSDe, router, USD)
            )
        );

        // 3b. Deploy vbUSDC collateral vault (REF vault, isRefVault=true).
        ERC4626EVCCollateralCork vbUSDCVault = new ERC4626EVCCollateralCork(
            EVC,
            permit2,
            deployer,
            sUSDeBorrowVault,
            vbUSDC,
            "Euler Collateral: vbUSDC",
            "ecvbUSDC",
            true // isRefVault
        );

        // 3c. Deploy cST collateral vault (isRefVault=false).
        ERC4626EVCCollateralCork cSTVault = new ERC4626EVCCollateralCork(
            EVC,
            permit2,
            deployer,
            sUSDeBorrowVault,
            cST,
            "Euler Collateral: vbUSDC4cST",
            "eccST",
            false // isRefVault
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: Vaults ===");
        console.log("SUSDE_BORROW_VAULT=%s", sUSDeBorrowVault);
        console.log("VBUSDC_VAULT=%s", address(vbUSDCVault));
        console.log("CST_VAULT=%s", address(cSTVault));
        console.log("\nPaste all three into .env, then run 04_WireRouter.s.sol");
    }
}
