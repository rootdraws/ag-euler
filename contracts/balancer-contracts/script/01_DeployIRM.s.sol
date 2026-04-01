// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IKinkIRMFactory {
    /// @dev deploy(baseRate, slope1, slope2, kink) — standard 2-slope linear IRM
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

/// @title 01_DeployIRM
/// @notice Step 1 of 6: Deploy the KinkIRM for both borrow vaults.
///
/// @dev Uses kinkIRMFactory (EulerKinkIRM, 2-slope linear) NOT kinkyIRMFactory (IRMLinearKinky,
///      non-linear 5-param curve). The calculator output maps to the 4-param kink interface.
///
/// @dev IRM parameters: Base=0%, Kink(93%)=5% APY, Max=100% APY
///      Computed via: node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 5 100 93
///
/// @dev Run:
///      source .env && forge script script/01_DeployIRM.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --verify
///
/// @dev After running: paste KINK_IRM=<address> into .env, then run 02_DeployRouter.s.sol
contract DeployIRM is Script {
    address constant KINK_IRM_FACTORY = 0x05Cccb5d0f1e1D568804453B82453a719Dc53758;

    // Base=0%, Kink(93%)=5% APY, Max=100% APY
    // node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 5 100 93
    uint256 constant IRM_BASE   = 0;
    uint256 constant IRM_SLOPE1 = 387_074_372;
    uint256 constant IRM_SLOPE2 = 67_916_236_305;
    uint32  constant IRM_KINK   = 3_994_319_585;

    function run() external {
        vm.startBroadcast();

        address irm = IKinkIRMFactory(KINK_IRM_FACTORY).deploy(
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
