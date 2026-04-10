// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

interface IEVault {
    function checkLiquidation(address liquidator, address borrower, address collateral) 
        external view returns (uint256 maxRepay, uint256 maxYield);
    function asset() external view returns (address);
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function disableController() external;
    function convertToAssets(uint256 shares) external view returns (uint256);
}
