// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Addresses} from "./Addresses.sol";

/// @title 05_WireOracle
/// @notice Step 5 of 7: Wire the EulerRouter so it can quote agVVVWETHlp in USDC.
///
/// @dev Oracle resolution chain (unit of account = USDC):
///
///        Collateral EVault → convertToAssets → agVVVWETHlp share
///                          → PileInclusiveOracle.getQuote(_, agVVVWETHlp, USDC)
///                          → USDC amount (6 decimals)
///
///      Two router config calls:
///        1. govSetResolvedVault(collateralVault) — EVault wraps agVVVWETHlp, share→share ratio
///        2. govSetConfig(agVVVWETHlp, USDC, PileInclusiveOracle) — terminal price step
///
///      The PileInclusiveOracle composes a 30-min Aerodrome TWAP + Chainlink ETH/USD
///      + the harvested VVV pile. Returns USDC base units directly.
///
/// @dev Prerequisites (in .env): EULER_ROUTER, COLLATERAL_VAULT
///
/// @dev Run:
///      source .env && forge script script/05_WireOracle.s.sol \
///        --rpc-url $RPC_URL_BASE --private-key $PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
///
/// @dev No new addresses. Run 06_ConfigureCluster.s.sol next.
contract WireOracle is Script {
    function run() external {
        address router    = vm.envAddress("EULER_ROUTER");
        address collVault = vm.envAddress("COLLATERAL_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // 1. Collateral EVault → agVVVWETHlp shares via ERC-4626 convertToAssets
        r.govSetResolvedVault(collVault, true);

        // 2. agVVVWETHlp → USDC via PileInclusiveOracle
        r.govSetConfig(Addresses.AG_VVV_WETH_LP, Addresses.USDC, Addresses.PILE_INCLUSIVE_ORACLE);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Oracle Wired ===");
        console.log("govSetResolvedVault(%s, true)", collVault);
        console.log("govSetConfig(agVVVWETHlp=%s, USDC=%s, oracle=%s)",
            Addresses.AG_VVV_WETH_LP, Addresses.USDC, Addresses.PILE_INCLUSIVE_ORACLE);
        console.log("Resolution: CollateralVault -> agVVVWETHlp -> USDC (via PileInclusiveOracle)");
        console.log("\nRun 06_ConfigureCluster.s.sol next.");
    }
}
