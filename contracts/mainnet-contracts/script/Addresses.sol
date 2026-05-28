// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses
/// @notice Ethereum mainnet (chainId 1) addresses for AG cross-margin clusters.
/// @dev The ETH/USDC/WBTC triad extends the existing Origin ARM/WETH market by
///      sharing the same EulerRouter and WETH borrow vault. Governance on the
///      existing three contracts (router, WETH vault, ARM vault) is the AG Safe.
///      The new USDC + WBTC vaults deployed from this project retain the
///      deployer EOA as governor for operational control during bring-up.
library Addresses {
    // ─── Euler Core ───
    address constant EVC            = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant EVAULT_FACTORY = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── Euler Periphery ───
    address constant KINK_IRM_FACTORY      = 0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9;
    address constant ORACLE_ROUTER_FACTORY = 0x70B3f6F61b7Bf237DF04589DdAA842121072326A;
    address constant SWAPPER               = 0x2Bba09866b6F1025258542478C39720A09B728bF;
    address constant SWAP_VERIFIER         = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;

    // ─── EulerSwap V2 ───
    address constant EULER_SWAP_V2_FACTORY = 0xD05213331221fAB8a3C387F2affBb605Bb04DF5F;

    // ─── Tokens ───
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 decimals
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 decimals

    // ─── Unit of Account ───
    address constant USD = address(840); // ISO 4217 USD — used as the cross asset by CrossAdapter chains

    // ─── Euler Oracle Adapters (pre-deployed, wrapped ChainlinkOracle) ───
    /// @dev ETH/USD adapter shared with the Origin ARM market (base=WETH, quote=USD).
    ///      Used as the `oracleCrossQuote` leg of both new CrossAdapters.
    address constant ETH_USD_ADAPTER = 0x10674C8C1aE2072d4a75FE83f1E159425fd84E1D;

    // ─── Chainlink Aggregator Feeds (raw) ───
    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // 24h heartbeat
    address constant CHAINLINK_BTC_USD  = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // 1h heartbeat

    // ─── Existing Origin ARM Deployment (chain 1) ───
    /// @dev Shared router; new USDC + WBTC vaults use this same router.
    address constant EULER_ROUTER = 0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3;

    /// @dev Existing WETH borrow vault — governed by the AG Safe. Scripts 04 and 06
    ///      emit calldata for the Safe to accept USDC and WBTC as collateral here.
    address constant WETH_BORROW_VAULT = 0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B;

    /// @dev Existing ARM collateral vault — unchanged by the triad extension.
    address constant ARM_COLLATERAL_VAULT = 0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd;

    /// @dev AG Safe — governor on the existing router + WETH vault + ARM vault.
    ///      Any governance call on those three contracts must be executed here.
    address constant AG_SAFE = 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C;
}
