// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployVaults
/// @notice Step 3 of 6: Deploy the USDC and WBTC borrow vaults.
///
/// @dev Unit of account = WETH (cluster convention from the existing Origin market).
///      Both vaults serve dual duty: lenders earn yield AND depositors can use
///      their eShares as collateral for borrowing other cluster assets.
///
///      Oracle pricing (wired in script 04) composes through USD:
///        eUSDC → USDC → USDC/USD → ETH/USD → WETH
///        eWBTC → WBTC →  BTC/USD → ETH/USD → WETH
///
/// @dev Prerequisites (in .env): EULER_ROUTER (shared with the Origin ARM deploy)
///
/// @dev Run:
///      source .env && forge script script/03_DeployVaults.s.sol \
///        --rpc-url $RPC_URL_MAINNET --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running, paste into .env:
///      USDC_BORROW_VAULT=<address>
///      WBTC_BORROW_VAULT=<address>
contract DeployVaults is Script {
    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address usdcVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.USDC, router, Addresses.WETH)
        );

        address wbtcVault = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(Addresses.WBTC, router, Addresses.WETH)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: USDC + WBTC Borrow Vaults ===");
        console.log("USDC_BORROW_VAULT=%s", usdcVault);
        console.log("WBTC_BORROW_VAULT=%s", wbtcVault);
        console.log("\nPaste into .env, then run 04_WireOracle_SafeCalldata.s.sol");
    }
}
