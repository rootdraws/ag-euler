// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 01_DeployIRMs
/// @notice Step 1 of 7: Deploy KinkIRMs for the USDT and BNB borrow vaults.
///
/// @dev Target rates:
///
///      USDT (stablecoin):
///        Base (0% util)   = 0% APY
///        Kink (90% util)  = 8% APY
///        Max  (100% util) = 150% APY
///
///      BNB (volatile major):
///        Base (0% util)   = 0.5% APY
///        Kink (80% util)  = 8% APY
///        Max  (100% util) = 80% APY
///
/// @dev TODO: Compute ray/sec constants with the Euler calculator before deploy:
///      node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow <base> <kink> <max> <kinkPct>
///
///      Placeholders below must be replaced with real values from the calculator.
///
/// @dev Run:
///      source .env && forge script script/01_DeployIRMs.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
///
/// @dev After running: paste KINK_IRM_USDT and KINK_IRM_BNB into .env
contract DeployIRMs is Script {
    // ── USDT IRM: Base=0%, Kink(90%)=8%, Max=150% APY ──
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 8 150 90
    uint256 constant USDT_BASE   = 0;
    uint256 constant USDT_SLOPE1 = 630_918_865;
    uint256 constant USDT_SLOPE2 = 61_926_662_555;
    uint32  constant USDT_KINK   = 3_865_470_566; // 90% of type(uint32).max

    // ── BNB IRM: Base=0.5%, Kink(80%)=8%, Max=80% APY ──
    // Computed via: node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0.5 8 80 80
    uint256 constant BNB_BASE   = 158_048_882_541_000_800;
    uint256 constant BNB_SLOPE1 = 663_785_444;
    uint256 constant BNB_SLOPE2 = 18_844_636_593;
    uint32  constant BNB_KINK   = 3_435_973_836; // 80% of type(uint32).max

    function run() external {
        vm.startBroadcast();

        address usdtIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            USDT_BASE, USDT_SLOPE1, USDT_SLOPE2, USDT_KINK
        );

        address bnbIrm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            BNB_BASE, BNB_SLOPE1, BNB_SLOPE2, BNB_KINK
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 1 COMPLETE: KinkIRMs ===");
        console.log("KINK_IRM_USDT=%s", usdtIrm);
        console.log("KINK_IRM_BNB=%s",  bnbIrm);
        console.log("\nPaste into .env, then run 02_DeployRouter.s.sol");
    }
}
