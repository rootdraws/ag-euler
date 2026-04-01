// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setInterestRateModel(address irm) external;
    function setMaxLiquidationDiscount(uint16 discount) external;
    function setLiquidationCoolOffTime(uint16 coolOffTime) external;
    function setCaps(uint16 supplyCap, uint16 borrowCap) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function setInterestFee(uint16 fee) external;
}

/// @title 16_ConfigureZROCluster
/// @notice Step 16: Configure ZRO borrow vault and add ZRO collateral to existing VVV cluster vaults.
///
/// @dev A. ZRO Borrow Vault (new):
///        - Set IRM (ZRO-specific: Base=2%, Kink 70%=15%, Max=200%)
///        - Set interest fee, liquidation params, caps
///        - Accept USDC, VVV, WETH collateral vaults (80%/85% LTV — matches VVV cluster)
///
///      B. Existing VVV/USDC/ETH Borrow Vaults:
///        - Add ZRO collateral vault (80%/85% LTV)
///        - Does NOT change IRM, caps, or other config on existing vaults
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM_ZRO, ZRO_BORROW_VAULT,
///      VVV_BORROW_VAULT, USDC_BORROW_VAULT, ETH_BORROW_VAULT,
///      USDC_COLLATERAL_VAULT, VVV_COLLATERAL_VAULT, WETH_COLLATERAL_VAULT, ZRO_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/16_ConfigureZROCluster.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract ConfigureZROCluster is Script {
    // Match VVV cluster uniform LTVs
    uint16 constant BORROW_LTV      = 0.80e4; // 80%
    uint16 constant LIQUIDATION_LTV = 0.85e4; // 85%

    // Caps: 185,000 ZRO (mantissa=185, exp=23 → (185 << 6) | 23 = 11863)
    uint16 constant ZRO_CAP = 11863;

    // Shared parameters (match VVV cluster)
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;       // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4;  // 10%

    function run() external {
        address zroIrm          = vm.envAddress("KINK_IRM_ZRO");
        address zroBorrowVault  = vm.envAddress("ZRO_BORROW_VAULT");
        address vvvBorrowVault  = vm.envAddress("VVV_BORROW_VAULT");
        address usdcBorrowVault = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault  = vm.envAddress("ETH_BORROW_VAULT");
        address usdcCollVault   = vm.envAddress("USDC_COLLATERAL_VAULT");
        address vvvCollVault    = vm.envAddress("VVV_COLLATERAL_VAULT");
        address wethCollVault   = vm.envAddress("WETH_COLLATERAL_VAULT");
        address zroCollVault    = vm.envAddress("ZRO_COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── A. Configure ZRO Borrow Vault (new) ──
        IEVault zroBorrow = IEVault(zroBorrowVault);
        zroBorrow.setInterestRateModel(zroIrm);
        zroBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        zroBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        zroBorrow.setInterestFee(INTEREST_FEE);
        zroBorrow.setCaps(ZRO_CAP, ZRO_CAP); // 185,000 ZRO supply & borrow
        zroBorrow.setLTV(usdcCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        zroBorrow.setLTV(vvvCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        zroBorrow.setLTV(wethCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── B. Add ZRO collateral to existing VVV borrow vault ──
        IEVault(vvvBorrowVault).setLTV(zroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── C. Add ZRO collateral to existing USDC borrow vault ──
        IEVault(usdcBorrowVault).setLTV(zroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── D. Add ZRO collateral to existing ETH borrow vault ──
        IEVault(ethBorrowVault).setLTV(zroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 16 COMPLETE: ZRO Configured in VVV Cluster ===");
        console.log("\nZRO Borrow Vault: %s", zroBorrowVault);
        console.log("  IRM:              %s (Base=2%%, Kink(70%%)=15%%, Max=200%%)", zroIrm);
        console.log("  Caps:             185,000 ZRO supply & borrow");
        console.log("  Collateral:       USDC coll (%s) - 80%%/85%%", usdcCollVault);
        console.log("  Collateral:       VVV coll  (%s) - 80%%/85%%", vvvCollVault);
        console.log("  Collateral:       WETH coll (%s) - 80%%/85%%", wethCollVault);
        console.log("\nExisting vaults - added ZRO collateral (%s):", zroCollVault);
        console.log("  VVV borrow:  %s - 80%%/85%%", vvvBorrowVault);
        console.log("  USDC borrow: %s - 80%%/85%%", usdcBorrowVault);
        console.log("  ETH borrow:  %s - 80%%/85%%", ethBorrowVault);
        console.log("\nRun 17_SetZROFeeReceiver.s.sol next.");
    }
}
