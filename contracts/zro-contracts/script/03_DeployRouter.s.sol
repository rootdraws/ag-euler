// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 03_DeployRouter
/// @notice Step 3 of 7: Deploy an EulerRouter for the ZRO borrow vault.
///   The existing USDC vault already has its own router (USDC_EULER_ROUTER in .env).
///   This router is only for the ZRO vault to price USDC collateral.
///
/// @dev Usage:
///   source .env
///   forge script script/03_DeployRouter.s.sol:DeployRouter \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: ZRO_EULER_ROUTER=<address>
contract DeployRouter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        EulerRouter router = new EulerRouter(Addresses.EVC, deployer);

        vm.stopBroadcast();

        console.log("=== STEP 3 COMPLETE: Router Deployed ===");
        console.log("EulerRouter:", address(router));
        console.log("Governor:", deployer);
        console.log("\nAdd to .env: ZRO_EULER_ROUTER=%s", address(router));
        console.log("Run 04_DeployZROVault.s.sol next.");
    }
}
