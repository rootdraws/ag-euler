// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";

interface IEVaultFactory {
    function createProxy(address implementation, bool upgradeable, bytes calldata trailingData)
        external returns (address vault);
}

interface IEVault {
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
}

/// @title 08_AddBrzTokenCollateral
/// @notice Adds raw BRZ token as a direct collateral type to the existing frxUSD borrow cluster.
///   Unlike the ICHI vault collaterals, BRZ is deposited as a plain ERC-20 token — not wrapped
///   in an ICHI vault first.
///
///   Three steps in a single broadcast:
///     1. Deploy ChainlinkOracle adapter (BRZ_TOKEN → frxUSD via the BRZ/USD Chainlink feed)
///     2. Deploy collateral eVault wrapping BRZ_TOKEN (oracle=address(0), uoa=address(0))
///        + wire EulerRouter: govSetConfig(BRZ_TOKEN, frxUSD, oracle) +
///                            govSetResolvedVault(cvBrzToken, true)
///     3. setLTV on the frxUSD borrow vault (85% borrow / 90% liquidation — adjust as needed)
///
/// @dev frxUSD is pegged 1:1 to USD, so the Chainlink BRZ/USD feed prices BRZ in frxUSD directly.
///      maxStaleness is set to 90 000 s (25 h) — slightly above the 24 h Chainlink BRZ/USD heartbeat.
///      Tighten this if a shorter-heartbeat feed becomes available.
///
/// @dev Prerequisites (must be in .env before running):
///   EULER_ROUTER        — deployed in step 02
///   FRXUSD_BORROW_VAULT — deployed in step 04
///   BRZ_CHAINLINK_FEED  — 0x0b0E64c05083FdF9ED7C5D3d8262c4216eFc9394
///
/// @dev Usage:
///   source .env
///   forge script script/08_AddBrzTokenCollateral.s.sol:AddBrzTokenCollateral \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env:
///     ORACLE_BRZ_TOKEN=<addr>
///     COLLATERAL_VAULT_BRZ_TOKEN=<addr>
contract AddBrzTokenCollateral is Script {
    // BRZ is an FX stablecoin pegged to BRL.
    // 85% / 90% LTV (conservative vs ICHI frxUSD vaults). Adjust before production.
    uint16 constant BORROW_LTV = 8500; // 85.00%
    uint16 constant LIQ_LTV   = 9000; // 90.00%

    // 25 hours — slightly above the Chainlink BRZ/USD 24 h heartbeat
    uint256 constant MAX_STALENESS = 90_000;

    function run() external {
        address routerAddr  = vm.envAddress("EULER_ROUTER");
        address borrowVault = vm.envAddress("FRXUSD_BORROW_VAULT");
        address feed        = vm.envAddress("BRZ_CHAINLINK_FEED");

        vm.startBroadcast();

        // 1. Deploy ChainlinkOracle adapter: BRZ_TOKEN priced in frxUSD via BRZ/USD feed
        ChainlinkOracle oracle = new ChainlinkOracle(
            Addresses.BRZ_TOKEN,
            Addresses.frxUSD,
            feed,
            MAX_STALENESS
        );

        // 2. Deploy collateral eVault for raw BRZ token
        address cvBrzToken = IEVaultFactory(Addresses.EVAULT_FACTORY).createProxy(
            address(0), true, abi.encodePacked(Addresses.BRZ_TOKEN, address(0), address(0))
        );

        // 3. Wire the router
        EulerRouter router = EulerRouter(routerAddr);
        router.govSetConfig(Addresses.BRZ_TOKEN, Addresses.frxUSD, address(oracle));
        router.govSetResolvedVault(cvBrzToken, true);

        // 4. Set LTV on the borrow vault
        IEVault(borrowVault).setLTV(cvBrzToken, BORROW_LTV, LIQ_LTV, 0);

        vm.stopBroadcast();

        console.log("=== STEP 8 COMPLETE: BRZ Token Collateral Added ===");
        console.log("ORACLE_BRZ_TOKEN:            %s", address(oracle));
        console.log("COLLATERAL_VAULT_BRZ_TOKEN:  %s", cvBrzToken);
        console.log("  Underlying:      BRZ_TOKEN  %s", Addresses.BRZ_TOKEN);
        console.log("  Chainlink feed:  %s", feed);
        console.log("  Max staleness:   %s s (25 h)", MAX_STALENESS);
        console.log("  Borrow LTV:      85%%");
        console.log("  Liquidation LTV: 90%%");
        console.log("");
        console.log("Add to .env:");
        console.log("  ORACLE_BRZ_TOKEN=%s", address(oracle));
        console.log("  COLLATERAL_VAULT_BRZ_TOKEN=%s", cvBrzToken);
    }
}
