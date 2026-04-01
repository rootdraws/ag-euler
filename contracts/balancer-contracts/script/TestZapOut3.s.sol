// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;
import {Script, console} from "forge-std/Script.sol";
import {BalancerBptAdapter} from "../src/BalancerBptAdapter.sol";
interface IERC20 { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
contract TestZapOut3 is Script {
    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        vm.startBroadcast();
        IERC20(0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3).approve(0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832, 5000000000000000);
        BalancerBptAdapter(0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832).zapOut(1, 5000000000000000, 0);
        vm.stopBroadcast();
    }
}
