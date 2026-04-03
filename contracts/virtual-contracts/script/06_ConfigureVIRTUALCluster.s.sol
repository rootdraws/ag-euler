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

/// @title 06_ConfigureVIRTUALCluster
/// @notice Step 6: Configure VIRTUAL borrow vault, activate vaults, and add VIRTUAL collateral
///         to existing VVV cluster vaults.
///
/// @dev A. VIRTUAL Borrow Vault (new):
///        - Activate (setHookConfig(0,0) on borrow + collateral vaults)
///        - Set IRM (VIRTUAL-specific: Base=0%, Kink 80%=15%, Max=100%)
///        - Set interest fee, liquidation params, caps
///        - Accept USDC, VVV, WETH, ZRO, AERO collateral vaults (85%/87% LTV)
///
///      B. Existing VVV/USDC/ETH/ZRO/AERO Borrow Vaults:
///        - Add VIRTUAL collateral vault (85%/87% LTV)
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM_VIRTUAL, VIRTUAL_BORROW_VAULT, VIRTUAL_COLLATERAL_VAULT,
///      VVV_BORROW_VAULT, USDC_BORROW_VAULT, ETH_BORROW_VAULT, ZRO_BORROW_VAULT, AERO_BORROW_VAULT,
///      USDC_COLLATERAL_VAULT, VVV_COLLATERAL_VAULT, WETH_COLLATERAL_VAULT, ZRO_COLLATERAL_VAULT, AERO_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureVIRTUALCluster.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract ConfigureVIRTUALCluster is Script {
    uint16 constant BORROW_LTV      = 0.85e4; // 85%
    uint16 constant LIQUIDATION_LTV = 0.87e4; // 87%

    // Caps: 3,300,000 VIRTUAL (18 dec) = 3.3 × 10^24 smallest unit
    // mantissa=33, exp=23 → (33 << 6) | 23 = 2135
    uint16 constant VIRTUAL_CAP = 2135;

    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;       // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4;  // 10%

    function run() external {
        address virtualIrm          = vm.envAddress("KINK_IRM_VIRTUAL");
        address virtualBorrowVault  = vm.envAddress("VIRTUAL_BORROW_VAULT");
        address virtualCollVault    = vm.envAddress("VIRTUAL_COLLATERAL_VAULT");
        address vvvBorrowVault      = vm.envAddress("VVV_BORROW_VAULT");
        address usdcBorrowVault     = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault      = vm.envAddress("ETH_BORROW_VAULT");
        address zroBorrowVault      = vm.envAddress("ZRO_BORROW_VAULT");
        address aeroBorrowVault     = vm.envAddress("AERO_BORROW_VAULT");
        address usdcCollVault       = vm.envAddress("USDC_COLLATERAL_VAULT");
        address vvvCollVault        = vm.envAddress("VVV_COLLATERAL_VAULT");
        address wethCollVault       = vm.envAddress("WETH_COLLATERAL_VAULT");
        address zroCollVault        = vm.envAddress("ZRO_COLLATERAL_VAULT");
        address aeroCollVault       = vm.envAddress("AERO_COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── Activate VIRTUAL vaults (clear factory default hookedOps) ──
        IEVault(virtualBorrowVault).setHookConfig(address(0), 0);
        IEVault(virtualCollVault).setHookConfig(address(0), 0);

        // ── A. Configure VIRTUAL Borrow Vault (new) ──
        IEVault virtualBorrow = IEVault(virtualBorrowVault);
        virtualBorrow.setInterestRateModel(virtualIrm);
        virtualBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        virtualBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        virtualBorrow.setInterestFee(INTEREST_FEE);
        virtualBorrow.setCaps(VIRTUAL_CAP, VIRTUAL_CAP); // 3,300,000 VIRTUAL supply & borrow
        virtualBorrow.setLTV(usdcCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        virtualBorrow.setLTV(vvvCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        virtualBorrow.setLTV(wethCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        virtualBorrow.setLTV(zroCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        virtualBorrow.setLTV(aeroCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── B. Add VIRTUAL collateral to existing borrow vaults ──
        IEVault(vvvBorrowVault).setLTV(virtualCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(usdcBorrowVault).setLTV(virtualCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(ethBorrowVault).setLTV(virtualCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(zroBorrowVault).setLTV(virtualCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        IEVault(aeroBorrowVault).setLTV(virtualCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: VIRTUAL Configured in VVV Cluster ===");
        console.log("\nVIRTUAL Borrow Vault: %s", virtualBorrowVault);
        console.log("  IRM:              %s (Base=0%%, Kink(80%%)=15%%, Max=100%%)", virtualIrm);
        console.log("  Caps:             3,300,000 VIRTUAL supply & borrow");
        console.log("  Collateral:       USDC coll (%s) - 85%%/87%%", usdcCollVault);
        console.log("  Collateral:       VVV coll  (%s) - 85%%/87%%", vvvCollVault);
        console.log("  Collateral:       WETH coll (%s) - 85%%/87%%", wethCollVault);
        console.log("  Collateral:       ZRO coll  (%s) - 85%%/87%%", zroCollVault);
        console.log("  Collateral:       AERO coll (%s) - 85%%/87%%", aeroCollVault);
        console.log("\nExisting vaults - added VIRTUAL collateral (%s):", virtualCollVault);
        console.log("  VVV borrow:  %s - 85%%/87%%", vvvBorrowVault);
        console.log("  USDC borrow: %s - 85%%/87%%", usdcBorrowVault);
        console.log("  ETH borrow:  %s - 85%%/87%%", ethBorrowVault);
        console.log("  ZRO borrow:  %s - 85%%/87%%", zroBorrowVault);
        console.log("  AERO borrow: %s - 85%%/87%%", aeroBorrowVault);
        console.log("\nRun 07_SetVIRTUALFeeReceiver.s.sol next.");
    }
}
