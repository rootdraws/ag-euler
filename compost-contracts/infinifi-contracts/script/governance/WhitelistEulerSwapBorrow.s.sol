// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

/// @title Whitelist EulerSwap Pools for Credit Pool Borrow
/// @notice Grants OP_BORROW permission to EulerSwap pools on the shared hook
/// @dev Run AFTER EulerSwap pools are deployed
contract WhitelistEulerSwapBorrow is Script {
    
    // Existing infrastructure
    address constant LIQUIDATOR_HOOK = 0x1D34a4f69b7CB81ee77CD3b1D3944513352941d5;
    
    // EulerSwap v2 pool (LIQUIDATION deployment - equal prices)
    address constant EULER_SWAP_4W = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8;
    
    // borrow(uint256,address) selector
    bytes4 constant BORROW_SELECTOR = 0x4b8a3529;
    
    function run() external {
        console.log("=== Whitelisting EulerSwap Pool for Borrow ===");
        console.log("");
        console.log("Hook:", LIQUIDATOR_HOOK);
        console.log("Borrow Selector:", vm.toString(BORROW_SELECTOR));
        console.log("");
        console.log("Pool to whitelist:");
        console.log("- 4W:", EULER_SWAP_4W);
        console.log("");
        
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        
        IAccessControl hook = IAccessControl(LIQUIDATOR_HOOK);
        
        hook.grantRole(bytes32(BORROW_SELECTOR), EULER_SWAP_4W);
        console.log("Granted borrow to 4W pool");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Done ===");
        console.log("");
        console.log("Credit Pool borrow is now enabled for EulerSwap liquidations.");
    }
}
