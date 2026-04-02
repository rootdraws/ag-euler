// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 24_WireAEROOracle
/// @notice Step 24: Add AERO/USD adapter to shared EulerRouter and resolve AERO collateral vault.
///
/// @dev Prerequisites (all must be set in .env):
///      EULER_ROUTER, AERO_USD_ADAPTER, AERO_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/24_WireAEROOracle.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract WireAEROOracle is Script {
    function run() external {
        address router        = vm.envAddress("EULER_ROUTER");
        address aeroAdapter   = vm.envAddress("AERO_USD_ADAPTER");
        address aeroCollVault = vm.envAddress("AERO_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // Add AERO/USD price adapter to the shared router
        r.govSetConfig(Addresses.AERO, Addresses.USD, aeroAdapter);

        // Resolve AERO collateral eVault → underlying AERO token
        r.govSetResolvedVault(aeroCollVault, true);

        vm.stopBroadcast();

        console.log("\n=== STEP 24 COMPLETE: AERO Oracle Wired ===");
        console.log("Router:                %s", router);
        console.log("  AERO/USD adapter:    %s", aeroAdapter);
        console.log("  Resolved: AERO coll  %s", aeroCollVault);
        console.log("\nRun 25_ConfigureAEROCluster.s.sol next.");
    }
}
