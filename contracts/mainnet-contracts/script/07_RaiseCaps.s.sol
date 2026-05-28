// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEVault {
    function setCaps(uint16 supplyCap, uint16 borrowCap) external;
    function governorAdmin() external view returns (address);
    function caps() external view returns (uint16, uint16);
}

/// @title 07_RaiseCaps
/// @notice Raise supply + borrow caps on the AG triad's new USDC and WBTC vaults.
///
/// @dev AmountCap encoding (AmountCapLib.resolve in euler-vault-kit):
///        resolved_wei = mantissa * 10^exp / 100
///        mantissa = upper 10 bits, exp = lower 6 bits
///
///      New caps:
///        USDC: 5,000,000 USDC (6 dec)  → 5e12 wei → (500<<6)|12 = 32012
///        WBTC: 50 WBTC        (8 dec)  → 5e9  wei → (500<<6)|9  = 32009
///
/// @dev The prior caps (32010 / 32007) were set under the wrong formula assumption
///      (mantissa*10^exp instead of mantissa*10^exp/100), which resulted in caps
///      100x smaller than documented: 50,000 USDC and 0.5 WBTC.
///
/// @dev Deployer EOA is still governor on both vaults, so this broadcasts directly.
///
/// @dev Run (user's own terminal):
///      forge script script/07_RaiseCaps.s.sol \
///        --rpc-url $RPC_URL_MAINNET --account dev --sender $DEPLOYER --broadcast
contract RaiseCaps is Script {
    uint16 constant USDC_CAP_NEW = 32012; // 5,000,000 USDC
    uint16 constant WBTC_CAP_NEW = 32009; // 50 WBTC

    function run() external {
        address usdcVault = vm.envAddress("USDC_BORROW_VAULT");
        address wbtcVault = vm.envAddress("WBTC_BORROW_VAULT");
        address deployer  = msg.sender;

        require(IEVault(usdcVault).governorAdmin() == deployer, "USDC vault not governed by deployer");
        require(IEVault(wbtcVault).governorAdmin() == deployer, "WBTC vault not governed by deployer");

        (uint16 uSupBefore, uint16 uBorBefore) = IEVault(usdcVault).caps();
        (uint16 wSupBefore, uint16 wBorBefore) = IEVault(wbtcVault).caps();

        vm.startBroadcast();
        IEVault(usdcVault).setCaps(USDC_CAP_NEW, USDC_CAP_NEW);
        IEVault(wbtcVault).setCaps(WBTC_CAP_NEW, WBTC_CAP_NEW);
        vm.stopBroadcast();

        console.log("\n=== STEP 7 COMPLETE: Caps Raised ===");
        console.log("USDC vault: %s", usdcVault);
        console.log("  before: supply=%s borrow=%s (50,000 USDC)", uint256(uSupBefore), uint256(uBorBefore));
        console.log("  after:  supply=%s borrow=%s (5,000,000 USDC)", uint256(USDC_CAP_NEW), uint256(USDC_CAP_NEW));
        console.log("WBTC vault: %s", wbtcVault);
        console.log("  before: supply=%s borrow=%s (0.5 WBTC)", uint256(wSupBefore), uint256(wBorBefore));
        console.log("  after:  supply=%s borrow=%s (50 WBTC)", uint256(WBTC_CAP_NEW), uint256(WBTC_CAP_NEW));
    }
}
