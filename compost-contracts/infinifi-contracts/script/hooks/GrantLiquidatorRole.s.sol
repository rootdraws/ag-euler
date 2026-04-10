// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IHookTargetAccessControl {
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title Grant Liquidator Role to HookTargetAccessControl
/// @notice Grants liquidate function permission to the Warren liquidator contract
contract GrantLiquidatorRole is Script {
    
    // Warren HookTargetAccessControl address (deployed 12/20/2025)
    address constant HOOK_TARGET = 0x1D34a4f69b7CB81ee77CD3b1D3944513352941d5;
    
    // Warren Liquidator address (deployed 12/20/2025 - v4 atomic debt pattern)
    address constant LIQUIDATOR = 0x2b4be42ffE67aF9FeFb020Ff0891332C1DB1440e;
    
    // Calculate liquidate selector: keccak256("liquidate(address,address,uint256,uint256)")
    bytes32 constant LIQUIDATE_SELECTOR = bytes32(bytes4(keccak256("liquidate(address,address,uint256,uint256)")));
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        
        console.log("=== Granting Liquidator Role ===");
        console.log("");
        
        console.log("Configuration:");
        console.log("- Hook Target: ", HOOK_TARGET);
        console.log("- Liquidator: ", LIQUIDATOR);
        console.log("- Liquidate Selector: ");
        console.logBytes32(LIQUIDATE_SELECTOR);
        console.log("");
        
        IHookTargetAccessControl hook = IHookTargetAccessControl(HOOK_TARGET);
        
        // Check current status
        bool hasRole = hook.hasRole(LIQUIDATE_SELECTOR, LIQUIDATOR);
        console.log("Current permission status: ", hasRole ? "GRANTED" : "NOT GRANTED");
        console.log("");
        
        // Start recording transactions
        vm.startBroadcast(deployerPrivateKey);
        
        if (!hasRole) {
            console.log("Granting liquidate permission to liquidator...");
            hook.grantRole(LIQUIDATE_SELECTOR, LIQUIDATOR);
            console.log("Permission granted!");
        } else {
            console.log("Liquidator already has permission. No action needed.");
        }
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Complete ===");
        console.log("Liquidator can now call liquidate() on Warren vaults");
        console.log("");
        console.log("To update liquidator address:");
        console.log("1. Revoke role from old address: hook.revokeRole(LIQUIDATE_SELECTOR, oldAddress)");
        console.log("2. Grant role to new address: hook.grantRole(LIQUIDATE_SELECTOR, newAddress)");
    }
}
