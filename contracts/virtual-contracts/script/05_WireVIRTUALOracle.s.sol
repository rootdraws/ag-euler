// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 05_WireVIRTUALOracle
/// @notice Step 5: Add VIRTUAL/USD adapter to shared EulerRouter and resolve VIRTUAL collateral vault.
///
/// @dev Prerequisites (all must be set in .env):
///      EULER_ROUTER, VIRTUAL_USD_ADAPTER, VIRTUAL_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/05_WireVIRTUALOracle.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract WireVIRTUALOracle is Script {
    function run() external {
        address router           = vm.envAddress("EULER_ROUTER");
        address virtualAdapter   = vm.envAddress("VIRTUAL_USD_ADAPTER");
        address virtualCollVault = vm.envAddress("VIRTUAL_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // Add VIRTUAL/USD price adapter to the shared router
        r.govSetConfig(Addresses.VIRTUAL, Addresses.USD, virtualAdapter);

        // Resolve VIRTUAL collateral eVault → underlying VIRTUAL token
        r.govSetResolvedVault(virtualCollVault, true);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: VIRTUAL Oracle Wired ===");
        console.log("Router:                   %s", router);
        console.log("  VIRTUAL/USD adapter:    %s", virtualAdapter);
        console.log("  Resolved: VIRTUAL coll  %s", virtualCollVault);
        console.log("\nRun 06_ConfigureVIRTUALCluster.s.sol next.");
    }
}
