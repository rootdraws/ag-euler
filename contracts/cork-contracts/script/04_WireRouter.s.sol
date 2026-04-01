// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

/// @title 04_WireRouter
/// @notice Step 4 of 7: Wire the EulerRouter with all oracle configs and resolved vaults.
///
/// @dev Prerequisites (all must be set in .env):
///      EULER_ROUTER, CORK_ORACLE_IMPL, CST_ZERO_ORACLE, VBUSDC_VAULT, CST_VAULT
///
/// @dev Oracle resolution chains:
///      sUSDe/USD: sUSDe → [resolvedVault] → USDe → [govSetConfig] → Chainlink USDe/USD
///      vbUSDC/USD: vbUSDCVault → [resolvedVault] → vbUSDC → [govSetConfig] → CorkOracleImpl
///      cST/USD:    cSTVault → [resolvedVault] → cST → [govSetConfig] → CSTZeroOracle (0)
///
/// @dev Run:
///      source .env && forge script script/04_WireRouter.s.sol \
///        --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
///        --broadcast --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev No new contracts deployed. Nothing to capture. Run 05_DeployHookAndWire.s.sol next.
contract WireRouter is Script {
    // Assets
    address constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant USDe  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant vbUSDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    address constant cST   = 0x1B42544F897B7Ab236C111A4f800A54D94840688;
    address constant USD   = address(840);

    // Existing USDe/USD Chainlink adapter (ChainlinkInfrequentOracle, reused from Yield cluster)
    address constant usdeUsdOracle = 0x93840A424aBc32549809Dd0Bc07cEb56E137221C;

    function run() external {
        address router        = vm.envAddress("EULER_ROUTER");
        address corkOracleImpl = vm.envAddress("CORK_ORACLE_IMPL");
        address cstZeroOracle  = vm.envAddress("CST_ZERO_ORACLE");
        address vbUSDCVault    = vm.envAddress("VBUSDC_VAULT");
        address cSTVault       = vm.envAddress("CST_VAULT");

        EulerRouter r = EulerRouter(router);

        vm.startBroadcast();

        // sUSDe/USD chain: resolve sUSDe (ERC4626) → USDe via convertToAssets, then Chainlink
        r.govSetResolvedVault(sUSDe, true);
        r.govSetConfig(USDe, USD, usdeUsdOracle);

        // vbUSDC/USD chain: resolve vbUSDCVault → vbUSDC (1:1), then CorkOracleImpl
        r.govSetResolvedVault(vbUSDCVault, true);
        r.govSetConfig(vbUSDC, USD, corkOracleImpl);

        // cST/USD chain: resolve cSTVault → cST, then CSTZeroOracle (always 0)
        r.govSetResolvedVault(cSTVault, true);
        r.govSetConfig(cST, USD, cstZeroOracle);

        vm.stopBroadcast();

        console.log("\n=== STEP 4 COMPLETE: EulerRouter Wired ===");
        console.log("govSetResolvedVault(sUSDe, true)");
        console.log("govSetConfig(USDe, USD, %s)", usdeUsdOracle);
        console.log("govSetResolvedVault(vbUSDCVault, true) -> %s", vbUSDCVault);
        console.log("govSetConfig(vbUSDC, USD, %s)", corkOracleImpl);
        console.log("govSetResolvedVault(cSTVault, true) -> %s", cSTVault);
        console.log("govSetConfig(cST, USD, %s)", cstZeroOracle);
        console.log("\nRun 05_DeployHookAndWire.s.sol next.");
    }
}
