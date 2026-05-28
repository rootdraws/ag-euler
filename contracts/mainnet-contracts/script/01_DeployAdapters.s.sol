// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {CrossAdapter} from "euler-price-oracle/adapter/CrossAdapter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 01_DeployAdapters
/// @notice Step 1 of 6: Deploy oracle adapters for the ETH/USDC/WBTC cross-margin triad.
///
/// @dev The cluster router uses WETH as unit of account (reused from the existing
///      Origin ARM market). USDC and WBTC prices are composed through USD:
///
///        USDC → USDC/USD adapter → (cross USD) → ETH/USD adapter → WETH
///        WBTC →  BTC/USD adapter → (cross USD) → ETH/USD adapter → WETH
///
///      The ETH/USD adapter (0x10674C...) is already deployed and is a wrapped
///      ChainlinkOracle with base=WETH / quote=USD. We chain off it for both sides.
///
///      WBTC uses the raw Chainlink BTC/USD feed directly (no WBTC/BTC depeg
///      correction). Conservative caps and LTVs compensate for WBTC/BTC basis risk.
///
/// @dev Run:
///      source .env && forge script script/01_DeployAdapters.s.sol \
///        --rpc-url $RPC_URL_MAINNET --account dev --sender $DEPLOYER \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running, paste into .env:
///      USDC_USD_ADAPTER=<address>
///      WBTC_USD_ADAPTER=<address>
///      USDC_WETH_ADAPTER=<address>
///      WBTC_WETH_ADAPTER=<address>
contract DeployAdapters is Script {
    uint256 constant USDC_MAX_STALENESS = 25 hours;    // 24h heartbeat + 1h buffer
    uint256 constant BTC_MAX_STALENESS  = 6 hours;     // 1h heartbeat + 5h buffer

    function run() external {
        vm.startBroadcast();

        // ── Single-hop adapters (token/USD) ──
        ChainlinkOracle usdcUsd = new ChainlinkOracle(
            Addresses.USDC,
            Addresses.USD,
            Addresses.CHAINLINK_USDC_USD,
            USDC_MAX_STALENESS
        );

        ChainlinkOracle wbtcUsd = new ChainlinkOracle(
            Addresses.WBTC,
            Addresses.USD,
            Addresses.CHAINLINK_BTC_USD,
            BTC_MAX_STALENESS
        );

        // ── CrossAdapters (token/WETH via USD) ──
        CrossAdapter usdcWeth = new CrossAdapter(
            Addresses.USDC,
            Addresses.USD,
            Addresses.WETH,
            address(usdcUsd),
            Addresses.ETH_USD_ADAPTER
        );

        CrossAdapter wbtcWeth = new CrossAdapter(
            Addresses.WBTC,
            Addresses.USD,
            Addresses.WETH,
            address(wbtcUsd),
            Addresses.ETH_USD_ADAPTER
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 1 COMPLETE: Oracle Adapters ===");
        console.log("USDC_USD_ADAPTER=%s",  address(usdcUsd));
        console.log("WBTC_USD_ADAPTER=%s",  address(wbtcUsd));
        console.log("USDC_WETH_ADAPTER=%s", address(usdcWeth));
        console.log("WBTC_WETH_ADAPTER=%s", address(wbtcWeth));
        console.log("\nPaste into .env, then run 02_DeployIRMs.s.sol");
    }
}
