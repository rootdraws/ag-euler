// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external
        returns (address);
}

/// @title 02_DeployVIRTUALIRM
/// @notice Step 2: Deploy a KinkIRM for VIRTUAL borrow market.
///
///   VIRTUAL Borrow IRM:  Base=0%, Kink(80%)=15%, Max=100%
///
///   Compute params with:
///     node ../../reference/evk-periphery/script/utils/calculate-irm-linear-kink.js \
///       borrow 0 15 100 80
///
/// @dev Run:
///      source .env && forge script script/02_DeployVIRTUALIRM.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste KINK_IRM_VIRTUAL into .env
contract DeployVIRTUALIRM is Script {
    // VIRTUAL Borrow IRM: Base=0%, Kink(80%)=15%, Max=100%
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 15 100 80
    uint256 constant VIRTUAL_IRM_BASE   = 0;
    uint256 constant VIRTUAL_IRM_SLOPE1 = 1_288_973_619;
    uint256 constant VIRTUAL_IRM_SLOPE2 = 20_414_684_065;
    uint32  constant VIRTUAL_IRM_KINK   = 3_435_973_836; // 80% utilization

    function run() external {
        vm.startBroadcast();

        address virtualIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            VIRTUAL_IRM_BASE, VIRTUAL_IRM_SLOPE1, VIRTUAL_IRM_SLOPE2, VIRTUAL_IRM_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: VIRTUAL IRM Deployed ===");
        console.log("KINK_IRM_VIRTUAL=%s  (Base=0%%, Kink(80%%)=15%%, Max=100%%)", virtualIrm);
        console.log("\nPaste into .env, then run 03_DeployVIRTUALBorrowVault.s.sol");
    }
}
