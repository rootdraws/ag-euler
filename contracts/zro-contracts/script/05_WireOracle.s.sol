// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 05_WireOracle
/// @notice Step 5 of 7: Wire oracle adapters into ALL THREE routers.
///
///   A. ZRO vault's router (new):
///      - ZRO/USD, USDC/USD, ETH/USD adapters (to price debt + both collaterals)
///      - Resolve USDC vault + ETH vault (collateral shares → underlying)
///
///   B. Existing USDC vault's router:
///      - Add ZRO/USD adapter (to price ZRO collateral)
///      - Resolve ZRO vault
///
///   C. Existing ETH vault's router:
///      - Add ZRO/USD adapter (to price ZRO collateral)
///      - Resolve ZRO vault
///
///   NOTE: The deployer must be governor of ALL THREE routers.
///
/// @dev Usage:
///   source .env
///   forge script script/05_WireOracle.s.sol:WireOracle \
///     --rpc-url base --broadcast -vvvv
contract WireOracle is Script {
    function run() external {
        address zroRouterAddr  = vm.envAddress("ZRO_EULER_ROUTER");
        address usdcRouterAddr = vm.envAddress("USDC_EULER_ROUTER");
        address ethRouterAddr  = vm.envAddress("ETH_EULER_ROUTER");
        address zroAdapter     = vm.envAddress("CHAINLINK_ZRO_USD_ADAPTER");
        address zroVault       = vm.envAddress("ZRO_BORROW_VAULT");
        address usdcVault      = vm.envAddress("USDC_BORROW_VAULT");
        address ethVault       = vm.envAddress("ETH_BORROW_VAULT");

        vm.startBroadcast();

        // ─── A. Wire ZRO vault's router ───
        EulerRouter zroRouter = EulerRouter(zroRouterAddr);
        zroRouter.govSetConfig(Addresses.ZRO,  Addresses.USD, zroAdapter);
        zroRouter.govSetConfig(Addresses.USDC, Addresses.USD, Addresses.USDC_USD_ADAPTER);
        zroRouter.govSetConfig(Addresses.WETH, Addresses.USD, Addresses.ETH_USD_ADAPTER);
        zroRouter.govSetResolvedVault(usdcVault, true);
        zroRouter.govSetResolvedVault(ethVault,  true);

        // ─── B. Wire existing USDC vault's router ───
        EulerRouter usdcRouter = EulerRouter(usdcRouterAddr);
        usdcRouter.govSetConfig(Addresses.ZRO, Addresses.USD, zroAdapter);
        usdcRouter.govSetResolvedVault(zroVault, true);

        // ─── C. Wire existing ETH vault's router ───
        EulerRouter ethRouter = EulerRouter(ethRouterAddr);
        ethRouter.govSetConfig(Addresses.ZRO, Addresses.USD, zroAdapter);
        ethRouter.govSetResolvedVault(zroVault, true);

        vm.stopBroadcast();

        console.log("=== STEP 5 COMPLETE: All Three Routers Wired ===");
        console.log("");
        console.log("ZRO Router (%s):", zroRouterAddr);
        console.log("  ZRO  -> USD  via %s", zroAdapter);
        console.log("  USDC -> USD  via %s", Addresses.USDC_USD_ADAPTER);
        console.log("  WETH -> USD  via %s", Addresses.ETH_USD_ADAPTER);
        console.log("  Resolved: USDC vault (%s)", usdcVault);
        console.log("  Resolved: ETH vault  (%s)", ethVault);
        console.log("");
        console.log("USDC Router (%s):", usdcRouterAddr);
        console.log("  ZRO  -> USD  via %s", zroAdapter);
        console.log("  Resolved: ZRO vault (%s)", zroVault);
        console.log("");
        console.log("ETH Router (%s):", ethRouterAddr);
        console.log("  ZRO  -> USD  via %s", zroAdapter);
        console.log("  Resolved: ZRO vault (%s)", zroVault);
        console.log("\nRun 06_ConfigureCluster.s.sol next.");
    }
}
