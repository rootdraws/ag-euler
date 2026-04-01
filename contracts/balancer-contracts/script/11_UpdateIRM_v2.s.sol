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

/// @title 11_UpdateIRM_v2
/// @notice Raise IRM curves while collateral incentives are active.
///         AUSD: 3.5% → 15% at kink.  WMON: 9% → 20% at kink.
///
/// @dev AUSD IRM: Base=0%, Kink(93%)=15% APY, Max=100% APY
///      node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 15 100 93
///
/// @dev WMON IRM: Base=0%, Kink(93%)=20% APY, Max=100% APY
///      node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 20 100 93
///
/// @dev Run:
///      source .env && forge script script/11_UpdateIRM_v2.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --gas-estimate-multiplier 400
contract UpdateIRM_v2 is Script {
    address constant KINK_IRM_FACTORY = 0x05Cccb5d0f1e1D568804453B82453a719Dc53758;

    // AUSD: Base=0%, Kink(93%)=15% APY, Max=100% APY
    uint256 constant AUSD_BASE   = 0;
    uint256 constant AUSD_SLOPE1 = 1_108_794_511;
    uint256 constant AUSD_SLOPE2 = 58_327_668_759;
    uint32  constant AUSD_KINK   = 3_994_319_585;

    // WMON: Base=0%, Kink(93%)=20% APY, Max=100% APY
    uint256 constant WMON_BASE   = 0;
    uint256 constant WMON_SLOPE1 = 1_446_439_121;
    uint256 constant WMON_SLOPE2 = 53_841_818_943;
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

        console.log("\n=== IRM UPDATE v2 COMPLETE ===");
        console.log("AUSD_KINK_IRM=%s  (15%% at 93%% kink)", ausdIrm);
        console.log("WMON_KINK_IRM=%s  (20%% at 93%% kink)", wmonIrm);
        console.log("\nPaste into .env. Previous IRMs are now unused.");
    }
}
