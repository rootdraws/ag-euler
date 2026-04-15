// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployBorrowVaults
/// @notice Step 3 of 7: Deploy USDT + BNB borrow vaults.
///
/// @dev Both vaults share the router deployed in step 2.
///      Unit of account = USD (address(840)) — both sides have Chainlink USD feeds.
///
///      trailingData = abi.encodePacked(asset, router, USD)
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env
///
/// @dev Run:
///      source .env && forge script script/03_DeployBorrowVaults.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
///
/// @dev After running: paste USDT_BORROW_VAULT and BNB_BORROW_VAULT into .env
contract DeployBorrowVaults is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address usdtBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDT, router, Addresses.USD)
        );

        address bnbBorrowVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WBNB, router, Addresses.USD)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: Borrow Vaults ===");
        console.log("USDT_BORROW_VAULT=%s", usdtBorrowVault);
        console.log("BNB_BORROW_VAULT=%s",  bnbBorrowVault);
        console.log("\nPaste into .env, then run 04_DeployCollateralVaults.s.sol");
    }
}
