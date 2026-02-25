// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 01_DeployRouter
/// @notice Step 1 of 7: Deploy the EulerRouter.
///
/// @dev Run:
///      source .env && forge script script/01_DeployRouter.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste EULER_ROUTER=<address> into .env, then run 02_DeployOracles.s.sol
contract DeployRouter is Script {
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();

        EulerRouter router = new EulerRouter(EVC, deployer);

        vm.stopBroadcast();

        console.log("\n=== STEP 1 COMPLETE: EulerRouter ===");
        console.log("EULER_ROUTER=%s", address(router));
        console.log("\nPaste into .env, then run 02_DeployOracles.s.sol");
    }
}
