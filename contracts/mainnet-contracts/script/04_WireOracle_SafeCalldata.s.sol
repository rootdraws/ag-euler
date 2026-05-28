// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

interface IEulerRouter {
    function govSetConfig(address base, address quote, address oracle) external;
    function govSetResolvedVault(address vault, bool set) external;
    function governor() external view returns (address);
    function getConfiguredOracle(address base, address quote) external view returns (address);
    function resolvedVaults(address vault) external view returns (address);
}

/// @title 04_WireOracle_SafeCalldata
/// @notice Step 4 of 6: Wire the EulerRouter to price USDC and WBTC in WETH,
///         and register the new vaults as resolved (eShare → underlying asset).
///
/// @dev Governor on the existing router is the AG Safe (0x4f89...Fd3C). This script
///      does NOT broadcast — it emits the 5 target/calldata tuples the Safe must
///      execute via tx-builder.
///
///      Calls to add (in this order):
///        1. router.govSetConfig(USDC, WETH, USDC_WETH_ADAPTER)
///        2. router.govSetConfig(WBTC, WETH, WBTC_WETH_ADAPTER)
///        3. router.govSetResolvedVault(USDC_BORROW_VAULT, true)
///        4. router.govSetResolvedVault(WBTC_BORROW_VAULT, true)
///        5. router.govSetResolvedVault(WETH_BORROW_VAULT, true)
///
///      Step 5 is what lets the eWETH (existing borrow vault's shares) act as
///      collateral in the new USDC/WBTC vaults — the router needs to resolve its
///      asset() back to WETH (identity).
///
/// @dev Prerequisites (in .env):
///      EULER_ROUTER, USDC_WETH_ADAPTER, WBTC_WETH_ADAPTER,
///      USDC_BORROW_VAULT, WBTC_BORROW_VAULT
///
/// @dev Run (read-only — no broadcast flag):
///      source .env && forge script script/04_WireOracle_SafeCalldata.s.sol \
///        --rpc-url $RPC_URL_MAINNET
///
/// @dev Copy the printed (target, calldata) pairs into the Safe transaction builder
///      as individual transactions, or feed them into a multisend batch.
contract WireOracle_SafeCalldata is Script {
    function run() external view {
        address router         = vm.envAddress("EULER_ROUTER");
        address usdcWethAdapter = vm.envAddress("USDC_WETH_ADAPTER");
        address wbtcWethAdapter = vm.envAddress("WBTC_WETH_ADAPTER");
        address usdcVault       = vm.envAddress("USDC_BORROW_VAULT");
        address wbtcVault       = vm.envAddress("WBTC_BORROW_VAULT");

        // Pre-flight — confirm we're targeting the right Safe.
        address currentGov = IEulerRouter(router).governor();
        require(currentGov == Addresses.AG_SAFE, "router governor != AG Safe; update Addresses.sol");

        bytes[] memory calls = new bytes[](5);
        string[] memory labels = new string[](5);

        calls[0] = abi.encodeCall(IEulerRouter.govSetConfig, (Addresses.USDC, Addresses.WETH, usdcWethAdapter));
        labels[0] = "govSetConfig(USDC, WETH, USDC_WETH_ADAPTER)";

        calls[1] = abi.encodeCall(IEulerRouter.govSetConfig, (Addresses.WBTC, Addresses.WETH, wbtcWethAdapter));
        labels[1] = "govSetConfig(WBTC, WETH, WBTC_WETH_ADAPTER)";

        calls[2] = abi.encodeCall(IEulerRouter.govSetResolvedVault, (usdcVault, true));
        labels[2] = "govSetResolvedVault(USDC_BORROW_VAULT, true)";

        calls[3] = abi.encodeCall(IEulerRouter.govSetResolvedVault, (wbtcVault, true));
        labels[3] = "govSetResolvedVault(WBTC_BORROW_VAULT, true)";

        calls[4] = abi.encodeCall(IEulerRouter.govSetResolvedVault, (Addresses.WETH_BORROW_VAULT, true));
        labels[4] = "govSetResolvedVault(WETH_BORROW_VAULT (existing), true)";

        console.log("\n=== STEP 4: Safe Calldata for Router Wiring ===");
        console.log("Execute from AG Safe: %s", Addresses.AG_SAFE);
        console.log("Target (all 5 calls): %s (EulerRouter)", router);
        console.log("");

        for (uint256 i = 0; i < calls.length; i++) {
            console.log("--- call #%s: %s ---", i + 1, labels[i]);
            console.log("  to:    %s", router);
            console.log("  value: 0");
            console.log("  data:");
            console.logBytes(calls[i]);
            console.log("");
        }

        console.log("After the Safe executes all 5 calls, run 05_ConfigureCluster.s.sol");
    }
}
