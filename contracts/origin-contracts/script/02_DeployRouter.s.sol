// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 02_DeployRouter
/// @notice Step 2 of 6: Deploy an EulerRouter for the Origin ARM market.
///
/// @dev The router is the oracle address passed when creating the borrow vault (step 3),
///      and is wired with the ARM resolved-vault config in step 5.
///      Deployer retains governor role until step 6 optionally transfers it.
///
/// @dev Run:
///      source .env && forge script script/02_DeployRouter.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste EULER_ROUTER=<address> into .env, then run 03_DeployBorrowVault.s.sol
contract DeployRouter is Script {
    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();

        EulerRouter router = new EulerRouter(Addresses.EVC, deployer);

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: EulerRouter ===");
        console.log("EULER_ROUTER=%s", address(router));
        console.log("\nPaste into .env, then run 03_DeployBorrowVault.s.sol");
    }
}
