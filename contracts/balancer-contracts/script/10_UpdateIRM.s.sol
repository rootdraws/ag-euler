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

/// @title 10_UpdateIRM
/// @notice Deploy separate KinkIRMs for AUSD (3.5% at kink) and WMON (9% at kink),
///         then update each borrow vault's interest rate model.
///
/// @dev AUSD IRM: Base=0%, Kink(93%)=3.5% APY, Max=100% APY
///      node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 3.5 100 93
///
/// @dev WMON IRM: Base=0%, Kink(93%)=9% APY, Max=100% APY
///      node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 9 100 93
///
/// @dev Run:
///      source .env && forge script script/10_UpdateIRM.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --gas-estimate-multiplier 400
contract UpdateIRM is Script {
    address constant KINK_IRM_FACTORY = 0x05Cccb5d0f1e1D568804453B82453a719Dc53758;

    // AUSD: Base=0%, Kink(93%)=3.5% APY, Max=100% APY
    uint256 constant AUSD_BASE   = 0;
    uint256 constant AUSD_SLOPE1 = 272_922_025;
    uint256 constant AUSD_SLOPE2 = 69_432_831_773;
    uint32  constant AUSD_KINK   = 3_994_319_585;

    // WMON: Base=0%, Kink(93%)=9% APY, Max=100% APY
    uint256 constant WMON_BASE   = 0;
    uint256 constant WMON_SLOPE1 = 683_686_524;
    uint256 constant WMON_SLOPE2 = 63_975_532_014;
    uint32  constant WMON_KINK   = 3_994_319_585;

    function run() external {
        address ausdBorrowVault = vm.envAddress("AUSD_BORROW_VAULT");
        address wmonBorrowVault = vm.envAddress("WMON_BORROW_VAULT");

        vm.startBroadcast();

        address ausdIrm = IKinkIRMFactory(KINK_IRM_FACTORY).deploy(
            AUSD_BASE, AUSD_SLOPE1, AUSD_SLOPE2, AUSD_KINK
        );

        address wmonIrm = IKinkIRMFactory(KINK_IRM_FACTORY).deploy(
            WMON_BASE, WMON_SLOPE1, WMON_SLOPE2, WMON_KINK
        );

        IEVault(ausdBorrowVault).setInterestRateModel(ausdIrm);
        IEVault(wmonBorrowVault).setInterestRateModel(wmonIrm);

        vm.stopBroadcast();

        console.log("\n=== IRM UPDATE COMPLETE ===");
        console.log("AUSD_KINK_IRM=%s  (3.5%% at 93%% kink)", ausdIrm);
        console.log("WMON_KINK_IRM=%s  (9%% at 93%% kink)", wmonIrm);
        console.log("\nPaste into .env. Old shared IRM is now unused.");
    }
}
