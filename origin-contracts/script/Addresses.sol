// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses
/// @notice Ethereum mainnet addresses for the Origin ARM x Euler deployment.
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
    address constant WETH          = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ARM_WETH_STETH = 0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6;

    // ─── Oracles ───
    address constant CHAINLINK_ETH_USD = 0x10674C8C1aE2072d4a75FE83f1E159425fd84E1D;
}
