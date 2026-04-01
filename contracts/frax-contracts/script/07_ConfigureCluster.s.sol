// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setInterestRateModel(address irm) external;
    function setMaxLiquidationDiscount(uint16 discount) external;
    function setLiquidationCoolOffTime(uint16 coolOffTime) external;
    function setCaps(uint16 supplyCap, uint16 borrowCap) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
}

/// @title 07_ConfigureCluster
/// @notice Step 7 of 7: Configure the frxUSD borrow vault cluster.
///   - Set IRM
///   - Set uniform 95%/97% LTVs for all 5 collateral vaults
///   - Set 3% max liquidation discount (treasury-internal liquidations)
///   - Caps unlimited (tighten later)
///   - Fee receiver: set later via setFeeReceiver()
///
/// @dev Usage:
///   source .env
///   forge script script/07_ConfigureCluster.s.sol:ConfigureCluster \
///     --rpc-url base --broadcast -vvvv
contract ConfigureCluster is Script {
    // 95% borrow LTV, 97% liquidation LTV — uniform across all vaults
    // Single-sided frxUSD collateral borrowing frxUSD. Treasury handles liquidations.
    uint16 constant BORROW_LTV = 9500;  // 95.00%
    uint16 constant LIQ_LTV   = 9700;  // 97.00%

    uint16 constant MAX_LIQ_DISCOUNT = 300;  // 3%
    uint16 constant LIQ_COOL_OFF     = 1;    // 1 second

    function run() external {
        address irm              = vm.envAddress("KINK_IRM");
        address borrowVault      = vm.envAddress("FRXUSD_BORROW_VAULT");
        address cvBrz            = vm.envAddress("COLLATERAL_VAULT_BRZ");
        address cvTgbp           = vm.envAddress("COLLATERAL_VAULT_TGBP");
        address cvUsdc           = vm.envAddress("COLLATERAL_VAULT_USDC");
        address cvIdrx           = vm.envAddress("COLLATERAL_VAULT_IDRX");
        address cvKrwq           = vm.envAddress("COLLATERAL_VAULT_KRWQ");

        vm.startBroadcast();

        IEVault bv = IEVault(borrowVault);

        bv.setInterestRateModel(irm);
        bv.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        bv.setLiquidationCoolOffTime(LIQ_COOL_OFF);

        bv.setLTV(cvBrz,  BORROW_LTV, LIQ_LTV, 0);
        bv.setLTV(cvTgbp, BORROW_LTV, LIQ_LTV, 0);
        bv.setLTV(cvUsdc, BORROW_LTV, LIQ_LTV, 0);
        bv.setLTV(cvIdrx, BORROW_LTV, LIQ_LTV, 0);
        bv.setLTV(cvKrwq, BORROW_LTV, LIQ_LTV, 0);

        bv.setCaps(0, 0);

        vm.stopBroadcast();

        console.log("=== STEP 7 COMPLETE: Cluster Configured ===");
        console.log("Borrow vault: %s", borrowVault);
        console.log("  IRM:               %s", irm);
        console.log("  Borrow LTV:        95%%");
        console.log("  Liquidation LTV:   97%%");
        console.log("  Max Liq Discount:  3%%");
        console.log("  Caps:              unlimited (tighten before production)");
        console.log("  Fee Receiver:      NOT SET (call setFeeReceiver later)");
        console.log("\nDeployment complete! Post-deploy:");
        console.log("  1. Seed OraclePoke with dust tokens");
        console.log("  2. Start keeper.ts cron");
        console.log("  3. Set fee receiver");
        console.log("  4. Configure labels repo");
    }
}
