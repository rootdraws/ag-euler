// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;
import {Script, console} from "forge-std/Script.sol";
import {BalancerBptAdapter} from "../src/BalancerBptAdapter.sol";
interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
contract TestAdapterZapOut2 is Script {
    address constant POOL4_BPT = 0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3;
    address constant ADAPTER = 0x4da352A8c21d5AE5E70384B5965D0EEFC5b44123;
    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        console.log("BPT balance:", IERC20(POOL4_BPT).balanceOf(deployer));
        vm.startBroadcast();
        IERC20(POOL4_BPT).approve(ADAPTER, 5000000000000000);
        uint256 out = BalancerBptAdapter(ADAPTER).zapOut(1, 5000000000000000, 0);
        console.log("AUSD out:", out);
        vm.stopBroadcast();
    }
}
