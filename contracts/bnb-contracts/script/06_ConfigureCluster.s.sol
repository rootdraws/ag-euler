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

/// @title 06_ConfigureCluster
/// @notice Step 6 of 7: Activate all vaults and configure risk params for the USDT + BNB cluster.
///
/// @dev Market layout (cross-margin, 2 markets):
///        Borrow USDT ← BNB collateral  (88%/91% LTV — stable against volatile major)
///        Borrow BNB  ← USDT collateral (75%/80% LTV — volatile against stable)
///
/// @dev Activation: factory proxies ship with hookedOps=32767 (ALL ops disabled).
///      Must call setHookConfig(address(0), 0) on every vault to unblock user flows.
///
/// @dev Prerequisites (in .env):
///      KINK_IRM_USDT, KINK_IRM_BNB,
///      USDT_BORROW_VAULT, BNB_BORROW_VAULT,
///      USDT_COLLATERAL_VAULT, BNB_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER --broadcast
contract ConfigureCluster is Script {
    // ─── LTVs ───
    // USDT borrow vault accepts BNB collateral — conservative (volatile collateral)
    uint16 constant USDT_VAULT_BORROW_LTV      = 0.75e4; // 75%
    uint16 constant USDT_VAULT_LIQUIDATION_LTV = 0.80e4; // 80%

    // BNB borrow vault accepts USDT collateral — aggressive (stable collateral)
    uint16 constant BNB_VAULT_BORROW_LTV       = 0.88e4; // 88%
    uint16 constant BNB_VAULT_LIQUIDATION_LTV  = 0.91e4; // 91%

    // ─── Caps ───
    // AmountCap encoding: (mantissa << 6) | (scale + decimals)
    // ⚠ USDT is 18 decimals on BSC — NOT 6 like Ethereum/Base.
    //
    // 2,000,000 USDT (18 dec): mantissa=200, exp=22 → (200 << 6) | 22 = 12822
    // 5,000 WBNB   (18 dec):   mantissa=500, exp=19 → (500 << 6) | 19 = 32019
    uint16 constant USDT_CAP = 12822; // 2,000,000 USDT
    uint16 constant BNB_CAP  = 32019; // 5,000 WBNB

    // ─── Shared params ───
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;      // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4; // 10%

    function run() external {
        address usdtIrm         = vm.envAddress("KINK_IRM_USDT");
        address bnbIrm          = vm.envAddress("KINK_IRM_BNB");
        address usdtBorrowVault = vm.envAddress("USDT_BORROW_VAULT");
        address bnbBorrowVault  = vm.envAddress("BNB_BORROW_VAULT");
        address usdtCollVault   = vm.envAddress("USDT_COLLATERAL_VAULT");
        address bnbCollVault    = vm.envAddress("BNB_COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── Activate all 4 vaults (clear factory-default hookedOps=32767) ──
        IEVault(usdtBorrowVault).setHookConfig(address(0), 0);
        IEVault(bnbBorrowVault).setHookConfig(address(0), 0);
        IEVault(usdtCollVault).setHookConfig(address(0), 0);
        IEVault(bnbCollVault).setHookConfig(address(0), 0);

        // ── Market 1: Borrow USDT against BNB collateral ──
        IEVault usdtBorrow = IEVault(usdtBorrowVault);
        usdtBorrow.setInterestRateModel(usdtIrm);
        usdtBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        usdtBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        usdtBorrow.setInterestFee(INTEREST_FEE);
        usdtBorrow.setCaps(USDT_CAP, USDT_CAP);
        usdtBorrow.setLTV(bnbCollVault, USDT_VAULT_BORROW_LTV, USDT_VAULT_LIQUIDATION_LTV, 0);

        // ── Market 2: Borrow BNB against USDT collateral ──
        IEVault bnbBorrow = IEVault(bnbBorrowVault);
        bnbBorrow.setInterestRateModel(bnbIrm);
        bnbBorrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        bnbBorrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        bnbBorrow.setInterestFee(INTEREST_FEE);
        bnbBorrow.setCaps(BNB_CAP, BNB_CAP);
        bnbBorrow.setLTV(usdtCollVault, BNB_VAULT_BORROW_LTV, BNB_VAULT_LIQUIDATION_LTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("\nMarket 1 - Borrow USDT (collateral: BNB):");
        console.log("  Vault:  %s", usdtBorrowVault);
        console.log("  IRM:    %s", usdtIrm);
        console.log("  LTV:    75%% / 80%%");
        console.log("\nMarket 2 - Borrow BNB (collateral: USDT):");
        console.log("  Vault:  %s", bnbBorrowVault);
        console.log("  IRM:    %s", bnbIrm);
        console.log("  LTV:    88%% / 91%%");
        console.log("\nShared: MaxLiqDiscount=5%%, InterestFee=10%%");
        console.log("\nRun 07_SetFeeReceiver.s.sol next.");
    }
}
