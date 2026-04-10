// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HookTargetAccessControl} from "evk-periphery/HookTarget/HookTargetAccessControl.sol";

/// @title Deploy Warren Hook Target Access Control
/// @notice Deploys HookTargetAccessControl for managing liquidator permissions
contract DeployHookTargetAccessControl is Script {
    
    // Mainnet addresses
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant EVAULT_FACTORY = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address constant WARREN_MULTISIG = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448;
    
    function run() external returns (address hookAddress) {
        console.log("=== Deploying Warren HookTargetAccessControl ===");
        console.log("");
        
        console.log("Configuration:");
        console.log("- EVC: ", EVC);
        console.log("- EVault Factory: ", EVAULT_FACTORY);
        console.log("- Admin (Warren Multisig): ", WARREN_MULTISIG);
        console.log("");
        
        // Start recording transactions
        vm.startBroadcast();
        
        // Deploy HookTargetAccessControl
        console.log("Deploying HookTargetAccessControl...");
        HookTargetAccessControl hook = new HookTargetAccessControl(
            EVC,
            WARREN_MULTISIG,
            EVAULT_FACTORY
        );
        hookAddress = address(hook);
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        console.log("HookTargetAccessControl deployed at: ", hookAddress);
        console.log("");
        console.log("Features:");
        console.log("- Selector-based access control for vault operations");
        console.log("- Admin: Warren multisig can grant/revoke roles");
        console.log("- Liquidator permissions can be added when ready");
        console.log("");
        console.log("Next Steps:");
        console.log("1. Update WarrenCluster.s.sol with hook address");
        console.log("2. Deploy Warren vault cluster with hook enabled");
        console.log("3. Grant liquidator role when liquidator contract is deployed:");
        console.log("   hookTarget.grantRole(liquidateSelector, liquidatorAddress)");
    }
}
