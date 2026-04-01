// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployZROVault
/// @notice Step 4 of 7: Deploy the ZRO borrow vault.
///   The USDC borrow vault already exists (deployed by co-worker).
///
///   ZRO Borrow Vault: asset=ZRO, oracle=ZRO_EULER_ROUTER, unitOfAccount=USD
///
/// @dev Usage:
///   source .env
///   forge script script/04_DeployVaults.s.sol:DeployVaults \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: ZRO_BORROW_VAULT=<addr>
contract DeployVaults is Script {
    function run() external {
        address router = vm.envAddress("ZRO_EULER_ROUTER");

        vm.startBroadcast();

        address zroVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.ZRO, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("=== STEP 4 COMPLETE: ZRO Vault Deployed ===");
        console.log("ZRO Borrow Vault:  %s", zroVault);
        console.log("  asset:          ZRO (%s)", Addresses.ZRO);
        console.log("  oracle:         EulerRouter (%s)", router);
        console.log("  unitOfAccount:  USD");
        console.log("\nAdd to .env: ZRO_BORROW_VAULT=%s", zroVault);
        console.log("Run 05_WireOracle.s.sol next.");
    }
}
