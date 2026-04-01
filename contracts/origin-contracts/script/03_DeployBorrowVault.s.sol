// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployBorrowVault
/// @notice Step 3 of 6: Deploy the WETH borrow vault.
///
/// @dev Unit of account = WETH. Since the borrow asset IS WETH, oracle resolution for
///      ARM collateral terminates at WETH identity — no Chainlink USD feed needed.
///
///      trailingData = abi.encodePacked(asset, oracle, unitOfAccount) = 60 bytes.
///      Factory prepends bytes4(0) → 64 bytes (PROXY_METADATA_LENGTH).
///
/// @dev Prerequisites (must be set in .env):
///      EULER_ROUTER
///
/// @dev Run:
///      source .env && forge script script/03_DeployBorrowVault.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste WETH_BORROW_VAULT=<address> into .env,
///      then run 04_DeployCollateralVault.s.sol
contract DeployBorrowVault is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address wethBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WETH, router, Addresses.WETH)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: WETH Borrow Vault ===");
        console.log("WETH_BORROW_VAULT=%s", wethBorrowVault);
        console.log("\nPaste into .env, then run 04_DeployCollateralVault.s.sol");
    }
}
