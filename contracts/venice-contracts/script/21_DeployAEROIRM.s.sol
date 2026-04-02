// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external
        returns (address);
}

/// @title 21_DeployAEROIRM
/// @notice Step 21: Deploy a KinkIRM for AERO borrow market.
///
///   AERO Borrow IRM:  Base=0%, Kink(85%)=16%, Max=750%
///
///   Compute params with:
///     node ../../reference/evk-periphery/script/utils/calculate-irm-linear-kink.js \
///       borrow 0 16 750 85
///
/// @dev Run:
///      source .env && forge script script/21_DeployAEROIRM.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste KINK_IRM_AERO into .env
contract DeployAEROIRM is Script {
    // AERO Borrow IRM: Base=0%, Kink(85%)=16%, Max=750%
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 16 750 85
    uint256 constant AERO_IRM_BASE   = 0;
    uint256 constant AERO_IRM_SLOPE1 = 1_288_304_743;
    uint256 constant AERO_IRM_SLOPE2 = 97_963_887_950;
    uint32  constant AERO_IRM_KINK   = 3_650_722_201; // 85% utilization

    function run() external {
        vm.startBroadcast();

        address aeroIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            AERO_IRM_BASE, AERO_IRM_SLOPE1, AERO_IRM_SLOPE2, AERO_IRM_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 21 COMPLETE: AERO IRM Deployed ===");
        console.log("KINK_IRM_AERO=%s  (Base=0%%, Kink(85%%)=16%%, Max=750%%)", aeroIrm);
        console.log("\nPaste into .env, then run 22_DeployAEROBorrowVault.s.sol");
    }
}
