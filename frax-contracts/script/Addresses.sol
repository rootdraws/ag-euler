// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Addresses — Base (8453) constants for the Frax ICHI cluster
library Addresses {
    // ── Euler V2 Core (Base) ────────────────────────────────────────────
    address constant EVC            = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address constant KINK_IRM_FACTORY = 0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E;

    // ── Tokens ──────────────────────────────────────────────────────────
    address constant frxUSD    = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
    address constant BRZ_TOKEN = 0xE9185Ee218cae427aF7B9764A011bb89FeA761B4; // BRZ (Brazilian Digital Real)

    // ── ICHI Vaults (single-sided frxUSD on Hydrex / Algebra V3) ────────
    address constant ICHI_BRZ   = 0x80CBb36F48fad69069a3B93989EEE3bAD8f3f103; // frxUSD/BRZ
    address constant ICHI_TGBP  = 0x52801C578172c7cb60a0646fc0af6a42A47bA403; // tGBP/frxUSD
    address constant ICHI_USDC  = 0x6F28872Ed9b0dAe3273f5d9eadBeD224f8D24c19; // USDC/frxUSD
    address constant ICHI_IDRX  = 0x1ffEa4b2d372d2c85fE3A7f28BB1B213dF8c58ED; // IDRX/frxUSD
    address constant ICHI_KRWQ  = 0xdD01Aa17Db58068b877001f3741422DF439c0E0d; // KRWQ/frxUSD
}
