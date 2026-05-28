// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Addresses
/// @notice Base (8453) addresses for the AG test market — agVVVWETHlp / USDC.
/// @dev Isolated experimentation cluster. Not coupled to Venice/Frax/ZRO/AERO clusters.
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

    // ─── Borrow asset ───
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 decimals — Base canonical USDC

    // ─── Collateral: AlphaGrowth VVV Buyback LP Vault (ERC-7540 share token) ───
    /// @dev Vault7540 share wrapping Aerodrome VVV/WETH LP, gauge-staked. 18 decimals.
    /// @dev Per-share value = (gauge LP slice × pool TWAP reserves) + (pile VVV slice).
    address constant AG_VVV_WETH_LP = 0xf6a3B155CB5bd7d77E26b25177392c884b700B6f;

    // ─── Collateral oracle: PileInclusiveOracle ───
    /// @dev Returns USDC value of agVVVWETHlp shares. Composes WETH→USDC Chainlink wrapper
    ///      + VVV→USDC Aerodrome-reserve quote + 30-min TWAP. Used directly by router.
    address constant PILE_INCLUSIVE_ORACLE = 0xDDaF961D09d716044e5C6FCc8eF321825Ad534aB;

    // ─── Sub-oracles (informational; not wired directly) ───
    address constant CHAINLINK_USD_WRAPPER     = 0xA84C8425180A03f07a3c6A044BFEcc68eE01D1b7; // WETH/USDC
    address constant VVV_USD_RESERVE_QUOTE     = 0xC9CF8edB66B2fa89e919bFB0A6470F5af0427422; // VVV/USDC

    // ─── Fee receiver (AG curator share) ───
    address constant FEE_RECEIVER = 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C;
}
