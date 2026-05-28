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
/// @notice Step 6 of 7: Activate vaults and configure all risk parameters.
///
/// @dev Activation: factory proxies ship with hookedOps=32767 (ALL ops disabled).
///      setHookConfig(address(0), 0) on every vault to unblock deposit / withdraw /
///      borrow / repay / liquidate.
///
/// @dev Risk parameters (T0 canary, from spec):
///        Borrow LTV       = 60% (6000 bps)
///        Liquidation LTV  = 70% (7000 bps)
///        Max liq discount = 5%  (500 bps)   — modest, oracle pile is in VVV
///        Liq cool-off     = 1 second
///        Interest fee     = 10% (1000 bps)
///
///      Caps (AmountCap = (mantissa << 6) | exp, resolves to 10^exp * mantissa / 100):
///        USDC supply cap  = 25,000 USDC (6 dec)  → mantissa=25, exp=11 → 1611
///        USDC borrow cap  = 15,000 USDC (6 dec)  → mantissa=15, exp=11 → 971
///        Coll supply cap  = 60 agVVVWETHlp shares (18 dec) → mantissa=60, exp=20 → 3860
///        Coll borrow cap  = 0 (uncapped — nobody should borrow agVVVWETHlp, no IRM set anyway)
///
/// @dev Prerequisites (in .env):
///      KINK_IRM, USDC_BORROW_VAULT, COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract ConfigureCluster is Script {
    uint16 constant BORROW_LTV        = 0.60e4; // 60%
    uint16 constant LIQUIDATION_LTV   = 0.70e4; // 70%
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;       // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4;  // 10%

    // AmountCap encoding — see header comment
    uint16 constant USDC_SUPPLY_CAP = 1611; // 25,000 USDC
    uint16 constant USDC_BORROW_CAP = 971;  // 15,000 USDC
    uint16 constant COLL_SUPPLY_CAP = 3860; // 60 agVVVWETHlp shares
    uint16 constant COLL_BORROW_CAP = 0;    // uncapped (no IRM → unborrowable anyway)

    function run() external {
        address irm             = vm.envAddress("KINK_IRM");
        address usdcBorrowVault = vm.envAddress("USDC_BORROW_VAULT");
        address collVault       = vm.envAddress("COLLATERAL_VAULT");

        vm.startBroadcast();

        // ── Activate both vaults (clear factory-default hookedOps=32767) ──
        IEVault(usdcBorrowVault).setHookConfig(address(0), 0);
        IEVault(collVault).setHookConfig(address(0), 0);

        // ── USDC borrow vault ──
        IEVault borrow = IEVault(usdcBorrowVault);
        borrow.setInterestRateModel(irm);
        borrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        borrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        borrow.setInterestFee(INTEREST_FEE);
        borrow.setCaps(USDC_SUPPLY_CAP, USDC_BORROW_CAP);
        borrow.setLTV(collVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // ── Collateral vault — just a cap, no IRM/LTV ──
        IEVault(collVault).setCaps(COLL_SUPPLY_CAP, COLL_BORROW_CAP);

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("USDC Borrow Vault:    %s", usdcBorrowVault);
        console.log("  IRM:                %s", irm);
        console.log("  Borrow LTV:         60%%");
        console.log("  Liquidation LTV:    70%%");
        console.log("  Max liq discount:   5%%");
        console.log("  Interest fee:       10%%");
        console.log("  Supply cap:         25,000 USDC");
        console.log("  Borrow cap:         15,000 USDC");
        console.log("agVVVWETHlp Coll:     %s", collVault);
        console.log("  Supply cap:         60 shares (~$25k notional)");
        console.log("\nRun 07_SetFeeReceiver.s.sol next (optional).");
    }
}
