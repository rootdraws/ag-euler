// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVault {
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function governorAdmin() external view returns (address);
}

/// @title 06_WireWethVaultLTVs_SafeCalldata
/// @notice Step 6 of 6: Emit Safe calldata for the LTV additions the AG Safe
///         must apply on the existing WETH borrow vault.
///
/// @dev The existing WETH borrow vault is already governed by the AG Safe
///      (0x4f89...Fd3C, set by the Origin deploy's 08_RotateGovernance script).
///      To turn ETH↔USDC and ETH↔WBTC into real cross-margin pairs, the WETH
///      vault needs to accept eUSDC and eWBTC as collateral. This script does
///      NOT broadcast — it prints the (target, calldata) tuples the Safe
///      tx-builder consumes.
///
///      New LTVs on the WETH borrow vault:
///        accept USDC (eUSDC) as collateral: 85% / 88%
///        accept WBTC (eWBTC) as collateral: 80% / 83%
///
///      The existing ARM→WETH LTV (90/93) is untouched.
///
/// @dev Prerequisites (in .env):
///      WETH_BORROW_VAULT (existing), USDC_BORROW_VAULT, WBTC_BORROW_VAULT
///
/// @dev Run (read-only):
///      source .env && forge script script/06_WireWethVaultLTVs_SafeCalldata.s.sol \
///        --rpc-url $RPC_URL_MAINNET
contract WireWethVaultLTVs_SafeCalldata is Script {
    uint16 constant USDC_COLL_ON_WETH_BORROW_LTV = 0.85e4;
    uint16 constant USDC_COLL_ON_WETH_LIQ_LTV   = 0.88e4;

    uint16 constant WBTC_COLL_ON_WETH_BORROW_LTV = 0.80e4;
    uint16 constant WBTC_COLL_ON_WETH_LIQ_LTV   = 0.83e4;

    function run() external view {
        address wethVault = vm.envAddress("WETH_BORROW_VAULT");
        address usdcVault = vm.envAddress("USDC_BORROW_VAULT");
        address wbtcVault = vm.envAddress("WBTC_BORROW_VAULT");

        address currentGov = IEVault(wethVault).governorAdmin();
        require(currentGov == Addresses.AG_SAFE, "WETH vault governor != AG Safe; update Addresses.sol");

        bytes[] memory calls = new bytes[](2);
        string[] memory labels = new string[](2);

        calls[0] = abi.encodeCall(
            IEVault.setLTV,
            (usdcVault, USDC_COLL_ON_WETH_BORROW_LTV, USDC_COLL_ON_WETH_LIQ_LTV, 0)
        );
        labels[0] = "setLTV(USDC_VAULT, 85%, 88%, 0)";

        calls[1] = abi.encodeCall(
            IEVault.setLTV,
            (wbtcVault, WBTC_COLL_ON_WETH_BORROW_LTV, WBTC_COLL_ON_WETH_LIQ_LTV, 0)
        );
        labels[1] = "setLTV(WBTC_VAULT, 80%, 83%, 0)";

        console.log("\n=== STEP 6: Safe Calldata for Existing WETH Vault LTVs ===");
        console.log("Execute from AG Safe: %s", Addresses.AG_SAFE);
        console.log("Target (both calls):  %s (WETH Borrow Vault)", wethVault);
        console.log("");

        for (uint256 i = 0; i < calls.length; i++) {
            console.log("--- call #%s: %s ---", i + 1, labels[i]);
            console.log("  to:    %s", wethVault);
            console.log("  value: 0");
            console.log("  data:");
            console.logBytes(calls[i]);
            console.log("");
        }

        console.log("After Safe execution, the ETH/USDC/WBTC triad is fully cross-margined.");
        console.log("Final LTV matrix:");
        console.log("  WETH vault:   ARM 90/93 | USDC 85/88 | WBTC 80/83");
        console.log("  USDC vault:   WETH 85/88 | WBTC 80/83");
        console.log("  WBTC vault:   WETH 80/83 | USDC 80/83");
    }
}
