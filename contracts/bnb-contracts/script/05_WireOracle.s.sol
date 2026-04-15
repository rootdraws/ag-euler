// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 05_WireOracle
/// @notice Step 5 of 7: Wire the EulerRouter with price adapters and resolve collateral vaults.
///
/// @dev Price adapters (both pre-deployed on BSC):
///        USDT → USDT/USD adapter
///        WBNB → WBNB/USD adapter
///
///      Collateral vault resolution:
///        USDT collateral eVault → USDT token
///        BNB  collateral eVault → WBNB token
///
/// @dev Prerequisites (in .env): EULER_ROUTER, USDT_COLLATERAL_VAULT, BNB_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/05_WireOracle.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER --broadcast
contract WireOracle is Script {
    function run() external {
        address router        = vm.envAddress("EULER_ROUTER");
        address usdtCollVault = vm.envAddress("USDT_COLLATERAL_VAULT");
        address bnbCollVault  = vm.envAddress("BNB_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // Price adapters: token → USD
        r.govSetConfig(Addresses.USDT, Addresses.USD, Addresses.USDT_USD_ADAPTER);
        r.govSetConfig(Addresses.WBNB, Addresses.USD, Addresses.WBNB_USD_ADAPTER);

        // Resolve collateral eVaults → underlying tokens
        r.govSetResolvedVault(usdtCollVault, true);
        r.govSetResolvedVault(bnbCollVault,  true);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Oracle Wired ===");
        console.log("Router:              %s", router);
        console.log("  USDT/USD adapter:  %s", Addresses.USDT_USD_ADAPTER);
        console.log("  WBNB/USD adapter:  %s", Addresses.WBNB_USD_ADAPTER);
        console.log("  Resolved USDT coll: %s", usdtCollVault);
        console.log("  Resolved BNB  coll: %s", bnbCollVault);
        console.log("\nRun 06_ConfigureCluster.s.sol next.");
    }
}
