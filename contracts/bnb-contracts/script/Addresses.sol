// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses
/// @notice BSC (56) addresses for the USDT + BNB cross-margin Euler V2 cluster.
library Addresses {
    // ─── Euler Core (BSC) ───
    address constant EVC            = 0xb2E5a73CeE08593d1a076a2AE7A6e02925a640ea;
    address constant EVAULT_FACTORY = 0x7F53E2755eB3c43824E162F7F6F087832B9C9Df6;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── Euler Periphery (BSC) ───
    address constant KINK_IRM_FACTORY      = 0x40739156B75b477f5b4f2D671655492B535B59d2;
    address constant ORACLE_ROUTER_FACTORY = 0xbe83f65e5e898D482FfAEA251B62647c411576F1;
    address constant SWAPPER               = 0xAE4043937906975E95F885d8113D331133266Ee4;
    address constant SWAP_VERIFIER         = 0xA8a4f96EC451f39Eb95913459901f39F5E1C068B;
    address constant GOVERNED_PERSPECTIVE  = 0x775231E5da4F548555eeE633ebf7355a83A0FC03;

    // ─── Tokens ───
    // ⚠ USDT on BSC is 18 decimals (not 6 like Ethereum/Base)
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // 18 decimals
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // 18 decimals

    // ─── Unit of Account ───
    address constant USD = address(840); // ISO 4217 USD

    // ─── Existing Oracle Adapters (BSC, from OracleAdaptersAddresses.csv) ───
    address constant USDT_USD_ADAPTER = 0x7e262cD6226328AaF4eA5C993a952E18Dd633Bc8; // Chainlink USDT/USD
    address constant WBNB_USD_ADAPTER = 0xC8228b83F1d97a431A48bd9Bc3e971c8b418d889; // Chainlink WBNB/USD
}
