// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 05_WireOracle
/// @notice Step 5 of 6: Wire the EulerRouter with the ARM resolved-vault config.
///
/// @dev Oracle resolution chain (unit of account = WETH):
///
///      ARM Collateral Vault → convertToAssets → ARM-WETH-stETH token
///                           → convertToAssets → WETH (identity, done)
///
///      Two resolved vaults are needed:
///        1. ARM Collateral Vault (EVK) — its asset() returns ARM-WETH-stETH
///        2. ARM-WETH-stETH token     — its asset() returns WETH
///
///      The EulerRouter resolves recursively: collateral vault → ARM → WETH.
///
/// @dev Prerequisites (must be set in .env):
///      EULER_ROUTER, ARM_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/05_WireOracle.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev No new addresses. Run 06_ConfigureCluster.s.sol next.
contract WireOracle is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");
        address armCollVault = vm.envAddress("ARM_COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // 1. ARM collateral vault (EVK) — asset() returns ARM-WETH-stETH token
        r.govSetResolvedVault(armCollVault, true);

        // 2. ARM-WETH-stETH token — asset() returns WETH (already set, idempotent)
        r.govSetResolvedVault(Addresses.ARM_WETH_STETH, true);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Oracle Wired ===");
        console.log("govSetResolvedVault(collateral=%s, true)", armCollVault);
        console.log("govSetResolvedVault(ARM=%s, true)", Addresses.ARM_WETH_STETH);
        console.log("Resolution: CollateralVault -> ARM -> WETH (identity)");
        console.log("\nRun 06_ConfigureCluster.s.sol next.");
    }
}
