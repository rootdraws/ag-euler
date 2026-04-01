// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {CorkOracleImpl} from "../src/oracle/CorkOracleImpl.sol";
import {CSTZeroOracle} from "../src/oracle/CSTZeroOracle.sol";

/// @title 02_DeployOracles
/// @notice Step 2 of 7: Deploy CorkOracleImpl and CSTZeroOracle.
///
/// @dev Prerequisites: EULER_ROUTER must be set in .env from step 01.
///
/// @dev Run:
///      source .env && forge script script/02_DeployOracles.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev After running: paste CORK_ORACLE_IMPL and CST_ZERO_ORACLE into .env,
///      then run 03_DeployVaults.s.sol
contract DeployOracles is Script {
    // Assets
    address constant vbUSDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    address constant sUSDe  = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant cST    = 0x1B42544F897B7Ab236C111A4f800A54D94840688;
    address constant USD    = address(840); // 0x0000000000000000000000000000000000000348

    // Cork Infrastructure
    address constant corkPoolManager = 0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC;
    bytes32 constant corkPoolId      = 0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a;

    function run() external {
        address deployer = msg.sender;
        address router   = vm.envAddress("EULER_ROUTER");

        vm.startBroadcast();

        // CorkOracleImpl: prices vbUSDC/USD using Cork pool parameters.
        // sUsdePriceOracle = EulerRouter — resolves sUSDe → USDe → Chainlink USDe/USD.
        CorkOracleImpl corkOracle = new CorkOracleImpl(
            corkPoolManager,
            corkPoolId,
            vbUSDC,   // base
            USD,      // quote
            sUSDe,    // sUsdeToken
            router,   // sUsdePriceOracle
            1e18,     // hPool (no impairment)
            deployer  // governor
        );

        // CSTZeroOracle: always returns 0 for cST/USD.
        CSTZeroOracle cstOracle = new CSTZeroOracle(cST, USD);

        vm.stopBroadcast();

        console.log("\n=== STEP 2 COMPLETE: Oracles ===");
        console.log("CORK_ORACLE_IMPL=%s", address(corkOracle));
        console.log("CST_ZERO_ORACLE=%s", address(cstOracle));
        console.log("\nPaste both into .env, then run 03_DeployVaults.s.sol");
    }
}
