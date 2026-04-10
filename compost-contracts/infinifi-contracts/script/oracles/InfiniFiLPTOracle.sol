// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "euler-price-oracle/adapter/BaseAdapter.sol";
import {ScaleUtils, Scale} from "euler-price-oracle/lib/ScaleUtils.sol";

interface ILockingController {
    function exchangeRate(uint32 unwindingEpochs) external view returns (uint256);
}

interface IAccounting {
    function price(address asset) external view returns (uint256);
}

/// @title InfiniFiLPTOracle
/// @notice Euler PriceOracle adapter for InfiniFi Locked Position Tokens
/// @dev Returns LPT price in USD by combining exchange rate with iUSD price
contract InfiniFiLPTOracle is BaseAdapter {
    /// @inheritdoc IPriceOracle
    string public constant name = "InfiniFiLPTOracle";

    /// @notice The LPT token address (base)
    address public immutable base;

    /// @notice The USD unit of account (quote)
    address public immutable quote;

    /// @notice The iUSD token address
    address public immutable iUSD;

    /// @notice The LockingController address
    ILockingController public immutable lockingController;

    /// @notice The Accounting address
    IAccounting public immutable accounting;

    /// @notice The bucket (unwinding epochs) this oracle prices
    uint32 public immutable unwindingEpochs;

    /// @notice The scale factors used for decimal conversions
    Scale internal immutable scale;

    /// @notice Deploy an InfiniFiLPTOracle
    /// @param _base The LPT token address
    /// @param _quote The USD unit of account address
    /// @param _iUSD The iUSD token address
    /// @param _lockingController The LockingController address
    /// @param _accounting The Accounting address
    /// @param _unwindingEpochs The bucket (1-13 weeks)
    constructor(
        address _base,
        address _quote,
        address _iUSD,
        address _lockingController,
        address _accounting,
        uint32 _unwindingEpochs
    ) {
        base = _base;
        quote = _quote;
        iUSD = _iUSD;
        lockingController = ILockingController(_lockingController);
        accounting = IAccounting(_accounting);
        unwindingEpochs = _unwindingEpochs;

        uint8 baseDecimals = _getDecimals(_base);
        uint8 quoteDecimals = _getDecimals(_quote);
        scale = ScaleUtils.calcScale(baseDecimals, quoteDecimals, 18);
    }

    /// @notice Get a quote by fetching exchange rate and iUSD price
    /// @param inAmount The amount of `base` to convert
    /// @param _base The token that is being priced
    /// @param _quote The token that is the unit of account
    /// @return The converted amount in USD
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        // Get LPT -> iUSD exchange rate (18 decimals)
        uint256 exchangeRate = lockingController.exchangeRate(unwindingEpochs);
        if (exchangeRate == 0) revert Errors.PriceOracle_InvalidConfiguration();

        // Get iUSD -> USD price (18 decimals)
        uint256 iUSDPrice = accounting.price(iUSD);
        if (iUSDPrice == 0) revert Errors.PriceOracle_InvalidConfiguration();

        // Combined rate: LPT -> USD (18 decimals)
        uint256 rate = (exchangeRate * iUSDPrice) / 1e18;

        return ScaleUtils.calcOutAmount(inAmount, rate, scale, inverse);
    }
}