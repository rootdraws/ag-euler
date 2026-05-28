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
    function setHookConfig(address hookTarget, uint32 hookedOps) external;
    function governorAdmin() external view returns (address);
}

/// @title 05_ConfigureCluster
/// @notice Step 5 of 6: Activate the new USDC + WBTC vaults, set risk params,
///         and wire in-cluster LTVs (only the cross-LTVs owned by the new vaults).
///
/// @dev The USDC and WBTC vaults' governor is still the deployer (per user choice to
///      keep control), so this script broadcasts from the deployer EOA.
///
///      LTV matrix this script writes (setLTV calls on the NEW vaults):
///        USDC vault accepts WETH (eWETH):   85% / 88%
///        USDC vault accepts WBTC (eWBTC):   80% / 83%
///        WBTC vault accepts WETH (eWETH):   80% / 83%
///        WBTC vault accepts USDC (eUSDC):   80% / 83%
///
///      The converse direction (existing WETH borrow vault accepting USDC/WBTC)
///      is governor-gated on the AG Safe — emitted as Safe calldata by script 06.
///
/// @dev AmountCap encoding (see AmountCapLib.resolve in euler-vault-kit):
///        raw = (mantissa << 6) | exp    (upper 10 bits mantissa, lower 6 bits exp)
///        resolved_wei = mantissa * 10^exp / 100    (mantissa is pre-scaled by 100)
///
///        50,000 USDC (6 dec):  5e10 wei  → (500 << 6) | 10 = 32010
///        0.5 WBTC    (8 dec):  5e7  wei  → (500 << 6) | 7  = 32007
///
///      These are low bring-up caps. To reach 5M USDC / 50 WBTC use (500<<6)|12
///      (32012) and (500<<6)|9 (32009) respectively — see 07_RaiseCaps.s.sol.
///
/// @dev Prerequisites (in .env):
///      USDC_IRM, WBTC_IRM,
///      USDC_BORROW_VAULT, WBTC_BORROW_VAULT,
///      WETH_BORROW_VAULT   (existing, used only as a setLTV target address)
///      FEE_RECEIVER        (optional — typically the AG curator fee address)
///
/// @dev Run:
///      source .env && forge script script/05_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_MAINNET --account dev --sender $DEPLOYER --broadcast
contract ConfigureCluster is Script {
    // ─── Cross-margin LTVs (borrowLTV / liquidationLTV) ───
    uint16 constant WETH_COLL_ON_USDC_BORROW_LTV = 0.85e4;
    uint16 constant WETH_COLL_ON_USDC_LIQ_LTV   = 0.88e4;

    uint16 constant WETH_COLL_ON_WBTC_BORROW_LTV = 0.80e4;
    uint16 constant WETH_COLL_ON_WBTC_LIQ_LTV   = 0.83e4;

    uint16 constant WBTC_COLL_ON_USDC_BORROW_LTV = 0.80e4;
    uint16 constant WBTC_COLL_ON_USDC_LIQ_LTV   = 0.83e4;

    uint16 constant USDC_COLL_ON_WBTC_BORROW_LTV = 0.80e4;
    uint16 constant USDC_COLL_ON_WBTC_LIQ_LTV   = 0.83e4;

    // ─── Caps (AmountCap encoded) ───
    uint16 constant USDC_CAP = 32010; // 50,000 USDC (6 dec) — bring-up cap
    uint16 constant WBTC_CAP = 32007; // 0.5 WBTC    (8 dec) — ~$50k bring-up cap

    // ─── Shared params ───
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;      // 1 second
    uint16 constant INTEREST_FEE      = 0.10e4; // 10%

    function run() external {
        address usdcIrm        = vm.envAddress("USDC_IRM");
        address wbtcIrm        = vm.envAddress("WBTC_IRM");
        address usdcVault      = vm.envAddress("USDC_BORROW_VAULT");
        address wbtcVault      = vm.envAddress("WBTC_BORROW_VAULT");
        address wethVault      = vm.envAddress("WETH_BORROW_VAULT");

        // Sanity: deployer must still be governor on the NEW vaults.
        address deployer = msg.sender;
        require(IEVault(usdcVault).governorAdmin() == deployer, "USDC vault not governed by deployer");
        require(IEVault(wbtcVault).governorAdmin() == deployer, "WBTC vault not governed by deployer");

        vm.startBroadcast();

        // ── Activate: clear factory-default hookedOps=32767 ──
        IEVault(usdcVault).setHookConfig(address(0), 0);
        IEVault(wbtcVault).setHookConfig(address(0), 0);

        // ── USDC borrow vault ──
        IEVault usdc = IEVault(usdcVault);
        usdc.setInterestRateModel(usdcIrm);
        usdc.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        usdc.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        usdc.setInterestFee(INTEREST_FEE);
        usdc.setCaps(USDC_CAP, USDC_CAP);
        usdc.setLTV(wethVault,  WETH_COLL_ON_USDC_BORROW_LTV, WETH_COLL_ON_USDC_LIQ_LTV, 0);
        usdc.setLTV(wbtcVault,  WBTC_COLL_ON_USDC_BORROW_LTV, WBTC_COLL_ON_USDC_LIQ_LTV, 0);

        // ── WBTC borrow vault ──
        IEVault wbtc = IEVault(wbtcVault);
        wbtc.setInterestRateModel(wbtcIrm);
        wbtc.setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        wbtc.setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        wbtc.setInterestFee(INTEREST_FEE);
        wbtc.setCaps(WBTC_CAP, WBTC_CAP);
        wbtc.setLTV(wethVault,  WETH_COLL_ON_WBTC_BORROW_LTV, WETH_COLL_ON_WBTC_LIQ_LTV, 0);
        wbtc.setLTV(usdcVault,  USDC_COLL_ON_WBTC_BORROW_LTV, USDC_COLL_ON_WBTC_LIQ_LTV, 0);

        // ── Optional fee receiver ──
        try vm.envAddress("FEE_RECEIVER") returns (address feeReceiver) {
            if (feeReceiver != address(0)) {
                usdc.setFeeReceiver(feeReceiver);
                wbtc.setFeeReceiver(feeReceiver);
                console.log("Fee receiver set on both vaults: %s", feeReceiver);
            }
        } catch {}

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Cluster Configured ===");
        console.log("USDC vault: %s", usdcVault);
        console.log("  IRM:             %s", usdcIrm);
        console.log("  LTV[WETH coll]:  85%% / 88%%");
        console.log("  LTV[WBTC coll]:  80%% / 83%%");
        console.log("  Cap (supply/borrow): 5,000,000 USDC");
        console.log("\nWBTC vault: %s", wbtcVault);
        console.log("  IRM:             %s", wbtcIrm);
        console.log("  LTV[WETH coll]:  80%% / 83%%");
        console.log("  LTV[USDC coll]:  80%% / 83%%");
        console.log("  Cap (supply/borrow): 50 WBTC (~$3M)");
        console.log("\nShared: MaxLiqDiscount=5%%, InterestFee=10%%");
        console.log("\nNext: run 06_WireWethVaultLTVs_SafeCalldata.s.sol to emit Safe calldata");
        console.log("for the existing WETH vault LTV additions.");
    }
}
