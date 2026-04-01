// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployCollateralVaults
/// @notice Step 4 of 6: Deploy 4 BPT collateral vaults (one per Balancer pool).
///
/// @dev No prerequisites. These are standard EVault proxies with the BPT as the underlying asset.
///      Oracle and LTV are configured on the BORROW vault (steps 5-6), not here.
///
/// @dev Pools:
///      Pool 1 - wnAUSD/wnUSDC/wnUSDT0  -> AUSD borrow
///      Pool 2 - Kintsu sMON/wnWMON     -> WMON borrow
///      Pool 3 - Fastlane shMON/wnWMON  -> WMON borrow
///      Pool 4 - wnLOAZND/AZND/wnAUSD   -> AUSD borrow
///
/// @dev Run:
///      source .env && forge script script/04_DeployCollateralVaults.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --verify
///
/// @dev After running: paste POOL1_VAULT, POOL2_VAULT, POOL3_VAULT, POOL4_VAULT into .env,
///      then run 05_DeployOracles.s.sol
contract DeployCollateralVaults is Script {
    address constant EVAULT_FACTORY = 0xba4Dd672062dE8FeeDb665DD4410658864483f1E;

    // BPT token addresses (pool address = BPT on Balancer v3)
    address constant POOL1_BPT = 0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b; // wnAUSD/wnUSDC/wnUSDT0
    address constant POOL2_BPT = 0x3475Ea1c3451a9a10Aeb51bd8836312175B88BAc; // Kintsu sMON/wnWMON
    address constant POOL3_BPT = 0x150360c0eFd098A6426060Ee0Cc4a0444c4b4b68; // Fastlane shMON/wnWMON
    address constant POOL4_BPT = 0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3; // wnLOAZND/AZND/wnAUSD

    function run() external {
        vm.startBroadcast();

        // Collateral vaults: asset=BPT, oracle=address(0), unitOfAccount=address(0).
        // Factory requires exactly 60 bytes of trailingData (prepends bytes4(0) → 64 = PROXY_METADATA_LENGTH).
        // Oracle/UoA on collateral vaults are unused — pricing happens via the borrow vault's EulerRouter.
        address pool1Vault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(POOL1_BPT, address(0), address(0))
        );
        address pool2Vault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(POOL2_BPT, address(0), address(0))
        );
        address pool3Vault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(POOL3_BPT, address(0), address(0))
        );
        address pool4Vault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(POOL4_BPT, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: Collateral Vaults ===");
        console.log("POOL1_VAULT=%s  (wnAUSD/wnUSDC/wnUSDT0)", pool1Vault);
        console.log("POOL2_VAULT=%s  (sMON/wnWMON)", pool2Vault);
        console.log("POOL3_VAULT=%s  (shMON/wnWMON)", pool3Vault);
        console.log("POOL4_VAULT=%s  (wnLOAZND/AZND/wnAUSD)", pool4Vault);
        console.log("\nPaste all four into .env, then run 05_DeployOracles.s.sol");
    }
}
