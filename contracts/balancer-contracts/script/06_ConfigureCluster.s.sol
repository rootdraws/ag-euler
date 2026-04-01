// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setInterestRateModel(address irm) external;
    function setMaxLiquidationDiscount(uint16 discount) external;
    function setLiquidationCoolOffTime(uint16 coolOffTime) external;
    function setCaps(uint16 supplyCap, uint16 borrowCap) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
}

/// @title 06_ConfigureCluster
/// @notice Step 6 of 6: Configure IRM, risk params, and LTVs on borrow vaults.
///
/// @dev Prerequisites (all must be set in .env):
///      KINK_IRM, AUSD_BORROW_VAULT, WMON_BORROW_VAULT
///      POOL1_VAULT, POOL2_VAULT, POOL3_VAULT, POOL4_VAULT
///
/// @dev AUSD borrow vault accepts Pool1 (wnAUSD/wnUSDC/wnUSDT0) and Pool4 (wnLOAZND/AZND/wnAUSD)
///      WMON borrow vault accepts Pool2 (sMON/wnWMON) and Pool3 (shMON/wnWMON)
///
/// @dev Run:
///      source .env && forge script script/06_ConfigureCluster.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY --broadcast
///
/// @dev No new addresses. Deployment complete.
contract ConfigureCluster is Script {
    uint16 constant MAX_LIQ_DISCOUNT  = 0.05e4; // 5%
    uint16 constant LIQ_COOL_OFF_TIME = 1;
    uint16 constant BORROW_LTV        = 0.95e4; // 9500
    uint16 constant LLTV              = 0.96e4; // 9600

    function run() external {
        address irm             = vm.envAddress("KINK_IRM");
        address ausdBorrowVault = vm.envAddress("AUSD_BORROW_VAULT");
        address wmonBorrowVault = vm.envAddress("WMON_BORROW_VAULT");
        address pool1Vault      = vm.envAddress("POOL1_VAULT");
        address pool2Vault      = vm.envAddress("POOL2_VAULT");
        address pool3Vault      = vm.envAddress("POOL3_VAULT");
        address pool4Vault      = vm.envAddress("POOL4_VAULT");

        vm.startBroadcast();

        IEVault(ausdBorrowVault).setInterestRateModel(irm);
        IEVault(ausdBorrowVault).setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        IEVault(ausdBorrowVault).setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        IEVault(ausdBorrowVault).setCaps(0, 0);
        IEVault(ausdBorrowVault).setLTV(pool1Vault, BORROW_LTV, LLTV, 0);
        IEVault(ausdBorrowVault).setLTV(pool4Vault, BORROW_LTV, LLTV, 0);

        IEVault(wmonBorrowVault).setInterestRateModel(irm);
        IEVault(wmonBorrowVault).setMaxLiquidationDiscount(MAX_LIQ_DISCOUNT);
        IEVault(wmonBorrowVault).setLiquidationCoolOffTime(LIQ_COOL_OFF_TIME);
        IEVault(wmonBorrowVault).setCaps(0, 0);
        IEVault(wmonBorrowVault).setLTV(pool2Vault, BORROW_LTV, LLTV, 0);
        IEVault(wmonBorrowVault).setLTV(pool3Vault, BORROW_LTV, LLTV, 0);

        vm.stopBroadcast();

        console.log("\n=== STEP 6 COMPLETE: Cluster Configured ===");
        console.log("AUSD borrow vault: IRM, discount, cooloff, caps, LTV pool1+pool4");
        console.log("WMON borrow vault: IRM, discount, cooloff, caps, LTV pool2+pool3");
        console.log("\nTODO: setFeeReceiver(agAddress) on both vaults once AG has Monad fee address.");
        console.log("TODO: tighten caps before full launch.");
        console.log("\nDeployment complete. Add vault addresses to balancer-labels repo.");
    }
}
