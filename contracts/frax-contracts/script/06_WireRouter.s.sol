// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 06_WireRouter
/// @notice Step 6 of 7: Wire all 5 ICHI vault oracles into the EulerRouter.
///   Two wiring layers:
///     1. govSetConfig(ICHI_vault, frxUSD, oracle) — prices ICHI shares in frxUSD
///     2. govSetResolvedVault(collateralEVault) — resolves eVault.asset() to the ICHI
///        shares so Euler can look up the config above when pricing collateral eVaults.
///
/// @dev Usage:
///   source .env
///   forge script script/06_WireRouter.s.sol:WireRouter \
///     --rpc-url base --broadcast -vvvv
contract WireRouter is Script {
    function run() external {
        address routerAddr = vm.envAddress("EULER_ROUTER");

        address oracleBrz  = vm.envAddress("ORACLE_BRZ");
        address oracleTgbp = vm.envAddress("ORACLE_TGBP");
        address oracleUsdc = vm.envAddress("ORACLE_USDC");
        address oracleIdrx = vm.envAddress("ORACLE_IDRX");
        address oracleKrwq = vm.envAddress("ORACLE_KRWQ");

        address cvBrz  = vm.envAddress("COLLATERAL_VAULT_BRZ");
        address cvTgbp = vm.envAddress("COLLATERAL_VAULT_TGBP");
        address cvUsdc = vm.envAddress("COLLATERAL_VAULT_USDC");
        address cvIdrx = vm.envAddress("COLLATERAL_VAULT_IDRX");
        address cvKrwq = vm.envAddress("COLLATERAL_VAULT_KRWQ");

        EulerRouter router = EulerRouter(routerAddr);

        vm.startBroadcast();

        router.govSetConfig(Addresses.ICHI_BRZ,  Addresses.frxUSD, oracleBrz);
        router.govSetConfig(Addresses.ICHI_TGBP, Addresses.frxUSD, oracleTgbp);
        router.govSetConfig(Addresses.ICHI_USDC, Addresses.frxUSD, oracleUsdc);
        router.govSetConfig(Addresses.ICHI_IDRX, Addresses.frxUSD, oracleIdrx);
        router.govSetConfig(Addresses.ICHI_KRWQ, Addresses.frxUSD, oracleKrwq);

        router.govSetResolvedVault(cvBrz,  true);
        router.govSetResolvedVault(cvTgbp, true);
        router.govSetResolvedVault(cvUsdc, true);
        router.govSetResolvedVault(cvIdrx, true);
        router.govSetResolvedVault(cvKrwq, true);

        vm.stopBroadcast();

        console.log("=== STEP 6 COMPLETE: Router Wired ===");
        console.log("Router %s configured with 5 oracle adapters + 5 resolved vaults", routerAddr);
        console.log("  ICHI_BRZ  -> %s  (eVault %s)", oracleBrz, cvBrz);
        console.log("  ICHI_TGBP -> %s  (eVault %s)", oracleTgbp, cvTgbp);
        console.log("  ICHI_USDC -> %s  (eVault %s)", oracleUsdc, cvUsdc);
        console.log("  ICHI_IDRX -> %s  (eVault %s)", oracleIdrx, cvIdrx);
        console.log("  ICHI_KRWQ -> %s  (eVault %s)", oracleKrwq, cvKrwq);
        console.log("\nRun 07_ConfigureCluster.s.sol next.");
    }
}
