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
    function setHookConfig(address hookTarget, uint32 hookedOps) external;
}

/// @title 25_ConfigureAEROCluster
/// @notice Step 25: Configure AERO borrow vault, activate vaults, and add AERO collateral
///         to existing VVV cluster vaults.
///
/// @dev A. AERO Borrow Vault (new):
///        - Activate (setHookConfig(0,0) on borrow + collateral vaults)
///        - Set IRM (AERO-specific: Base=0%, Kink 85%=16%, Max=750%)
///        - Set interest fee, liquidation params, caps
///        - Accept USDC, VVV, WETH, ZRO collateral vaults (80%/85% LTV)
///
///      B. Existing VVV/USDC/ETH/ZRO Borrow Vaults:
///        - Add AERO collateral vault (80%/85% LTV)
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM_AERO, AERO_BORROW_VAULT, AERO_COLLATERAL_VAULT,
///      VVV_BORROW_VAULT, USDC_BORROW_VAULT, ETH_BORROW_VAULT, ZRO_BORROW_VAULT,
///      USDC_COLLATERAL_VAULT, VVV_COLLATERAL_VAULT, WETH_COLLATERAL_VAULT, ZRO_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/25_ConfigureAEROCluster.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract ConfigureAEROCluster is Script {
    uint16 constant BORROW_LTV      = 0.80e4; // 80%
    uint16 constant LIQUIDATION_LTV = 0.85e4; // 85%

    // Caps: 10,000,000 AERO (18 dec) = 10^25 smallest unit
    // mantissa=100, exp=23 → (100 << 6) | 23 = 6423
    uint16 constant AERO_CAP = 6423;

    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;       // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4;  // 10%

    function run() external {
        address aeroIrm          = vm.envAddress("KINK_IRM_AERO");
        address aeroBorrowVault  = vm.envAddress("AERO_BORROW_VAULT");
        address aeroCollVault    = vm.envAddress("AERO_COLLATERAL_VAULT");
        address vvvBorrowVault   = vm.envAddress("VVV_BORROW_VAULT");
        address usdcBorrowVault  = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault   = vm.envAddress("ETH_BORROW_VAULT");
        address zroBorrowVault   = vm.envAddress("ZRO_BORROW_VAULT");
        address usdcCollVault    = vm.envAddress("USDC_COLLATERAL_VAULT");
        address vvvCollVault     = vm.envAddress("VVV_COLLATERAL_VAULT");
        address wethCollVault    = vm.envAddress("WETH_COLLATERAL_VAULT");
        address zroCollVault     = vm.envAddress("ZRO_COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── Activate AERO vaults (clear factory default hookedOps) ──
        IEVault(aeroBorrowVault).setHookConfig(address(0), 0);
        IEVault(aeroCollVault).setHookConfig(address(0), 0);

        // ── A. Configure AERO Borrow Vault (new) ──
        IEVault aeroBorrow = IEVault(aeroBorrowVault);
        aeroBorrow.setInterestRateModel(aeroIrm);
        aeroBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        aeroBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        aeroBorrow.setInterestFee(INTEREST_FEE);
        aeroBorrow.setCaps(AERO_CAP, AERO_CAP); // 10,000,000 AERO supply & borrow
        aeroBorrow.setLTV(usdcCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        aeroBorrow.setLTV(vvvCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        aeroBorrow.setLTV(wethCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        aeroBorrow.setLTV(zroCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── B. Add AERO collateral to existing borrow vaults ──
        IEVault(vvvBorrowVault).setLTV(aeroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(usdcBorrowVault).setLTV(aeroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(ethBorrowVault).setLTV(aeroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(zroBorrowVault).setLTV(aeroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 25 COMPLETE: AERO Configured in VVV Cluster ===");
        console.log("\nAERO Borrow Vault: %s", aeroBorrowVault);
        console.log("  IRM:              %s (Base=0%%, Kink(85%%)=16%%, Max=750%%)", aeroIrm);
        console.log("  Caps:             10,000,000 AERO supply & borrow");
        console.log("  Collateral:       USDC coll (%s) - 80%%/85%%", usdcCollVault);
        console.log("  Collateral:       VVV coll  (%s) - 80%%/85%%", vvvCollVault);
        console.log("  Collateral:       WETH coll (%s) - 80%%/85%%", wethCollVault);
        console.log("  Collateral:       ZRO coll  (%s) - 80%%/85%%", zroCollVault);
        console.log("\nExisting vaults - added AERO collateral (%s):", aeroCollVault);
        console.log("  VVV borrow:  %s - 80%%/85%%", vvvBorrowVault);
        console.log("  USDC borrow: %s - 80%%/85%%", usdcBorrowVault);
        console.log("  ETH borrow:  %s - 80%%/85%%", ethBorrowVault);
        console.log("  ZRO borrow:  %s - 80%%/85%%", zroBorrowVault);
        console.log("\nRun 26_SetAEROFeeReceiver.s.sol next.");
    }
}
