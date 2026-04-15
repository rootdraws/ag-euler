// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setFeeReceiver(address receiver) external;
}

/// @title 07_SetFeeReceiver
/// @notice Step 7 of 7: Point interest fees at the AG fee receiver.
///
/// @dev Run:
///      source .env && forge script script/07_SetFeeReceiver.s.sol \
///        --rpc-url $RPC_URL_BSC --account dev --sender $DEPLOYER --broadcast
contract SetFeeReceiver is Script {
    function run() external {
        address usdtBorrowVault = vm.envAddress("USDT_BORROW_VAULT");
        address bnbBorrowVault  = vm.envAddress("BNB_BORROW_VAULT");
        address feeReceiver     = vm.envAddress("FEE_RECEIVER");

        require(feeReceiver != address(0), "FEE_RECEIVER not set");

        vm.startBroadcast();

        IEVault(usdtBorrowVault).setFeeReceiver(feeReceiver);
        IEVault(bnbBorrowVault).setFeeReceiver(feeReceiver);

        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: Fee Receivers Set ===");
        console.log("Fee receiver:      %s", feeReceiver);
        console.log("  USDT borrow:     %s", usdtBorrowVault);
        console.log("  BNB  borrow:     %s", bnbBorrowVault);
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Next steps:");
        console.log("  1. Add vault addresses to frontends/labels/alphagrowth/56/");
        console.log("  2. Submit official listing PR to euler-xyz/euler-labels");
        console.log("  3. Transfer governor to AG Safe (0x4f89...Fd3C)");
    }
}
