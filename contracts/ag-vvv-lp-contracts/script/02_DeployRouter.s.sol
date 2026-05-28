// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 02_DeployRouter
/// @notice Step 2 of 7: Deploy an EulerRouter for the agVVVWETHlp / USDC market.
///
/// @dev Deployer becomes the initial governor — required so the same key can
///      run step 5 (govSetConfig + govSetResolvedVault) without an extra
///      governance transfer. Transfer to a Safe later via router.transferGovernance().
///
/// @dev Run:
///      source .env && forge script script/02_DeployRouter.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
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
        console.log("Governor:     %s", deployer);
        console.log("\nPaste into .env, then run 03_DeployBorrowVault.s.sol");
    }
}
