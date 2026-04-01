// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {ICHIVaultOracle} from "ichi-oracle-kit/src/ICHIVaultOracle.sol";

/// @title FixKRWQOracle
/// @notice Deploy a KRWQ oracle with longer maxStaleness (1 week) for initial setup.
///   The KRWQ/frxUSD Algebra pool has no recent activity, so the original oracle
///   (maxStaleness=7200s) reverts with StaleOracle during setLTV.
///   Deployed directly (bypasses factory which blocks duplicate vaults).
contract FixKRWQOracle is Script {
    uint32 constant TWAP_PERIOD = 1800;
    uint32 constant MAX_STALENESS = 604800; // 1 week

    function run() external {
        address routerAddr = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        ICHIVaultOracle newOracle = new ICHIVaultOracle(
            Addresses.ICHI_KRWQ,
            TWAP_PERIOD,
            MAX_STALENESS
        );

        EulerRouter(routerAddr).govSetConfig(
            Addresses.ICHI_KRWQ,
            Addresses.frxUSD,
            address(newOracle)
        );

        vm.stopBroadcast();

        console.log("New KRWQ oracle (maxStaleness=1w): %s", address(newOracle));
        console.log("Router updated. Now run setLTV for KRWQ.");
    }
}
