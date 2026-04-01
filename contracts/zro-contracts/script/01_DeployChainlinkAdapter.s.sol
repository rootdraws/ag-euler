// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";

/// @title 01_DeployChainlinkAdapter
/// @notice Step 1 of 7: Deploy a ChainlinkOracle adapter for ZRO/USD on Base.
///   - base  = ZRO
///   - quote = USD (address(840))
///   - feed  = Chainlink ZRO/USD (0xdc31a...)
///   - maxStaleness = 90000 (25h — heartbeat is 24h + buffer)
///
/// @dev Usage:
///   source .env
///   forge script script/01_DeployChainlinkAdapter.s.sol:DeployChainlinkAdapter \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env: CHAINLINK_ZRO_USD_ADAPTER=<address>
contract DeployChainlinkAdapter is Script {
    uint256 constant MAX_STALENESS = 90_000; // 25 hours (24h heartbeat + 1h buffer)

    function run() external {
        vm.startBroadcast();

        ChainlinkOracle adapter = new ChainlinkOracle(
            Addresses.ZRO,
            Addresses.USD,
            Addresses.CHAINLINK_ZRO_USD,
            MAX_STALENESS
        );

        vm.stopBroadcast();

        console.log("=== STEP 1 COMPLETE: Chainlink ZRO/USD Adapter Deployed ===");
        console.log("ChainlinkOracle:", address(adapter));
        console.log("  base:          ZRO (%s)", Addresses.ZRO);
        console.log("  quote:         USD (%s)", Addresses.USD);
        console.log("  feed:          %s", Addresses.CHAINLINK_ZRO_USD);
        console.log("  maxStaleness:  %s seconds (25h)", MAX_STALENESS);
        console.log("\nAdd to .env: CHAINLINK_ZRO_USD_ADAPTER=%s", address(adapter));
        console.log("Run 02_DeployIRMs.s.sol next.");
    }
}
