// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 15_WireZROOracle
/// @notice Step 15: Add ZRO/USD adapter to shared EulerRouter and resolve ZRO collateral vault.
///
/// @dev Prerequisites (all must be set in .env):
///      EULER_ROUTER, ZRO_USD_ADAPTER, ZRO_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/15_WireZROOracle.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract WireZROOracle is Script {
    function run() external {
        address router       = vm.envAddress("EULER_ROUTER");
        address zroAdapter   = vm.envAddress("ZRO_USD_ADAPTER");
        address zroCollVault = vm.envAddress("ZRO_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // Add ZRO/USD price adapter to the shared router
        r.govSetConfig(Addresses.ZRO, Addresses.USD, zroAdapter);

        // Resolve ZRO collateral eVault → underlying ZRO token
        r.govSetResolvedVault(zroCollVault, true);

        vm.stopBroadcast();

        console.log("\n=== STEP 15 COMPLETE: ZRO Oracle Wired ===");
        console.log("Router:               %s", router);
        console.log("  ZRO/USD adapter:    %s", zroAdapter);
        console.log("  Resolved: ZRO coll  %s", zroCollVault);
        console.log("\nRun 16_ConfigureZROCluster.s.sol next.");
    }
}
