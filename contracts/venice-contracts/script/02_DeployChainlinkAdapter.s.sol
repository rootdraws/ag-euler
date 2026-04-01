// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {Addresses} from "./Addresses.sol";

/// @title 02_DeployChainlinkAdapter
/// @notice Step 2 of 10: Deploy a ChainlinkOracle adapter for VVV/USD.
///
/// @dev The ChainlinkOracle from euler-price-oracle wraps a Chainlink AggregatorV3
///      feed into the Euler IPriceOracle interface. Constructor:
///        ChainlinkOracle(base, quote, feed, maxStaleness)
///
///      base  = VVV token (18 decimals)
///      quote = USD address(840) (18 decimals by convention)
///      feed  = Chainlink VVV/USD aggregator
///      maxStaleness = 25 hours (typical for 24h heartbeat feeds + buffer)
///
/// @dev Run:
///      source .env && forge script script/02_DeployChainlinkAdapter.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste VVV_USD_ADAPTER=<address> into .env
contract DeployChainlinkAdapter is Script {
    uint256 constant MAX_STALENESS = 25 hours;

    function run() external {
        vm.startBroadcast();

        ChainlinkOracle adapter = new ChainlinkOracle(
            Addresses.VVV,              // base
            Addresses.USD,              // quote
            Addresses.CHAINLINK_VVV_USD, // feed
            MAX_STALENESS               // maxStaleness
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: ChainlinkOracle (VVV/USD) ===");
        console.log("VVV_USD_ADAPTER=%s", address(adapter));
        console.log("  base:         %s (VVV)", Addresses.VVV);
        console.log("  quote:        %s (USD)", Addresses.USD);
        console.log("  feed:         %s", Addresses.CHAINLINK_VVV_USD);
        console.log("  maxStaleness: %s seconds", MAX_STALENESS);
        console.log("\nPaste into .env, then run 03_DeployRouter.s.sol");
    }
}
