// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 02_DeployRouter
/// @notice Step 2 of 6: Deploy the EulerRouter.
///
/// @dev The router is passed as the oracle address when creating borrow vaults (step 3),
///      and wired with oracle configs in step 5.
///
/// @dev Run:
///      source .env && forge script script/02_DeployRouter.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --verify
///
/// @dev After running: paste EULER_ROUTER=<address> into .env, then run 03_DeployBorrowVaults.s.sol
contract DeployRouter is Script {
    address constant EVC = 0x7a9324E8f270413fa2E458f5831226d99C7477CD;

    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();

        EulerRouter router = new EulerRouter(EVC, deployer);

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: EulerRouter ===");
        console.log("EULER_ROUTER=%s", address(router));
        console.log("\nPaste into .env, then run 03_DeployBorrowVaults.s.sol");
    }
}
