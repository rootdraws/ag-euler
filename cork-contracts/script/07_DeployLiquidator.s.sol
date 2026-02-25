// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {CorkProtectedLoopLiquidator} from "../src/liquidator/CorkProtectedLoopLiquidator.sol";

/// @title 07_DeployLiquidator
/// @notice Step 7 of 7: Deploy CorkProtectedLoopLiquidator.
///
/// @dev Prerequisites (all must be set in .env):
///      VBUSDC_VAULT, CST_VAULT, SUSDE_BORROW_VAULT
///
/// @dev IMPORTANT: After deploying, send the liquidator address to the Cork team.
///      Cork governance must call:
///        WhitelistManager.addToMarketWhitelist(POOL_ID, liquidatorAddress)
///      Without this, exercise() cannot be called and liquidation will fail.
///
/// @dev Run:
///      source .env && forge script script/07_DeployLiquidator.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running:
///      1. Paste CORK_LIQUIDATOR=<address> into .env
///      2. Send address to Cork team for pool whitelist
///      3. Update cork-labels/1/products.json + vaults.json with all deployed addresses
///      4. Push cork-labels to rootdraws/ag-euler-cork-labels
contract DeployLiquidator is Script {
    // Assets
    address constant vbUSDC    = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    address constant sUSDe     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant cST       = 0x1B42544F897B7Ab236C111A4f800A54D94840688;

    // Euler Infrastructure
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // Cork Infrastructure
    address constant corkPoolManager = 0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC;
    bytes32 constant corkPoolId      = 0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a;

    function run() external {
        address deployer         = msg.sender;
        address vbUSDCVault      = vm.envAddress("VBUSDC_VAULT");
        address cSTVault         = vm.envAddress("CST_VAULT");

        vm.startBroadcast();

        CorkProtectedLoopLiquidator liquidator = new CorkProtectedLoopLiquidator(
            EVC,
            deployer,
            corkPoolManager,
            corkPoolId,
            vbUSDCVault,
            cSTVault,
            vbUSDC,
            cST,
            sUSDe
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: Liquidator ===");
        console.log("CORK_LIQUIDATOR=%s", address(liquidator));
        console.log("\n!!! ACTION REQUIRED !!!");
        console.log("Send liquidator address to Cork team for whitelist:");
        console.log("  WhitelistManager.addToMarketWhitelist(poolId, %s)", address(liquidator));
        console.log("\nNext steps:");
        console.log("  1. Paste CORK_LIQUIDATOR into .env");
        console.log("  2. Update cork-labels/1/products.json + vaults.json");
        console.log("  3. Push cork-labels to rootdraws/ag-euler-cork-labels");
    }
}
