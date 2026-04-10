// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "./USDCChainlinkOracle.sol";

/// @title Deploy USDC Chainlink Oracle
/// @notice Deploys the USDC Chainlink oracle adapter for pricing USDC/USD
contract DeployUSDCChainlinkOracle is Script {
    
    function run() external returns (address adapterAddress) {
        console.log("=== Deploying USDC Chainlink Oracle ===");
        console.log("");
        
        // Configuration
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address USD = address(840);
        address chainlinkFeed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
        uint256 maxStaleness = 90000; // 25 hours (24h heartbeat + 1h buffer)
        
        console.log("Oracle Configuration:");
        console.log("- USDC: ", USDC);
        console.log("- USD: ", USD);
        console.log("- Chainlink Feed: ", chainlinkFeed);
        console.log("- Max Staleness: ", maxStaleness, "seconds (25 hours)");
        console.log("");
        
        // Start recording transactions
        vm.startBroadcast();
        
        // Deploy USDCChainlinkOracle
        console.log("Deploying USDCChainlinkOracle...");
        USDCChainlinkOracle adapter = new USDCChainlinkOracle(USDC, USD, chainlinkFeed, maxStaleness);
        adapterAddress = address(adapter);
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        console.log("USDCChainlinkOracle deployed at: ", adapterAddress);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Verify contract on Etherscan");
        console.log("2. Update AddressesMainnet.sol with adapter address");
        console.log("3. Register adapter in Oracle Adapter Registry");
        console.log("4. Configure Euler Oracle Router for USDC/USD pair");
    }
}
