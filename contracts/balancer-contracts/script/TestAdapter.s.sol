// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BalancerBptAdapter} from "../src/BalancerBptAdapter.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

contract TestAdapter is Script {
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant ADAPTER = 0x0Af9156B3E1C64C332c680E043C2354ee1ABF293;

    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        console.log("Deployer:", deployer);
        console.log("AUSD balance:", IERC20(AUSD).balanceOf(deployer));
        console.log("AUSD allowance to adapter:", IERC20(AUSD).allowance(deployer, ADAPTER));

        vm.startBroadcast();

        IERC20(AUSD).approve(ADAPTER, 50000);
        console.log("Approved 50000 AUSD to adapter");

        console.log("Calling zapIn(1, 50000, 0)...");
        uint256 bptOut = BalancerBptAdapter(ADAPTER).zapIn(1, 50000, 0);
        console.log("BPT out:", bptOut);

        vm.stopBroadcast();
    }
}
