// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployBorrowVault
/// @notice Step 4 of 7: Deploy the shared frxUSD borrow vault.
///   - asset = frxUSD
///   - oracle = EulerRouter (from step 2)
///   - unitOfAccount = frxUSD (debt pricing is trivial: base == quote)
///
/// @dev Usage:
///   source .env
///   forge script script/04_DeployBorrowVault.s.sol:DeployBorrowVault \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: FRXUSD_BORROW_VAULT=<address>
contract DeployBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address borrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.frxUSD, router, Addresses.frxUSD)
        );

        vm.stopBroadcast();

        console.log("=== STEP 4 COMPLETE: Borrow Vault Deployed ===");
        console.log("frxUSD Borrow Vault:", borrowVault);
        console.log("  asset:          frxUSD (%s)", Addresses.frxUSD);
        console.log("  oracle:         EulerRouter (%s)", router);
        console.log("  unitOfAccount:  frxUSD (self - trivial pricing)");
        console.log("\nAdd to .env: FRXUSD_BORROW_VAULT=%s", borrowVault);
        console.log("Run 05_DeployCollateralVaults.s.sol next.");
    }
}
