// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 02_DeployRouter
/// @notice Step 2 of 7: Deploy an EulerRouter. The deployer becomes governor.
///
/// @dev Usage:
///   source .env
///   forge script script/02_DeployRouter.s.sol:DeployRouter \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: EULER_ROUTER=<address>
contract DeployRouter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        EulerRouter router = new EulerRouter(Addresses.EVC, deployer);

        vm.stopBroadcast();

        console.log("=== STEP 2 COMPLETE: Router Deployed ===");
        console.log("EulerRouter:", address(router));
        console.log("Governor:", deployer);
        console.log("\nAdd to .env: EULER_ROUTER=%s", address(router));
        console.log("Run 03_DeployOracles.s.sol next.");
    }
}
