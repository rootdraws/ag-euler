// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 04_DeployCollateralVault
/// @notice Step 4 of 7: Deploy the agVVVWETHlp collateral vault.
///
/// @dev The EVK treats agVVVWETHlp as a generic ERC-20 — it does not call any
///      ERC-7540 async deposit/redeem paths. Users move shares in/out of this
///      EVault with standard ERC-4626 deposit/withdraw; the underlying ERC-7540
///      semantics only matter when a user wants to convert back to LP.
///
///      Collateral vaults set oracle=address(0) and unitOfAccount=address(0).
///      Pricing happens on the borrow vault side via the EulerRouter.
///
/// @dev Run:
///      source .env && forge script script/04_DeployCollateralVault.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste COLLATERAL_VAULT=<address> into .env, then run 05_WireOracle.s.sol
contract DeployCollateralVault is Script {
    function run() external {
        vm.startBroadcast();

        address collVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.AG_VVV_WETH_LP, address(0), address(0))
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: agVVVWETHlp Collateral Vault ===");
        console.log("COLLATERAL_VAULT=%s", collVault);
        console.log("  asset: %s (agVVVWETHlp)", Addresses.AG_VVV_WETH_LP);
        console.log("\nPaste into .env, then run 05_WireOracle.s.sol");
    }
}
