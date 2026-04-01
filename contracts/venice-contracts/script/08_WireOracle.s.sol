// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 08_WireOracle
/// @notice Step 8 of 10: Wire the EulerRouter with oracle adapters for all three markets.
///
/// @dev Oracle resolution (unit of account = USD for all borrow vaults):
///
///      Price adapters:
///        VVV  → VVV/USD adapter (deployed in step 2)
///        USDC → USDC/USD adapter (existing on Base)
///        WETH → ETH/USD adapter (existing on Base)
///
///      Collateral vault resolution:
///        USDC collateral eVault → (resolved) → USDC token
///        VVV collateral eVault  → (resolved) → VVV token
///        WETH collateral eVault → (resolved) → WETH token
///
/// @dev Prerequisites (all must be set in .env):
///      VVV_USD_ADAPTER, EULER_ROUTER,
///      USDC_COLLATERAL_VAULT, VVV_COLLATERAL_VAULT, WETH_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/08_WireOracle.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract WireOracle is Script {
    function run() external {
        address router        = vm.envAddress("EULER_ROUTER");
        address vvvAdapter    = vm.envAddress("VVV_USD_ADAPTER");
        address usdcCollVault = vm.envAddress("USDC_COLLATERAL_VAULT");
        address vvvCollVault  = vm.envAddress("VVV_COLLATERAL_VAULT");
        address wethCollVault = vm.envAddress("WETH_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // Price adapters: token → USD
        r.govSetConfig(Addresses.VVV,  Addresses.USD, vvvAdapter);
        r.govSetConfig(Addresses.USDC, Addresses.USD, Addresses.USDC_USD_ADAPTER);
        r.govSetConfig(Addresses.WETH, Addresses.USD, Addresses.ETH_USD_ADAPTER);

        // Resolve collateral eVaults → underlying tokens
        r.govSetResolvedVault(usdcCollVault, true);
        r.govSetResolvedVault(vvvCollVault,  true);
        r.govSetResolvedVault(wethCollVault, true);

        vm.stopBroadcast();

        console.log("\n=== STEP 8 COMPLETE: Oracle Wired ===");
        console.log("Router:             %s", router);
        console.log("  VVV/USD adapter:  %s", vvvAdapter);
        console.log("  USDC/USD adapter: %s (existing)", Addresses.USDC_USD_ADAPTER);
        console.log("  ETH/USD adapter:  %s (existing)", Addresses.ETH_USD_ADAPTER);
        console.log("  Resolved: USDC collateral vault %s", usdcCollVault);
        console.log("  Resolved: VVV collateral vault  %s", vvvCollVault);
        console.log("  Resolved: WETH collateral vault %s", wethCollVault);
        console.log("\nRun 09_ConfigureCluster.s.sol next.");
    }
}
