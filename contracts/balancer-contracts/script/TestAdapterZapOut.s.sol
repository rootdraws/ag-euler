// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BalancerBptAdapter} from "../src/BalancerBptAdapter.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract TestAdapterZapOut is Script {
    address constant POOL4_BPT = 0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3;
    address constant ADAPTER = 0xBD079948af3b91EaE15A2D240F3f90C7E4CCA08c;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        uint256 bptBal = IERC20(POOL4_BPT).balanceOf(deployer);
        console.log("BPT balance:", bptBal);

        uint256 zapOutAmount = 5000000000000000; // 5e15

        vm.startBroadcast();
        IERC20(POOL4_BPT).approve(ADAPTER, zapOutAmount);
        console.log("Calling zapOut(1, 5e15, 0)...");
        uint256 ausdOut = BalancerBptAdapter(ADAPTER).zapOut(1, zapOutAmount, 0);
        console.log("AUSD out:", ausdOut);
        vm.stopBroadcast();
    }
}
