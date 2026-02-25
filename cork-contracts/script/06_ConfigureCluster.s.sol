// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IRMLinearKink} from "evk/InterestRateModels/IRMLinearKink.sol";

/// @title 06_ConfigureCluster
/// @notice Step 6 of 7: Deploy IRM and configure the sUSDe borrow vault cluster.
///
/// @dev Prerequisites (all must be set in .env):
///      SUSDE_BORROW_VAULT, VBUSDC_VAULT, CST_VAULT
///
/// @dev Configuration applied:
///      - IRMLinearKink: Base=0%, Kink(80%)=~4% APY, Max(100%)=~44% APY
///      - vbUSDC borrow LTV: 80%, liquidation LTV: 85%
///      - cST borrow LTV: 0%, liquidation LTV: 0% (zero-priced oracle)
///      - Max liquidation discount: 15%
///      - Liquidation cool-off: 1 second
///      - Supply/borrow caps: unlimited (AmountCap=0 → type(uint256).max) — tighten before full launch
///      - Interest fee: vault default (ProtocolConfig minimum 0.1e4 = 10%)
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev No addresses to capture. Run 07_DeployLiquidator.s.sol next.
///      setFeeReceiver is called here — fees accrue to reservoirDAO address.
contract ConfigureCluster is Script {
    address constant FEE_RECEIVER = 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C; // reservoirDAO Address

    // LTVs in Euler 1e4 scale (0.80e4 = 80%)
    uint16 constant vbUSDC_BORROW_LTV         = 0.80e4;
    uint16 constant vbUSDC_LLTV               = 0.85e4;
    uint16 constant cST_BORROW_LTV            = 0;
    uint16 constant cST_LLTV                  = 0;
    uint16 constant MAX_LIQUIDATION_DISCOUNT  = 0.15e4;

    // IRM: Base=0%, Kink(80%)=~4% APY, Max(100%)=~44% APY
    // Computed via: node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 4 44 80
    uint256 constant IRM_BASE_RATE = 0;
    uint256 constant IRM_SLOPE1    = 361_718_388;
    uint256 constant IRM_SLOPE2    = 12_005_010_303;
    uint32  constant IRM_KINK      = 3_435_973_836;

    function run() external {
        address sUSDeBorrowVault = vm.envAddress("SUSDE_BORROW_VAULT");
        address vbUSDCVault      = vm.envAddress("VBUSDC_VAULT");
        address cSTVault         = vm.envAddress("CST_VAULT");

        vm.startBroadcast();

        IRMLinearKink irm = new IRMLinearKink(IRM_BASE_RATE, IRM_SLOPE1, IRM_SLOPE2, IRM_KINK);

        IEVault bv = IEVault(sUSDeBorrowVault);

        bv.setInterestRateModel(address(irm));
        bv.setMaxLiquidationDiscount(MAX_LIQUIDATION_DISCOUNT);
        bv.setLiquidationCoolOffTime(1);
        bv.setLTV(vbUSDCVault, vbUSDC_BORROW_LTV, vbUSDC_LLTV, 0);
        bv.setLTV(cSTVault, cST_BORROW_LTV, cST_LLTV, 0);
        // AmountCap 0 = no cap (unlimited) in Euler's encoding
        bv.setCaps(0, 0);
        // Note: setInterestFee(0) rejected by ProtocolConfig — using vault default fee
        bv.setFeeReceiver(FEE_RECEIVER);

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("IRMLinearKink deployed: %s", address(irm));
        console.log("setInterestRateModel(irm)");
        console.log("setMaxLiquidationDiscount(15%%)");
        console.log("setLiquidationCoolOffTime(1)");
        console.log("setLTV(vbUSDCVault, 80%% borrow, 85%% liquidation)");
        console.log("setLTV(cSTVault, 0%%, 0%%)");
        console.log("setCaps(unlimited) -- tighten before full launch");
        console.log("interestFee: using vault default (ProtocolConfig minimum)");
        console.log("setFeeReceiver: %s", FEE_RECEIVER);
        console.log("\nRun 07_DeployLiquidator.s.sol next.");
    }
}
