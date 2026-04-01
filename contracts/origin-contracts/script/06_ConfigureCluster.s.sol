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
    function setFeeReceiver(address receiver) external;
}

/// @title 06_ConfigureCluster
/// @notice Step 6 of 6: Configure IRM, risk parameters, and LTVs on the WETH borrow vault.
///
/// @dev Parameters:
///      Borrow LTV        = 90% (9000 bps)  — ARM/WETH tightly correlated
///      Liquidation LTV   = 93% (9300 bps)  — 3% buffer
///      Max liq discount   = 5%  (500 bps)
///      Liq cool-off       = 1 second
///      Interest fee       = 10% (1000 bps)  — protocol revenue share
///      Supply cap (ARM)   = ~$2M initial    — encoded as AmountCap
///      Borrow cap (WETH)  = uncapped start  — tighten after launch
///
/// @dev setCaps encoding: Euler uses a compressed uint16 format (AmountCap) where
///      the value is (mantissa * 10^exponent). 0 = uncapped. See EVault docs for
///      the exact encoding. For initial deployment we leave caps at 0 (uncapped)
///      and tighten post-launch via a separate governance call.
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM, WETH_BORROW_VAULT, ARM_COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY --broadcast
///
/// @dev No new addresses. Deployment complete after this step.
contract ConfigureCluster is Script {
    uint16 constant BORROW_LTV        = 0.90e4; // 9000 bps
    uint16 constant LIQUIDATION_LTV   = 0.93e4; // 9300 bps
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;
    uint16 constant INTEREST_FEE      = 0.10e4; // 10%

    function run() external {
        address irm              = vm.envAddress("KINK_IRM");
        address wethBorrowVault  = vm.envAddress("WETH_BORROW_VAULT");
        address armCollVault     = vm.envAddress("ARM_COLLATERAL_VAULT");

        vm.startBroadcast();

        IEVault borrow = IEVault(wethBorrowVault);

        borrow.setInterestRateModel(irm);
        borrow.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        borrow.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        borrow.setInterestFee(INTEREST_FEE);
        borrow.setCaps(0, 0); // uncapped initially — tighten post-launch
        borrow.setLTV(armCollVault, BORROW_LTV, LIQUIDATION_LTV, 0);

        // Optional: set fee receiver if env var is provided
        try vm.envAddress("FEE_RECEIVER") returns (address feeReceiver) {
            if (feeReceiver != address(0)) {
                borrow.setFeeReceiver(feeReceiver);
                console.log("Fee receiver set to %s", feeReceiver);
            }
        } catch {}

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("WETH borrow vault: %s", wethBorrowVault);
        console.log("  IRM:              %s", irm);
        console.log("  Borrow LTV:       90%%");
        console.log("  Liquidation LTV:  93%%");
        console.log("  Max liq discount: 5%%");
        console.log("  Interest fee:     10%%");
        console.log("  Collateral:       %s (ARM-WETH-stETH)", armCollVault);
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Next steps:");
        console.log("  1. Add vault addresses to origin-labels repo products.json");
        console.log("  2. Configure ARM_ADAPTER_CONFIG in euler-lite-origin .env");
        console.log("  3. Origin deploys EulerSwap pool via Maglev");
        console.log("  4. Tighten supply/borrow caps via setCaps()");
    }
}
