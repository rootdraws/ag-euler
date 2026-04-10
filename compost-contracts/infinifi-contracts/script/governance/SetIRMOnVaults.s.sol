// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }
    function batch(BatchItem[] calldata items) external payable;
}

interface IEVault {
    function setInterestRateModel(address newModel) external;
    function interestRateModel() external view returns (address);
}

/// @title Set IRM on USDC Vault
/// @notice Sets the Loop-Optimized Kinky IRM ONLY on USDC vault
contract SetIRMOnVaults is Script {
    
    // Deployed addresses (updated 12/29/2025)
    address constant INF_IRM = 0xB71DA37621076D6D6b5281824e7Af8ac183d6838;
    address constant USDC_VAULT = 0x4cBcfD04Ad466aa4999Fe607fc1864B1b8A400E4;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        
        console.log("=== Setting IRM on USDC Vault ONLY ===");
        console.log("");
        console.log("IRM Address: ", INF_IRM);
        console.log("USDC Vault: ", USDC_VAULT);
        console.log("");
        
        // Execute directly (no EVC batch needed for single vault)
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Setting IRM on USDC vault...");
        IEVault(USDC_VAULT).setInterestRateModel(INF_IRM);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== IRM Configuration Complete ===");
        console.log("USDC vault now uses Loop-Optimized Kinky IRM");
        console.log("Other vaults unchanged");
    }
}
