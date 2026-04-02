// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses
/// @notice Base (8453) addresses for the AERO × Euler deployment (extending VVV cluster).
library Addresses {
    // ─── Euler Core (Base) ───
    address constant EVC            = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── Euler Periphery (Base) ───
    address constant KINK_IRM_FACTORY      = 0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E;
    address constant ORACLE_ROUTER_FACTORY = 0xA9287853987B107969f181Cce5e25e0D09c1c116;
    address constant SWAPPER               = 0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df;
    address constant SWAP_VERIFIER         = 0x30660764A7a05B84608812C8AFC0Cb4845439EEe;

    // ─── Tokens ───
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631; // Aerodrome (18 decimals)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 decimals
    address constant VVV  = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // 18 decimals
    address constant WETH = 0x4200000000000000000000000000000000000006; // 18 decimals
    address constant ZRO  = 0x6985884C4392D348587B19cb9eAAf157F13271cd; // 18 decimals

    // ─── Unit of Account ───
    address constant USD = address(840); // ISO 4217 USD — treated as 18 decimals by Euler

    // ─── Chainlink Price Feeds ───
    address constant CHAINLINK_AERO_USD = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;
}
