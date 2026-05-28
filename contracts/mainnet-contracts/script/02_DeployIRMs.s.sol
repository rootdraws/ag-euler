// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 02_DeployIRMs
/// @notice Step 2 of 6: Deploy KinkIRMs for the new USDC and WBTC borrow vaults.
///
/// @dev USDC target (stablecoin, tight through kink, steep cap):
///        Base (0% util)   = 0%     APY
///        Kink (92% util)  = 4.5%   APY
///        Max (100% util)  = 50%    APY
///      Computed via:
///        node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 4.5 50 92
///
/// @dev WBTC target (volatile major, classic curve):
///        Base (0% util)   = 0%     APY
///        Kink (80% util)  = 3%     APY
///        Max (100% util)  = 80%    APY
///      Computed via:
///        node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 3 80 80
///
/// @dev Run:
///      source .env && forge script script/02_DeployIRMs.s.sol \
///        --rpc-url $RPC_URL_MAINNET --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running, paste into .env:
///      USDC_IRM=<address>
///      WBTC_IRM=<address>
contract DeployIRMs is Script {
    // ─── USDC IRM: Base=0% / Kink(92%)=4.5% / Max=50% APY ───
    uint256 constant USDC_BASE   = 0;
    uint256 constant USDC_SLOPE1 = 353_001_513;
    uint256 constant USDC_SLOPE2 = 33_335_056_539;
    uint32  constant USDC_KINK   = 3_951_369_912; // 92%

    // ─── WBTC IRM: Base=0% / Kink(80%)=3% / Max=80% APY ───
    uint256 constant WBTC_BASE   = 0;
    uint256 constant WBTC_SLOPE1 = 272_610_093;
    uint256 constant WBTC_SLOPE2 = 20_593_331_113;
    uint32  constant WBTC_KINK   = 3_435_973_836; // 80%

    function run() external {
        vm.startBroadcast();

        address usdcIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            USDC_BASE, USDC_SLOPE1, USDC_SLOPE2, USDC_KINK
        );

        address wbtcIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            WBTC_BASE, WBTC_SLOPE1, WBTC_SLOPE2, WBTC_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: KinkIRMs ===");
        console.log("USDC_IRM=%s", usdcIrm);
        console.log("WBTC_IRM=%s", wbtcIrm);
        console.log("\nPaste into .env, then run 03_DeployVaults.s.sol");
    }
}
