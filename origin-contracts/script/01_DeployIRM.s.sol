// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 01_DeployIRM
/// @notice Step 1 of 6: Deploy a KinkIRM tuned for the ARM/WETH market.
///
/// @dev Target rates:
///      Base (0% util)  = 0.5% APY
///      Kink (80% util) = 2.5% APY
///      Max (100% util) = 50%  APY
///
///      These keep the equilibrium borrow cost well below ARM's ~4.79% yield,
///      leaving margin for leveraged loopers while attracting WETH supply.
///
/// @dev Run:
///      source .env && forge script script/01_DeployIRM.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste KINK_IRM=<address> into .env, then run 02_DeployRouter.s.sol
contract DeployIRM is Script {
    // Base=0.5%, Kink(80%)=2.5%, Max=50% APY
    // slope = (targetRateRay - prevRateRay) / utilizationDelta_uint32
    uint256 constant IRM_BASE   = 158_443_692_534_057_180;
    uint256 constant IRM_SLOPE1 = 184_452_734;
    uint256 constant IRM_SLOPE2 = 17_523_009_788;
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
