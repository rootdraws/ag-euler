// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

interface IEulerSwapRegistry {
    function registerPool(address poolAddr) external payable;
    function minimumValidityBond() external view returns (uint256);
    function validityBond(address pool) external view returns (uint256);
}

/// @title RegisterPool_v2
/// @notice Registers the deployed EulerSwap v2 pool in the EulerSwap Registry
/// @dev This makes the pool discoverable by the Euler swap API and other integrators
contract RegisterPool_v2 is Script, AddressesMainnet {
    
    address constant POOL = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8;
    address constant REGISTRY = 0x5FcCB84363F020c0cADE052C9c654aABF932814A;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        
        console.log("=== Registering EulerSwap v2 Pool ===");
        console.log("Pool:", POOL);
        console.log("Registry:", REGISTRY);
        console.log("");
        
        // Check minimum validity bond required
        uint256 minBond = IEulerSwapRegistry(REGISTRY).minimumValidityBond();
        console.log("Minimum validity bond:", minBond, "wei");
        
        // Check if already registered
        uint256 existingBond = IEulerSwapRegistry(REGISTRY).validityBond(POOL);
        if (existingBond > 0) {
            console.log("Pool already registered with bond:", existingBond, "wei");
            return;
        }
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Register pool with minimum bond (if bond required)
        console.log("Registering pool...");
        IEulerSwapRegistry(REGISTRY).registerPool{value: minBond}(POOL);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Registration Complete ===");
        console.log("Pool is now discoverable by Euler swap API");
        console.log("Validity bond posted:", minBond, "wei");
    }
}
