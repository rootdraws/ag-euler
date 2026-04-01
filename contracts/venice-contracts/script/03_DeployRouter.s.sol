// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 03_DeployRouter
/// @notice Step 3 of 10: Deploy an EulerRouter shared by all VVV/USDC/ETH markets.
///
/// @dev Both borrow vaults (VVV and USDC) reference this same router.
///      The router will be configured in step 7 with VVV/USD and USDC/USD adapters.
///
/// @dev Run:
///      source .env && forge script script/03_DeployRouter.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste EULER_ROUTER=<address> into .env
contract DeployRouter is Script {
    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();

        EulerRouter router = new EulerRouter(Addresses.EVC, deployer);

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: EulerRouter ===");
        console.log("EULER_ROUTER=%s", address(router));
        console.log("\nPaste into .env, then run 04_DeployVVVBorrowVault.s.sol");
    }
}
