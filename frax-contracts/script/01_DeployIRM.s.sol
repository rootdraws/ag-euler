// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external
        returns (address);
}

/// @title 01_DeployIRM
/// @notice Step 1 of 7: Deploy a KinkIRM for the frxUSD borrow market.
///
///   Base=0%, Kink(95%)=6% APY, Max=80% APY
///   Computed: node -e "..." (see parameters below)
///
/// @dev Usage:
///   source .env
///   forge script script/01_DeployIRM.s.sol:DeployIRM \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: KINK_IRM=<address>
contract DeployIRM is Script {
    // Base=0%, Kink(95%)=6% APY, Max=80% APY
    uint256 constant IRM_BASE   = 0;
    uint256 constant IRM_SLOPE1 = 452_541_450;
    uint256 constant IRM_SLOPE2 = 78_136_798_523;
    uint32  constant IRM_KINK   = 4_080_218_930;

    function run() external {
        vm.startBroadcast();

        address irm = IKinkIRMFactory(Addresses.KINK_IRM_FACTORY).deploy(
            IRM_BASE,
            IRM_SLOPE1,
            IRM_SLOPE2,
            IRM_KINK
        );

        vm.stopBroadcast();

        console.log("=== STEP 1 COMPLETE: IRM Deployed ===");
        console.log("KinkIRM:", irm);
        console.log("\nAdd to .env: KINK_IRM=%s", irm);
        console.log("Run 02_DeployRouter.s.sol next.");
    }
}
