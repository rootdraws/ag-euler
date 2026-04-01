// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
}

/// @title 11_SetFeeReceiver
/// @notice Set the fee receiver on both borrow vaults to the AG address.
///
/// @dev Run:
///      source .env && forge script script/11_SetFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --gas-estimate-multiplier 400
contract SetFeeReceiver is Script {
    address constant FEE_RECEIVER = 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C;

    function run() external {
        address ausdBorrowVault = vm.envAddress("AUSD_BORROW_VAULT");
        address wmonBorrowVault = vm.envAddress("WMON_BORROW_VAULT");

        vm.startBroadcast();

        IEVault(ausdBorrowVault).setFeeReceiver(FEE_RECEIVER);
        IEVault(wmonBorrowVault).setFeeReceiver(FEE_RECEIVER);

        vm.stopBroadcast();

        console.log("\n=== FEE RECEIVER SET ===");
        console.log("AUSD Borrow Vault: %s", ausdBorrowVault);
        console.log("WMON Borrow Vault: %s", wmonBorrowVault);
        console.log("Fee Receiver:      %s", FEE_RECEIVER);
    }
}
