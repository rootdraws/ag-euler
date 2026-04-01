// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setInterestRateModel(address irm) external;
    function setInterestFee(uint16 fee) external;
    function setMaxLiquidationDiscount(uint16 discount) external;
    function setLiquidationCoolOffTime(uint16 coolOffTime) external;
    function setCaps(uint16 supplyCap, uint16 borrowCap) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
}

/// @title 06_ConfigureCluster
/// @notice Step 6 of 7: Configure ZRO vault and add ZRO collateral to existing vaults.
///
///   A. ZRO Borrow Vault (new):
///     - Set IRM, interest fee, liquidation params, caps
///     - Accept USDC vault as collateral (70% / 75%)
///     - Accept ETH vault as collateral (70% / 75%)
///
///   B. Existing USDC Borrow Vault:
///     - Add ZRO vault as collateral (70% / 75%)
///
///   C. Existing ETH Borrow Vault:
///     - Add ZRO vault as collateral (70% / 75%)
///
///   Does NOT change IRM, caps, or other config on existing vaults.
///
/// @dev Usage:
///   source .env
///   forge script script/06_ConfigureCluster.s.sol:ConfigureCluster \
///     --rpc-url base --broadcast -vvvv
contract ConfigureCluster is Script {
    // Uniform LTV for all ZRO collateral relationships
    uint16 constant BORROW_LTV = 7000; // 70%
    uint16 constant LIQ_LTV   = 7500; // 75%

    uint16 constant MAX_LIQ_DISCOUNT = 500;  // 5%
    uint16 constant LIQ_COOL_OFF     = 1;    // 1 second
    uint16 constant INTEREST_FEE     = 1000; // 10%

    // Caps: 16-bit float encoding = (mantissa << 6) | exponent
    uint16 constant ZRO_CAP = 11863; // 185,000 ZRO (mantissa=185, exp=23 → 1.85e23 wei)

    function run() external {
        address zroIrm    = vm.envAddress("KINK_IRM_ZRO");
        address zroVault  = vm.envAddress("ZRO_BORROW_VAULT");
        address usdcVault = vm.envAddress("USDC_BORROW_VAULT");
        address ethVault  = vm.envAddress("ETH_BORROW_VAULT");

        vm.startBroadcast();

        // ─── A. Configure ZRO Borrow Vault (new) ───
        IEVault zro = IEVault(zroVault);
        zro.setInterestRateModel(zroIrm);
        zro.setInterestFee(INTEREST_FEE);
        zro.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        zro.setLiquidationCoolOffTime(LIQ_COOL_OFF);
        zro.setLTV(usdcVault, BORROW_LTV, LIQ_LTV, 0); // USDC vault as collateral
        zro.setLTV(ethVault,  BORROW_LTV, LIQ_LTV, 0);  // ETH vault as collateral
        zro.setCaps(ZRO_CAP, ZRO_CAP); // 185,000 ZRO supply & borrow

        // ─── B. Add ZRO collateral to existing USDC vault ───
        IEVault(usdcVault).setLTV(zroVault, BORROW_LTV, LIQ_LTV, 0);

        // ─── C. Add ZRO collateral to existing ETH vault ───
        IEVault(ethVault).setLTV(zroVault, BORROW_LTV, LIQ_LTV, 0);

        vm.stopBroadcast();

        console.log("=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("");
        console.log("ZRO Borrow Vault: %s", zroVault);
        console.log("  IRM:              %s", zroIrm);
        console.log("  Collateral:       USDC vault (%s) - 70%%/75%%", usdcVault);
        console.log("  Collateral:       ETH vault  (%s) - 70%%/75%%", ethVault);
        console.log("  Caps:             185,000 ZRO supply & borrow");
        console.log("");
        console.log("USDC Borrow Vault: %s (existing)", usdcVault);
        console.log("  Added collateral: ZRO vault (%s) - 70%%/75%%", zroVault);
        console.log("");
        console.log("ETH Borrow Vault: %s (existing)", ethVault);
        console.log("  Added collateral: ZRO vault (%s) - 70%%/75%%", zroVault);
        console.log("\nRun 07_SetFeeReceiver.s.sol next.");
    }
}
