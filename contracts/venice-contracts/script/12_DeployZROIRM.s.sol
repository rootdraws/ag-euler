// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external
        returns (address);
}

/// @title 12_DeployZROIRM
/// @notice Step 12: Deploy a KinkIRM for ZRO borrow market.
///
///   ZRO Borrow IRM:  Base=2%, Kink(70%)=15%, Max=200%
///
///   Compute params with:
///     node ../../reference/evk-periphery/script/utils/calculate-irm-linear-kink.js \
///       borrow 2 15 200 70
///
/// @dev Run:
///      source .env && forge script script/12_DeployZROIRM.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste KINK_IRM_ZRO into .env
contract DeployZROIRM is Script {
    // ZRO Borrow IRM: Base=2%, Kink(70%)=15%, Max=200%
    uint256 constant ZRO_IRM_BASE   = 627_520_268_750_923_800;
    uint256 constant ZRO_IRM_SLOPE1 = 1_264_389_925;
    uint256 constant ZRO_IRM_SLOPE2 = 23_581_675_779;
    uint32  constant ZRO_IRM_KINK   = 3_006_477_107; // 70% utilization

    function run() external {
        vm.startBroadcast();

        address zroIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            ZRO_IRM_BASE, ZRO_IRM_SLOPE1, ZRO_IRM_SLOPE2, ZRO_IRM_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 12 COMPLETE: ZRO IRM Deployed ===");
        console.log("KINK_IRM_ZRO=%s  (Base=2%%, Kink(70%%)=15%%, Max=200%%)", zroIrm);
        console.log("\nPaste into .env, then run 13_DeployZROBorrowVault.s.sol");
    }
}
