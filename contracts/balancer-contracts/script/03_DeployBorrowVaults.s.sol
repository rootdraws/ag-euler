// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

/// @title 03_DeployBorrowVaults
/// @notice Step 3 of 6: Deploy AUSD and WMON borrow vaults.
///
/// @dev Prerequisites (must be set in .env):
///      EULER_ROUTER
///
/// @dev trailingData = abi.encodePacked(asset, oracle, unitOfAccount) — 60 bytes.
///      Factory prepends bytes4(0) making it 64 bytes (PROXY_METADATA_LENGTH).
///
/// @dev Run:
///      source .env && forge script script/03_DeployBorrowVaults.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY --broadcast
///
/// @dev After running: paste AUSD_BORROW_VAULT and WMON_BORROW_VAULT into .env,
///      then run 04_DeployCollateralVaults.s.sol
contract DeployBorrowVaults is Script {
    address constant EVAULT_FACTORY = 0xba4Dd672062dE8FeeDb665DD4410658864483f1E;
    address constant AUSD           = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant WMON           = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    function run() external {
        address router = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        address ausdBorrowVault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(AUSD, router, AUSD)
        );

        address wmonBorrowVault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0),
            true,
            abi.encodePacked(WMON, router, WMON)
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: Borrow Vaults ===");
        console.log("AUSD_BORROW_VAULT=%s", ausdBorrowVault);
        console.log("WMON_BORROW_VAULT=%s", wmonBorrowVault);
        console.log("\nPaste both into .env, then run 04_DeployCollateralVaults.s.sol");
    }
}
