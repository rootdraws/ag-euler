// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "euler-price-oracle/adapter/BaseAdapter.sol";

/// @notice Minimal interface for Cork PoolManager — only the functions used in pricing.
interface ICorkPoolManager {
    /// @notice Returns the current swap/exercise rate: sUSDe received per 1 full vbUSDC token.
    /// @dev WAD scale: 1e18 = 1.0. Currently ~0.8187e18.
    function swapRate(bytes32 poolId) external view returns (uint256 rate);

    /// @notice Returns the swap fee percentage. Scale: 1e18 = 1% = 100 bps.
    /// @dev For 5 bps fee: returns 5e16 (0.05% in 1e18=1% scale).
    function swapFee(bytes32 poolId) external view returns (uint256 fees);
}

/// @title CorkOracleImpl
/// @custom:security-contact security@euler.xyz
/// @author Alpha Growth (https://alphagrowth.fun/)
/// @notice Standard PriceOracle adapter that prices vbUSDC in USD using Cork pool parameters.
/// @dev Pricing formula:
///
///      P_RA_effective_USD = min(P_RA_Nav, swapRate * P_sUSDe_USD * (1 - fee) * hPool)
///
///      Where:
///      - P_RA_Nav: vbUSDC NAV ≈ $1 (wraps USDC 1:1, hardcoded as 1e18)
///      - P_sUSDe_USD: sUSDe price in USD, read from the EulerRouter (sUSDe→USDe→Chainlink)
///      - swapRate: vbUSDC→sUSDe exercise rate from CorkPoolManager.swapRate(poolId)
///      - fee: Cork swap fee from CorkPoolManager.swapFee(poolId) (1e18 = 1%)
///      - hPool: impairment factor [0,1] in 1e18 WAD, governance-settable
///
///      inAmount is in native vbUSDC decimals (6). Return value is in native USD decimals (18).
///
///      Fee scale: Cork swapFee uses 1e18 = 1% = 100 bps. For 5 bps: swapFee = 5e16.
///      (1 - fee) in WAD = 1e18 - swapFee/100 = 1e18 - swapFee*1e16/1e18.
///
///      The hook (ProtectedLoopHook) enforces 1:1 cST/REF pairing on borrow. The vault
///      overrides (_withdraw/_deposit) enforce pairing on all collateral movements. This
///      oracle does not need per-account cST coverage checks — the pairing invariant
///      guarantees every account with debt has matched cST.
contract CorkOracleImpl is BaseAdapter {
    /// @inheritdoc IPriceOracle
    string public constant name = "CorkOracleImpl";

    /// @notice The base asset (vbUSDC token).
    address public immutable base;

    /// @notice The quote asset (USD, ISO 4217 code 840).
    address public immutable quote;

    /// @notice Cork PoolManager contract.
    address public immutable CORK_POOL_MANAGER;

    /// @notice Cork pool ID (keccak256 of Market struct).
    bytes32 public immutable POOL_ID;

    /// @notice sUSDe token (Collateral Asset).
    address public immutable sUsdeToken;

    /// @notice Oracle for sUSDe/USD pricing. Set to the EulerRouter address.
    /// @dev EulerRouter resolves: sUSDe → USDe (via resolvedVault) → Chainlink → USD.
    address public immutable sUsdePriceOracle;

    /// @notice Pool impairment factor [0, 1] in 1e18 WAD. Set to 1e18 (no impairment) initially.
    /// @dev Governance can reduce this to zero if the pool is compromised (triggers liquidations).
    uint256 public hPool;

    /// @notice Address with authority to update hPool.
    address public governor;

    event HPoolUpdated(uint256 oldHPool, uint256 newHPool);
    event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);

    error NotGovernor();
    error InvalidHPool();

    constructor(
        address _corkPoolManager,
        bytes32 _poolId,
        address _base,
        address _quote,
        address _sUsdeToken,
        address _sUsdePriceOracle,
        uint256 _hPool,
        address _governor
    ) {
        require(_corkPoolManager != address(0), "CorkOracleImpl: zero pool manager");
        require(_base != address(0), "CorkOracleImpl: zero base");
        require(_sUsdeToken != address(0), "CorkOracleImpl: zero sUSDe token");
        require(_sUsdePriceOracle != address(0), "CorkOracleImpl: zero oracle");
        require(_quote != address(0), "CorkOracleImpl: zero quote");
        require(_hPool <= 1e18, "CorkOracleImpl: hPool > 1.0");
        require(_governor != address(0), "CorkOracleImpl: zero governor");

        CORK_POOL_MANAGER = _corkPoolManager;
        POOL_ID = _poolId;
        base = _base;
        quote = _quote;
        sUsdeToken = _sUsdeToken;
        sUsdePriceOracle = _sUsdePriceOracle;
        hPool = _hPool;
        governor = _governor;
    }

    /// @notice Prices vbUSDC in USD using Cork pool parameters.
    /// @param inAmount Native vbUSDC units (6 decimals, e.g. 100e6 for 100 vbUSDC).
    /// @return Native USD units (18 decimals, e.g. 94e18 for $94).
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        if (!(_base == base && _quote == quote)) {
            revert Errors.PriceOracle_NotSupported(_base, _quote);
        }
        if (inAmount == 0) return 0;

        uint256 swapRateWad = ICorkPoolManager(CORK_POOL_MANAGER).swapRate(POOL_ID);
        if (swapRateWad == 0) return 0;

        uint256 feeBps = ICorkPoolManager(CORK_POOL_MANAGER).swapFee(POOL_ID);
        uint256 sUsdeUsd = IPriceOracle(sUsdePriceOracle).getQuote(1e18, sUsdeToken, quote);

        uint256 caBackedUsd = swapRateWad * sUsdeUsd / 1e18;

        uint256 feeFractionWad = feeBps * 1e16 / 1e18;
        caBackedUsd = caBackedUsd * (1e18 - feeFractionWad) / 1e18;

        caBackedUsd = caBackedUsd * hPool / 1e18;

        uint256 navUsd = 1e18;
        uint256 effectiveUsdPerToken = navUsd < caBackedUsd ? navUsd : caBackedUsd;

        return inAmount * effectiveUsdPerToken / 1e6;
    }

    /// @notice Update the pool impairment factor hPool.
    /// @param _hPool New value in [0, 1e18]. Setting to 0 makes vbUSDC worthless → liquidation.
    function setHPool(uint256 _hPool) external {
        if (msg.sender != governor) revert NotGovernor();
        if (_hPool > 1e18) revert InvalidHPool();
        emit HPoolUpdated(hPool, _hPool);
        hPool = _hPool;
    }

    /// @notice Transfer governance.
    function transferGovernance(address newGovernor) external {
        if (msg.sender != governor) revert NotGovernor();
        require(newGovernor != address(0), "CorkOracleImpl: zero governor");
        emit GovernorTransferred(governor, newGovernor);
        governor = newGovernor;
    }
}
