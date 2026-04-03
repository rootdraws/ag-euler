// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {Addresses} from "./Addresses.sol";

/// @title 01_DeployVIRTUALAdapter
/// @notice Step 1: Deploy Chainlink VIRTUAL/USD oracle adapter.
///
/// @dev Run:
///      source .env && forge script script/01_DeployVIRTUALAdapter.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev After running: paste VIRTUAL_USD_ADAPTER into .env
contract DeployVIRTUALAdapter is Script {
    uint256 constant MAX_STALENESS = 25 hours; // 24h heartbeat + 1h buffer

    function run() external {
        vm.startBroadcast();

        ChainlinkOracle adapter = new ChainlinkOracle(
            Addresses.VIRTUAL,                // base
            Addresses.USD,                    // quote
            Addresses.CHAINLINK_VIRTUAL_USD,  // feed
            MAX_STALENESS                     // maxStaleness
        );

        vm.stopBroadcast();

        console.log("\n=== STEP 1 COMPLETE: ChainlinkOracle (VIRTUAL/USD) ===");
        console.log("VIRTUAL_USD_ADAPTER=%s", address(adapter));
        console.log("  base:         %s (VIRTUAL)", Addresses.VIRTUAL);
        console.log("  quote:        %s (USD)", Addresses.USD);
        console.log("  feed:         %s", Addresses.CHAINLINK_VIRTUAL_USD);
        console.log("  maxStaleness: %s seconds", MAX_STALENESS);
        console.log("\nPaste into .env, then run 02_DeployVIRTUALIRM.s.sol");
    }
}
