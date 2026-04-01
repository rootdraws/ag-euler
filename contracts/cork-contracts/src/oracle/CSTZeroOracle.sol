// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "euler-price-oracle/adapter/BaseAdapter.sol";

/// @title CSTZeroOracle
/// @custom:security-contact security@euler.xyz
/// @author Alpha Growth (https://alphagrowth.fun/)
/// @notice PriceOracle adapter that always returns zero for cST/USD.
/// @dev Cork Swap Tokens (cST) have real market value (inverse of REF depeg risk) but are
///      priced at zero in Euler. Their value is captured by the vbUSDC oracle via
///      CorkCustomRiskManagerOracle, which uses cST presence as a coverage check.
///      Pricing cST at zero avoids double-counting. Cannot use FixedRateOracle because
///      its constructor reverts when rate == 0.
contract CSTZeroOracle is BaseAdapter {
    /// @inheritdoc IPriceOracle
    string public constant name = "CSTZeroOracle";

    /// @notice The address of the base asset (cST token).
    address public immutable base;

    /// @notice The address of the quote asset (USD, ISO 4217 code 840).
    address public immutable quote;

    /// @param _base The cST token address.
    /// @param _quote The USD address (0x0000000000000000000000000000000000000348).
    constructor(address _base, address _quote) {
        if (_base == address(0) || _quote == address(0)) revert Errors.PriceOracle_InvalidConfiguration();
        base = _base;
        quote = _quote;
    }

    /// @notice Always returns zero regardless of inAmount.
    /// @dev Both directions (base→quote and quote→base) return zero.
    function _getQuote(uint256, address _base, address _quote) internal view override returns (uint256) {
        if (!((_base == base && _quote == quote) || (_base == quote && _quote == base))) {
            revert Errors.PriceOracle_NotSupported(_base, _quote);
        }
        return 0;
    }
}
