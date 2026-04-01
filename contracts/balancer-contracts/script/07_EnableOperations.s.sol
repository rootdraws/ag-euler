// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setHookConfig(address hookTarget, uint32 hookedOps) external;
    function hookConfig() external view returns (address hookTarget, uint32 hookedOps);
    function governorAdmin() external view returns (address);
}

/// @title 07_EnableOperations
/// @notice Step 7: Clears the disabled-operations flag on all 6 vaults.
///
/// @dev The Monad EVault factory initializes vaults with hookedOps=32767
///      (all ops disabled) and hookTarget=address(0). This must be called
///      AFTER 06_ConfigureCluster to enable deposit/borrow/withdraw/etc.
///
/// @dev IMPORTANT: forge script --broadcast fails on Monad due to gas estimation
///      and nonce issues with batched transactions. Use cast send instead:
///
///      source .env
///      for VAULT in $AUSD_BORROW_VAULT $WMON_BORROW_VAULT \
///                    $POOL1_VAULT $POOL2_VAULT $POOL3_VAULT $POOL4_VAULT; do
///        cast send $VAULT "setHookConfig(address,uint32)" \
///          "0x0000000000000000000000000000000000000000" 0 \
///          --private-key $PRIVATE_KEY --rpc-url $RPC_URL_MONAD
///      done
///
/// @dev Verify with:
///      cast call $VAULT "hookConfig()(address,uint32)" --rpc-url $RPC_URL_MONAD
///      # Should return address(0) and 0
contract EnableOperations is Script {
    function run() external {
        address ausdBorrowVault = vm.envAddress("AUSD_BORROW_VAULT");
        address wmonBorrowVault = vm.envAddress("WMON_BORROW_VAULT");
        address pool1Vault      = vm.envAddress("POOL1_VAULT");
        address pool2Vault      = vm.envAddress("POOL2_VAULT");
        address pool3Vault      = vm.envAddress("POOL3_VAULT");
        address pool4Vault      = vm.envAddress("POOL4_VAULT");

        address[6] memory vaults = [
            ausdBorrowVault, wmonBorrowVault,
            pool1Vault, pool2Vault, pool3Vault, pool4Vault
        ];

        string[6] memory names = [
            "AUSD Borrow", "WMON Borrow",
            "Pool1 Collateral", "Pool2 Collateral", "Pool3 Collateral", "Pool4 Collateral"
        ];

        vm.startBroadcast();

        for (uint256 i = 0; i < vaults.length; i++) {
            IEVault v = IEVault(vaults[i]);

            (address hookTarget, uint32 hookedOps) = v.hookConfig();
            if (hookTarget == address(0) && hookedOps != 0) {
                v.setHookConfig(address(0), 0);
                console.log("Enabled ops on %s: %s", names[i], vaults[i]);
            } else {
                console.log("Already OK   %s: %s (hookedOps=%s)", names[i], vaults[i], hookedOps);
            }
        }

        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: All operations enabled ===");
    }
}
