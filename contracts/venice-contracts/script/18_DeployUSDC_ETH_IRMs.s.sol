// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 18_DeployUSDC_ETH_IRMs
/// @notice Deploy new KinkIRMs for the USDC and ETH borrow vaults.
///
/// @dev USDC target rates:
///      Base (0% util)   = 0% APY
///      Kink (90% util)  = 18.52% APY borrow → ~15% supply APY (with 10% reserve fee)
///      Max (100% util)  = 100% APY
///
/// @dev ETH target rates:
///      Base (0% util)   = 0% APY
///      Kink (90% util)  = 7.41% APY borrow → 6% supply APY (with 10% reserve fee)
///      Max (100% util)  = 100% APY
///
/// @dev Run:
///      source .env && forge script script/18_DeployUSDC_ETH_IRMs.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste USDC_IRM=<address> and ETH_IRM=<address> into .env
contract DeployUSDC_ETH_IRMs is Script {
    // ─── USDC IRM: Base=0%, Kink(90%)=18.52%, Max=100% APY ───
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 18.52 100 90
    uint256 constant USDC_BASE   = 0;
    uint256 constant USDC_SLOPE1 = 1_392_917_664;
    uint256 constant USDC_SLOPE2 = 38_604_898_109;
    uint32  constant USDC_KINK   = 3_865_470_566; // 90% of type(uint32).max

    // ─── ETH IRM: Base=0%, Kink(90%)=7.41%, Max=100% APY ───
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 7.4074 100 90
    uint256 constant ETH_BASE   = 0;
    uint256 constant ETH_SLOPE1 = 585_812_826;
    uint256 constant ETH_SLOPE2 = 45_868_841_646;
    uint32  constant ETH_KINK   = 3_865_470_566; // 90% of type(uint32).max

    function run() external {
        vm.startBroadcast();

        address usdcIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            USDC_BASE, USDC_SLOPE1, USDC_SLOPE2, USDC_KINK
        );

        address ethIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            ETH_BASE, ETH_SLOPE1, ETH_SLOPE2, ETH_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 18 COMPLETE: New IRMs Deployed ===");
        console.log("USDC_IRM=%s", usdcIrm);
        console.log("ETH_IRM=%s", ethIrm);
        console.log("\nPaste into .env, then run 19_UpdateIRMs.s.sol");
    }
}
