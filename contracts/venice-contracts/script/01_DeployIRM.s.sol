// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 01_DeployIRM
/// @notice Step 1 of 10: Deploy a KinkIRM for the VVV/USDC/ETH markets.
///
/// @dev Target rates (conservative for volatile token):
///      Base (0% util)  = 1% APY
///      Kink (80% util) = 40% APY
///      Max (100% util) = 100% APY
///
/// @dev Run:
///      source .env && forge script script/01_DeployIRM.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste KINK_IRM=<address> into .env
contract DeployIRM is Script {
    // Base=1%, Kink(80%)=40%, Max=100% APY
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 1 40 100 80
    // If the calculator is unavailable, recalculate these constants before deploying.
    //
    // Approximate values (verify with calculator):
    //   baseRate  ≈ 1% APY in ray/sec
    //   slope1    = (kinkRate - baseRate) / kinkUtil_uint32
    //   slope2    = (maxRate - kinkRate) / (type(uint32).max - kinkUtil_uint32)
    //   kink      = 80% of type(uint32).max = 3435973836
    uint256 constant IRM_BASE   = 315_313_405_426_480_960;  // ~1% APY in ray/sec
    uint256 constant IRM_SLOPE1 = 3_011_392_923;             // slope below kink
    uint256 constant IRM_SLOPE2 = 13_157_933_742;            // slope above kink (punitive)
    uint32  constant IRM_KINK   = 3_435_973_836;             // 80% of type(uint32).max

    function run() external {
        vm.startBroadcast();

        address irm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            IRM_BASE,
            IRM_SLOPE1,
            IRM_SLOPE2,
            IRM_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 1 COMPLETE: KinkIRM ===");
        console.log("KINK_IRM=%s", irm);
        console.log("\nPaste into .env, then run 02_DeployChainlinkAdapter.s.sol");
    }
}
