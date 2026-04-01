// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 05_DeployCollateralVaults
/// @notice Step 5 of 7: Deploy 5 collateral vaults (one per ICHI vault).
///   Collateral vaults use oracle=address(0), unitOfAccount=address(0).
///   Pricing happens through the borrow vault's EulerRouter.
///
/// @dev Usage:
///   source .env
///   forge script script/05_DeployCollateralVaults.s.sol:DeployCollateralVaults \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env:
///     COLLATERAL_VAULT_BRZ=<addr>  COLLATERAL_VAULT_TGBP=<addr>
///     COLLATERAL_VAULT_USDC=<addr> COLLATERAL_VAULT_IDRX=<addr>
///     COLLATERAL_VAULT_KRWQ=<addr>
contract DeployCollateralVaults is Script {
    function run() external {
        vm.startBroadcast();

        address cvBrz  = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.ICHI_BRZ, address(0), address(0))
        );
        address cvTgbp = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.ICHI_TGBP, address(0), address(0))
        );
        address cvUsdc = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.ICHI_USDC, address(0), address(0))
        );
        address cvIdrx = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.ICHI_IDRX, address(0), address(0))
        );
        address cvKrwq = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.ICHI_KRWQ, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("=== STEP 5 COMPLETE: Collateral Vaults Deployed ===");
        console.log("COLLATERAL_VAULT_BRZ:  %s  (frxUSD/BRZ ICHI)", cvBrz);
        console.log("COLLATERAL_VAULT_TGBP: %s  (tGBP/frxUSD ICHI)", cvTgbp);
        console.log("COLLATERAL_VAULT_USDC: %s  (USDC/frxUSD ICHI)", cvUsdc);
        console.log("COLLATERAL_VAULT_IDRX: %s  (IDRX/frxUSD ICHI)", cvIdrx);
        console.log("COLLATERAL_VAULT_KRWQ: %s  (KRWQ/frxUSD ICHI)", cvKrwq);
        console.log("\nRun 06_WireRouter.s.sol next.");
    }
}
