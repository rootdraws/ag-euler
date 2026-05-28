// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 01_DeployIRM
/// @notice Step 1 of 7: Deploy a KinkIRM for the USDC borrow vault.
///
/// @dev Target rates (defensive curve for a small test market):
///      Base (0% util)   = 1% APY
///      Kink (80% util)  = 8% APY
///      Max (100% util)  = 100% APY
///
///      Computed via:
///        node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 1 8 100 80
///
/// @dev Run:
///      source .env && forge script script/01_DeployIRM.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste KINK_IRM=<address> into .env, then run 02_DeployRouter.s.sol
contract DeployIRM is Script {
    // Base=1.00% APY, Kink(80.00%)=8.00% APY, Max=100.00% APY
    uint256 constant IRM_BASE   = 315_313_405_426_480_960;
    uint256 constant IRM_SLOPE1 = 618_015_444;
    uint256 constant IRM_SLOPE2 = 22_731_443_648;
    uint32  constant IRM_KINK   = 3_435_973_836; // 80% of type(uint32).max

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
        console.log("\nPaste into .env, then run 02_DeployRouter.s.sol");
    }
}
