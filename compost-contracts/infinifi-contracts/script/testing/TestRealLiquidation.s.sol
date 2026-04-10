// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IEVault {
    function checkLiquidation(address liquidator, address borrower, address collateral) 
        external view returns (uint256 maxRepay, uint256 maxYield);
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IEulerSwapV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1);
    function getAssets() external view returns (address asset0, address asset1);
    function computeQuote(address tokenIn, address tokenOut, uint256 amount, bool exactIn) external view returns (uint256);
}

/// @title TestRealLiquidation  
/// @notice Test the actual liquidation mechanism with real position data
contract TestRealLiquidation is Script, AddressesMainnet {
    
    // Real liquidation data from terminal output
    address constant VIOLATOR = 0x701A27330d13728A60Bbe37DeCDE9d5A6c7402e4;
    address constant COLLATERAL_VAULT = 0xb04ad3337dc567a68a6f4D571944229320Ad1740; // INF_4W_VAULT
    address constant LIABILITY_VAULT = 0x4cBcfD04Ad466aa4999Fe607fc1864B1b8A400E4;   // USDC_VAULT
    uint256 constant MAX_REPAY = 40032218; // 40.032218 USDC (6 decimals)
    uint256 constant MAX_YIELD = 36791932832968663893; // shares (18 decimals)
    
    address constant POOL = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8;
    address constant LIQUIDATOR_CONTRACT = 0x2b4be42ffE67aF9FeFb020Ff0891332C1DB1440e;
    
    function run() external {
        console.log("=== Testing Real Liquidation ===");
        console.log("Violator:", VIOLATOR);
        console.log("Pool:", POOL);
        console.log("");
        
        testLiquidationValidity();
        console.log("");
        
        testPoolDirectly();
        console.log("");
        
        testSwapMechanism();
        console.log("");
        
        console.log("=== Test Complete ===");
    }
    
    function testLiquidationValidity() internal view {
        console.log("--- Liquidation Validity Check ---");
        
        IEVault liabilityVault = IEVault(LIABILITY_VAULT);
        
        try liabilityVault.checkLiquidation(LIQUIDATOR_CONTRACT, VIOLATOR, COLLATERAL_VAULT) 
            returns (uint256 maxRepay, uint256 maxYield) {
                
            console.log("Current Max Repay:", maxRepay);
            console.log("Current Max Yield:", maxYield);
            console.log("Expected Max Repay:", MAX_REPAY);
            console.log("Expected Max Yield:", MAX_YIELD);
            
            if (maxRepay > 0) {
                console.log("SUCCESS: Position is still liquidatable");
                
                // Convert shares to underlying
                IEVault collateralVault = IEVault(COLLATERAL_VAULT);
                try collateralVault.convertToAssets(maxYield) returns (uint256 underlying) {
                    console.log("Underlying tokens:", underlying);
                } catch {
                    console.log("ERROR: convertToAssets failed");
                }
            } else {
                console.log("ERROR: Position is no longer liquidatable");
            }
        } catch {
            console.log("ERROR: checkLiquidation failed");
        }
    }
    
    function testPoolDirectly() internal view {
        console.log("--- Direct Pool Testing ---");
        
        IEulerSwapV2 pool = IEulerSwapV2(POOL);
        
        // Get pool assets
        try pool.getAssets() returns (address asset0, address asset1) {
            console.log("Asset 0:", asset0); // Should be liUSD-4w
            console.log("Asset 1:", asset1); // Should be USDC
            
            // Test converting ~37 liUSD-4w to USDC
            uint256 testAmount = 37e18; // 37 tokens
            
            console.log("Testing swap of", testAmount / 1e18, "liUSD-4w tokens");
            
            // Test correct quote function
            console.log("");
            console.log("Quote attempts:");
            
            // Correct method: computeQuote
            try pool.computeQuote(asset0, asset1, testAmount, true) returns (uint256 out) {
                console.log("SUCCESS: computeQuote works!");
                console.log("   liUSD-4w in:", testAmount / 1e18);
                console.log("   USDC out:", out / 1e6);
                console.log("   Rate:", (out * 1e18) / testAmount / 1e12, "USDC per liUSD-4w");
            } catch Error(string memory reason) {
                console.log("ERROR: computeQuote failed:", reason);
            } catch {
                console.log("ERROR: computeQuote failed with no reason");
            }
            
        } catch {
            console.log("ERROR: getAssets failed");
        }
        
        // Check reserves
        try pool.getReserves() returns (uint112 reserve0, uint112 reserve1) {
            console.log("");
            console.log("Current reserves:");
            console.log("Reserve 0:", reserve0);
            console.log("Reserve 1:", reserve1);
        } catch {
            console.log("ERROR: getReserves failed");
        }
    }
    
    function testSwapMechanism() internal view {
        console.log("--- Swap Mechanism Analysis ---");
        
        // Check if we can determine what's wrong with quotes
        IEulerSwapV2 pool = IEulerSwapV2(POOL);
        
        // Test very small amounts
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1e15;      // 0.001 tokens
        testAmounts[1] = 1e16;      // 0.01 tokens  
        testAmounts[2] = 1e17;      // 0.1 tokens
        testAmounts[3] = 1e18;      // 1 token
        testAmounts[4] = 10e18;     // 10 tokens
        
        for (uint i = 0; i < testAmounts.length; i++) {
            uint256 amount = testAmounts[i];
            console.log("");
            console.log("Testing", amount, "wei");
            
            try pool.computeQuote(address(0x66bCF6151D5558AfB47c38B20663589843156078), address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), amount, true) returns (uint256 out) {
                console.log("SUCCESS:", out, "wei out");
                console.log("   USDC:", out / 1e6);
                if (out > 0) {
                    uint256 rate = (out * 1e18) / amount;
                    console.log("   Rate:", rate / 1e12, "USDC per liUSD");
                }
            } catch Error(string memory reason) {
                console.log("ERROR:", reason);
            } catch {
                console.log("ERROR: Unknown error");
            }
        }
        
        console.log("");
        console.log("If ALL amounts fail, there's a fundamental issue with:");
        console.log("1. Quote function implementation");
        console.log("2. Pool permissions/configuration");
        console.log("3. Hook mechanism");
        console.log("4. Borrow-to-fill setup");
    }
}