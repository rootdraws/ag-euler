// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {WarrenLiquidator} from "./WarrenLiquidator.sol";

contract DeployWarrenLiquidator is Script {
    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        
        console2.log("Deployer:", deployer);
        
        vm.startBroadcast(pk);
        
        WarrenLiquidator liquidator = new WarrenLiquidator();
        console2.log("WarrenLiquidator:", address(liquidator));
        
        vm.stopBroadcast();
        
        console2.log("");
        console2.log("=== NEXT STEPS ===");
        console2.log("1. Grant liquidator role:");
        console2.log("   cast send 0x5e306F12E7eBCC0F7d3e5639Dc8f003791D76515 \"grantRole(bytes32,address)\" 0xc134257400000000000000000000000000000000000000000000000000000000", address(liquidator));
        console2.log("");
        console2.log("2. Update .env:");
        console2.log("   LIQUIDATOR_ADDRESS=%s", address(liquidator));
    }
}