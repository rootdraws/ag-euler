// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
    function feeReceiver() external view returns (address);
}

/// @title 07_SetFeeReceiver
/// @notice Step 7 of 7 (optional): Set AG curator fee receiver on USDC borrow vault.
///
/// @dev Defaults to Addresses.FEE_RECEIVER (AG curator address).
///      Override by setting FEE_RECEIVER in .env if you want a different receiver.
///
/// @dev Run:
///      source .env && forge script script/07_SetFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY --broadcast
contract SetFeeReceiver is Script {
    function run() external {
        address usdcBorrowVault = vm.envAddress("USDC_BORROW_VAULT");

        address feeReceiver;
        try vm.envAddress("FEE_RECEIVER") returns (address override_) {
            feeReceiver = override_ == address(0) ? Addresses.FEE_RECEIVER : override_;
        } catch {
            feeReceiver = Addresses.FEE_RECEIVER;
        }

        require(feeReceiver != address(0), "fee receiver cannot be zero");

        vm.startBroadcast();
        IEVault(usdcBorrowVault).setFeeReceiver(feeReceiver);
        vm.stopBroadcast();

        console.log("Fee receiver set to %s on USDC borrow vault %s", feeReceiver, usdcBorrowVault);
    }
}
