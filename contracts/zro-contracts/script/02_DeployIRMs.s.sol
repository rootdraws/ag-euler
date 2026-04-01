// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external
        returns (address);
}

/// @title 02_DeployIRM
/// @notice Step 2 of 7: Deploy a KinkIRM for the ZRO borrow market.
///   The USDC vault already has its own IRM (deployed by co-worker).
///
///   ZRO Borrow IRM:  Base=2%, Kink(70%)=15%, Max=200%
///
///   Compute params with:
///     node ../../reference/evk-periphery/script/utils/calculate-irm-linear-kink.js \
///       borrow <baseAPY> <kinkAPY> <maxAPY> <kinkUtil>
///
/// @dev Usage:
///   source .env
///   forge script script/02_DeployIRMs.s.sol:DeployIRMs \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: KINK_IRM_ZRO=<addr>
contract DeployIRMs is Script {
    // ZRO Borrow IRM: Base=2%, Kink(70%)=15%, Max=200%
    // node calculate-irm-linear-kink.js borrow 2 15 200 70
    uint256 constant ZRO_IRM_BASE   = 627_520_268_750_923_800;
    uint256 constant ZRO_IRM_SLOPE1 = 1_264_389_925;
    uint256 constant ZRO_IRM_SLOPE2 = 23_581_675_779;
    uint32  constant ZRO_IRM_KINK   = 3_006_477_107;    // 70% utilization

    function run() external {
        vm.startBroadcast();

        address zroIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            ZRO_IRM_BASE, ZRO_IRM_SLOPE1, ZRO_IRM_SLOPE2, ZRO_IRM_KINK
        );

        vm.stopBroadcast();

        console.log("=== STEP 2 COMPLETE: IRM Deployed ===");
        console.log("ZRO Borrow IRM:  %s  (Base=2%%, Kink(70%%)=15%%, Max=200%%)", zroIrm);
        console.log("\nAdd to .env: KINK_IRM_ZRO=%s", zroIrm);
        console.log("Run 03_DeployRouter.s.sol next.");
    }
}
