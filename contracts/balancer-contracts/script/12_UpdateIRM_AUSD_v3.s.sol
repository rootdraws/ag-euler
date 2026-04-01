// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address irm);
}

interface IEVault {
    function setInterestRateModel(address irm) external;
}

/// @title 12_UpdateIRM_AUSD_v3
/// @notice Lower AUSD kink from 15% → 10% to recover utilization.
///
/// @dev AUSD IRM: Base=0%, Kink(93%)=10% APY, Max=100% APY
///      node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 10 100 93
///
/// @dev Run:
///      source .env && forge script script/12_UpdateIRM_AUSD_v3.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --gas-estimate-multiplier 400
contract UpdateIRM_AUSD_v3 is Script {
    address constant KINK_IRM_FACTORY = 0x05Cccb5d0f1e1D568804453B82453a719Dc53758;

    // AUSD: Base=0%, Kink(93%)=10% APY, Max=100% APY
    uint256 constant AUSD_BASE   = 0;
    uint256 constant AUSD_SLOPE1 = 756_138_630;
    uint256 constant AUSD_SLOPE2 = 63_012_954_036;
    uint32  constant AUSD_KINK   = 3_994_319_585;

    function run() external {
        address ausdBorrowVault = vm.envAddress("AUSD_BORROW_VAULT");

        vm.startBroadcast();

        address ausdIrm = IKinkIRMFactory(KINK_IRM_FACTORY).deploy(
            AUSD_BASE, AUSD_SLOPE1, AUSD_SLOPE2, AUSD_KINK
        );

        IEVault(ausdBorrowVault).setInterestRateModel(ausdIrm);

        vm.stopBroadcast();

        console.log("\n=== AUSD IRM v3 COMPLETE ===");
        console.log("AUSD_KINK_IRM_V3=%s  (10%% at 93%% kink)", ausdIrm);
        console.log("\nPaste into .env.");
    }
}
