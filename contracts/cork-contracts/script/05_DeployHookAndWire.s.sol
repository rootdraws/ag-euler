// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {ProtectedLoopHook} from "../src/hook/ProtectedLoopHook.sol";
import {ERC4626EVCCollateralCork} from "../src/vault/ERC4626EVCCollateralCork.sol";

/// @title 05_DeployHookAndWire
/// @notice Step 5 of 7: Deploy ProtectedLoopHook, attach it to the borrow vault,
///         and wire both collateral vault pairing references.
///
/// @dev Prerequisites (all must be set in .env):
///      VBUSDC_VAULT, CST_VAULT, SUSDE_BORROW_VAULT
///
/// @dev What this does:
///      1. Deploys ProtectedLoopHook with all vault addresses + cST expiry.
///      2. sUSDeBorrowVault.setHookConfig(hook, OP_BORROW=64) — gates borrows.
///      3. vbUSDCVault.setPairedVault(cSTVault) — REF vault knows its cST counterpart.
///      4. cSTVault.setPairedVault(vbUSDCVault) — cST vault knows its REF counterpart.
///
/// @dev Run:
///      source .env && forge script script/05_DeployHookAndWire.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste PROTECTED_LOOP_HOOK=<address> into .env,
///      then run 06_ConfigureCluster.s.sol
contract DeployHookAndWire is Script {
    // Euler Infrastructure
    address constant EVC           = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant eVaultFactory = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;

    // cST token address and expiry
    address constant cST       = 0x1B42544F897B7Ab236C111A4f800A54D94840688;
    uint256 constant cstExpiry = 1776686400; // April 19, 2026

    // OP_BORROW = 64 (from EVault Constants.sol)
    uint32 constant OP_BORROW = 64;

    function run() external {
        address vbUSDCVault      = vm.envAddress("VBUSDC_VAULT");
        address cSTVault         = vm.envAddress("CST_VAULT");
        address sUSDeBorrowVault = vm.envAddress("SUSDE_BORROW_VAULT");

        vm.startBroadcast();

        // Deploy ProtectedLoopHook. Gates borrows on the sUSDe vault.
        ProtectedLoopHook hook = new ProtectedLoopHook(
            eVaultFactory,
            EVC,
            vbUSDCVault,
            cSTVault,
            sUSDeBorrowVault,
            cST,
            cstExpiry
        );

        // Attach hook to sUSDe borrow vault for OP_BORROW only.
        IEVault(sUSDeBorrowVault).setHookConfig(address(hook), OP_BORROW);

        // Wire paired vault references for withdraw/deposit pairing enforcement.
        ERC4626EVCCollateralCork(vbUSDCVault).setPairedVault(cSTVault);
        ERC4626EVCCollateralCork(cSTVault).setPairedVault(vbUSDCVault);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Hook Deployed and Wired ===");
        console.log("PROTECTED_LOOP_HOOK=%s", address(hook));
        console.log("sUSDeBorrowVault.setHookConfig(hook, OP_BORROW=64)");
        console.log("vbUSDCVault.setPairedVault(cSTVault)");
        console.log("cSTVault.setPairedVault(vbUSDCVault)");
        console.log("\nPaste PROTECTED_LOOP_HOOK into .env, then run 06_ConfigureCluster.s.sol");
    }
}
