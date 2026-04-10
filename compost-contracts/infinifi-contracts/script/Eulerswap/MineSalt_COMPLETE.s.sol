// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

interface IEulerSwapFactoryV2 {
    function computePoolAddress(StaticParams memory sParams, bytes32 salt) external view returns (address);
}

struct StaticParams {
    address supplyVault0;
    address supplyVault1;
    address borrowVault0;
    address borrowVault1;
    address eulerAccount;
    address feeRecipient;
}

contract MineSalt_COMPLETE is Script, AddressesMainnet {
    
    // Complete Uniswap v4 hook flags (from FactoryTest.t.sol)
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    
    uint160 constant COMPLETE_FLAGS = BEFORE_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG 
        | BEFORE_SWAP_FLAG | BEFORE_DONATE_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG;
    
    uint160 constant FLAG_MASK = 0x3FFF;
    
    function run() external view {
        IEulerSwapFactoryV2 factory = IEulerSwapFactoryV2(EULER_SWAP_FACTORY);
        
        StaticParams memory sParams = StaticParams({
            supplyVault0: INF_4W_VAULT,      // asset0 (liUSD-4w) - lower address 0x66...
            supplyVault1: USDC_CREDIT_POOL,  // asset1 (USDC) - higher address 0xa0...
            borrowVault0: address(0),        // No borrowing of liUSD-4w needed
            borrowVault1: USDC_CREDIT_POOL,  // borrows USDC for liquidator
            eulerAccount: WARREN_MULTISIG,
            feeRecipient: address(0)
        });
        
        console.log("=== Mining Complete Uniswap v4 Hook Address ===");
        console.log("Required flags breakdown:");
        console.log("  BEFORE_INITIALIZE_FLAG:", BEFORE_INITIALIZE_FLAG);
        console.log("  BEFORE_ADD_LIQUIDITY_FLAG:", BEFORE_ADD_LIQUIDITY_FLAG);
        console.log("  BEFORE_SWAP_FLAG:", BEFORE_SWAP_FLAG);
        console.log("  BEFORE_DONATE_FLAG:", BEFORE_DONATE_FLAG);
        console.log("  BEFORE_SWAP_RETURNS_DELTA_FLAG:", BEFORE_SWAP_RETURNS_DELTA_FLAG);
        console.log("Combined required flags:", COMPLETE_FLAGS);
        console.log("");
        
        address existingPoolManager = address(0x000000000000000000000000000000000004444c5dc75cb358380d2e3de08a90);
        console.log("Mining for poolManager:", existingPoolManager);
        
        for (uint256 i = 1400000; i < 10_000_000; i++) {
            bytes32 salt = keccak256(abi.encodePacked("WARREN_4W_COMPLETE_V4_HOOK_", i));
            address pool = factory.computePoolAddress(sParams, salt);
            
            uint160 poolFlags = uint160(pool) & FLAG_MASK;
            uint160 managerFlags = uint160(existingPoolManager) & FLAG_MASK;
            
            // Check if address has EXACTLY the required v4 hook flags (no extra flags)
            if (poolFlags == COMPLETE_FLAGS) {
                console.log("Found complete v4 hook address at iteration:", i);
                console.log("Salt:", vm.toString(salt));
                console.log("Pool address:", pool);
                console.log("Address flags:", poolFlags);
                console.log("Has all required v4 flags:", (poolFlags & COMPLETE_FLAGS) == COMPLETE_FLAGS);
                console.log("");
                console.log("SUCCESS: Complete Uniswap v4 hook address found!");
                return;
            }
            
            if (i % 100000 == 0) {
                console.log("Checked", i, "iterations...");
            }
        }
        
        console.log("No valid complete v4 hook address found");
    }
}