// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
    function feeReceiver() external view returns (address);
}

/// @title 07_SetFeeReceiver
/// @notice Post-deployment: set the fee receiver on the WETH borrow vault.
///
/// @dev Run:
///      source .env && forge script script/07_SetFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY --broadcast
contract SetFeeReceiver is Script {
    function run() external {
        address wethBorrowVault = vm.envAddress("WETH_BORROW_VAULT");
        address feeReceiver     = vm.envAddress("FEE_RECEIVER");

        require(feeReceiver != address(0), "FEE_RECEIVER not set");

        vm.startBroadcast();
        IEVault(wethBorrowVault).setFeeReceiver(feeReceiver);
        vm.stopBroadcast();

        console.log("Fee receiver set to %s on vault %s", feeReceiver, wethBorrowVault);
    }
}
