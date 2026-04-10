// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IEulerSwapPeriphery {
    function quoteExactInput(address eulerSwap, address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256);
    function getLimits(address eulerSwap, address tokenIn, address tokenOut)
        external view returns (uint256 limitIn, uint256 limitOut);
}

interface IEulerSwapV2 {
    function getAssets() external view returns (address asset0, address asset1);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 status);
}

/// @title TestPeripheryQuote
/// @notice Test quotes through periphery contract like the working OneSidedCurve test
contract TestPeripheryQuote is Script {
    
    address constant POOL = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8;
    address constant PERIPHERY = 0xD3a349EE0A21eA0A7E9513ac236ae614b5FD513E; // Correct Euler Periphery mainnet
    
    function run() external view {
        console.log("=== Testing Quotes Through Periphery (Like OneSidedCurve Test) ===");
        console.log("Pool:", POOL);
        console.log("Periphery:", PERIPHERY);
        console.log("");
        
        IEulerSwapV2 pool = IEulerSwapV2(POOL);
        IEulerSwapPeriphery periphery = IEulerSwapPeriphery(PERIPHERY);
        
        // Get pool info
        try pool.getAssets() returns (address asset0, address asset1) {
            console.log("Asset 0:", asset0);
            console.log("Asset 1:", asset1);
            
            try pool.getReserves() returns (uint112 reserve0, uint112 reserve1, uint32 status) {
                console.log("Status:", status);
                console.log("Reserve 0:", reserve0);
                console.log("Reserve 1:", reserve1);
                console.log("");
                
                // Test periphery getLimits (like our working test)
                console.log("--- Testing Periphery getLimits ---");
                try periphery.getLimits(POOL, asset0, asset1) returns (uint256 limitIn, uint256 limitOut) {
                    console.log("SUCCESS: Periphery getLimits works!");
                    console.log("In Limit:", limitIn);
                    console.log("Out Limit:", limitOut);
                } catch Error(string memory reason) {
                    console.log("ERROR: Periphery getLimits failed:", reason);
                } catch {
                    console.log("ERROR: Periphery getLimits failed with no reason");
                }
                
                console.log("");
                console.log("--- Testing Periphery Quotes ---");
                
                // Test like OneSidedCurve does: quote small amount
                uint256 testAmount = 1e15; // 0.001 tokens
                console.log("Testing 0.001 tokens (like OneSidedCurve starts small)");
                
                try periphery.quoteExactInput(POOL, asset0, asset1, testAmount) returns (uint256 amountOut) {
                    console.log("SUCCESS: Periphery quote works!");
                    console.log("Amount out:", amountOut);
                    
                    if (amountOut == 0) {
                        console.log("Note: Amount out is 0 (expected for one-sided pool)");
                    } else {
                        console.log("Amount out USDC:", amountOut / 1e6);
                    }
                } catch Error(string memory reason) {
                    console.log("ERROR: Periphery quote failed:", reason);
                } catch {
                    console.log("ERROR: Periphery quote failed with no reason");
                }
                
                // Test reverse direction
                console.log("");
                console.log("Testing reverse direction (USDC -> liUSD-4w):");
                try periphery.quoteExactInput(POOL, asset1, asset0, 1e6) returns (uint256 amountOut) {
                    console.log("SUCCESS: Reverse quote works!");
                    console.log("Amount out tokens:", amountOut / 1e18);
                } catch Error(string memory reason) {
                    console.log("ERROR: Reverse quote failed:", reason);
                } catch {
                    console.log("ERROR: Reverse quote failed with no reason");
                }
                
            } catch {
                console.log("ERROR: Could not get pool reserves");
            }
        } catch {
            console.log("ERROR: Could not get pool assets");
        }
    }
}