// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

interface IEVault {
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
}

/// @title Set LTV to 75%
/// @notice Changes borrowLTV and liquidationLTV to 75% to trigger liquidation test
contract SetLTV75 is Script {
    // Warren Vaults (Mainnet)
    address constant USDC_VAULT = 0x4cBcfD04Ad466aa4999Fe607fc1864B1b8A400E4; // USDC Loop vault
    address constant INF_4W_VAULT = 0xb04ad3337dc567a68a6f4D571944229320Ad1740; // liUSD-4w vault
    
    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Setting LTV to 75% on USDC Loop vault...");
        console.log("Vault (Liability):", USDC_VAULT);
        console.log("Collateral:", INF_4W_VAULT);
        
        // Set LTV on USDC vault (liability) for liUSD-4w collateral
        // borrowLTV: 0.75e4 = 75%
        // liquidationLTV: 0.75e4 = 75% (no spread for immediate liquidation)
        // rampDuration: 0 (immediate, no ramp)
        IEVault(USDC_VAULT).setLTV(
            INF_4W_VAULT,  // collateral = liUSD-4w vault
            0.75e4,        // borrowLTV = 75%
            0.75e4,        // liquidationLTV = 75%
            0              // rampDuration = 0 (immediate)
        );
        
        console.log("LTV set to 75%!");
        console.log("Position 0x701a...02e5 with $40 debt / $49 collateral is now liquidatable");
        
        vm.stopBroadcast();
    }
}
