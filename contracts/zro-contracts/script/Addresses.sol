// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses — Base (8453) constants for the ZRO × Euler deployment.
library Addresses {
    // ─── Euler V2 Core (Base) ───
    address constant EVC            = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── Euler Periphery (Base) ───
    address constant KINK_IRM_FACTORY      = 0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E;
    address constant ORACLE_ROUTER_FACTORY = 0xA9287853987B107969f181Cce5e25e0D09c1c116;
    address constant SWAPPER               = 0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df;
    address constant SWAP_VERIFIER         = 0x30660764A7a05B84608812C8AFC0Cb4845439EEe;

    // ─── Tokens ───
    address constant ZRO  = 0x6985884C4392D348587B19cb9eAAf157F13271cd; // LayerZero (18 decimals)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Circle USDC (6 decimals)
    address constant WETH = 0x4200000000000000000000000000000000000006; // Wrapped ETH (18 decimals)

    // ─── Unit of Account ───
    address constant USD = 0x0000000000000000000000000000000000000348; // address(840)

    // ─── Chainlink Feeds ───
    address constant CHAINLINK_ZRO_USD = 0xdc31a4CCfCA039BeC6222e20BE7770E12581bfEB; // 24h heartbeat

    // ─── Existing Oracle Adapters (already deployed on Base, whitelisted) ───
    address constant USDC_USD_ADAPTER = 0x5C9d3504d64B401BE0E6fDA1b7970e2f5FF75485; // Chainlink USDC/USD
    address constant ETH_USD_ADAPTER  = 0xeCa05CC73e67c344d5B146311B13ddB75F7fE4E4;  // Chainlink ETH/USD
}
