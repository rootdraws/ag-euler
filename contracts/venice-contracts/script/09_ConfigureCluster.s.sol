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

/// @title 09_ConfigureCluster
/// @notice Step 9 of 10: Configure risk parameters on all three borrow vaults.
///
/// @dev Market 1 -Borrow VVV: accepts USDC + WETH collateral
///      Market 2 -Borrow USDC: accepts VVV + WETH collateral
///      Market 3 -Borrow ETH: accepts USDC + VVV collateral
///
///      All markets use uniform 80%/85% LTV.
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM, VVV_BORROW_VAULT, USDC_BORROW_VAULT, ETH_BORROW_VAULT,
///      USDC_COLLATERAL_VAULT, VVV_COLLATERAL_VAULT, WETH_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/09_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract ConfigureCluster is Script {
    // ─── Uniform LTVs ───
    uint16 constant BORROW_LTV      = 0.80e4; // 80%
    uint16 constant LIQUIDATION_LTV = 0.85e4; // 85%

    // ─── Caps ───
    // AmountCap encoding: (mantissa << 6) | (scale + decimals)
    // 200,000 VVV (18 dec):   mantissa=200, exp=23 → (200 << 6) | 23 = 12823
    // 1,500,000 USDC (6 dec): mantissa=150, exp=12 → (150 << 6) | 12 = 9612
    // 800 WETH (18 dec):      mantissa=800, exp=20 → (800 << 6) | 20 = 51220
    uint16 constant VVV_CAP  = 12823; // 200,000 VVV
    uint16 constant USDC_CAP = 9612;  // 1,500,000 USDC
    uint16 constant WETH_CAP = 51220; // 800 WETH

    // ─── Shared parameters ───
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;       // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4;  // 10%

    function run() external {
        address irm              = vm.envAddress("KINK_IRM");
        address vvvBorrowVault   = vm.envAddress("VVV_BORROW_VAULT");
        address usdcBorrowVault  = vm.envAddress("USDC_BORROW_VAULT");
        address ethBorrowVault   = vm.envAddress("ETH_BORROW_VAULT");
        address usdcCollVault    = vm.envAddress("USDC_COLLATERAL_VAULT");
        address vvvCollVault     = vm.envAddress("VVV_COLLATERAL_VAULT");
        address wethCollVault    = vm.envAddress("WETH_COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── Market 1: Borrow VVV against USDC + WETH ──
        IEVault vvvBorrow = IEVault(vvvBorrowVault);
        vvvBorrow.setInterestRateModel(irm);
        vvvBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        vvvBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        vvvBorrow.setInterestFee(INTEREST_FEE);
        vvvBorrow.setCaps(VVV_CAP, VVV_CAP); // 200,000 VVV supply & borrow
        vvvBorrow.setLTV(usdcCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        vvvBorrow.setLTV(wethCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── Market 2: Borrow USDC against VVV + WETH ──
        IEVault usdcBorrow = IEVault(usdcBorrowVault);
        usdcBorrow.setInterestRateModel(irm);
        usdcBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        usdcBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        usdcBorrow.setInterestFee(INTEREST_FEE);
        usdcBorrow.setCaps(USDC_CAP, USDC_CAP); // 1,500,000 USDC supply & borrow
        usdcBorrow.setLTV(vvvCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);
        usdcBorrow.setLTV(wethCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── Market 3: Borrow ETH against USDC + VVV ──
        IEVault ethBorrow = IEVault(ethBorrowVault);
        ethBorrow.setInterestRateModel(irm);
        ethBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        ethBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        ethBorrow.setInterestFee(INTEREST_FEE);
        ethBorrow.setCaps(WETH_CAP, WETH_CAP); // 800 WETH supply & borrow
        ethBorrow.setLTV(usdcCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);
        ethBorrow.setLTV(vvvCollVault,  BORROW_LTV, LIQUIDATION_LTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 9 COMPLETE: All Markets Configured ===");
        console.log("\nMarket 1 -Borrow VVV (collateral: USDC, WETH):");
        console.log("  Vault: %s", vvvBorrowVault);
        console.log("\nMarket 2 -Borrow USDC (collateral: VVV, WETH):");
        console.log("  Vault: %s", usdcBorrowVault);
        console.log("\nMarket 3 -Borrow ETH (collateral: USDC, VVV):");
        console.log("  Vault: %s", ethBorrowVault);
        console.log("\nAll markets: LTV=80%%, LLTV=85%%, MaxLiqDiscount=5%%, InterestFee=10%%");
        console.log("IRM: %s", irm);
        console.log("\nRun 10_SetFeeReceiver.s.sol next.");
    }
}
