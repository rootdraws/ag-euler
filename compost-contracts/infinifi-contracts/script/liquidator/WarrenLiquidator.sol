// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IEVC} from "./interfaces/IEVC.sol";
import {IEVault} from "./interfaces/IEVault.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title WarrenLiquidator v4
/// @notice No flash loan needed - debt created and repaid atomically via Euler Swapper
contract WarrenLiquidator {
    address public constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address public constant EULER_SWAPPER = 0x2Bba09866b6F1025258542478C39720A09B728bF;
    
    address public owner;

    struct LiquidationParams {
        address violator;
        address collateralVault;
        address liabilityVault;
        uint256 maxRepay;
        uint256 maxYield;
        bytes swapperData;  // multicall calldata for Euler Swapper
    }

    error NotOwner();
    error LiquidationFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Execute liquidation - no flash loan, atomic debt pattern
    function liquidate(LiquidationParams calldata params) external onlyOwner {
        IEVC evc = IEVC(EVC);
        
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](7);
        
        // Step 1: Enable controller (liability vault controls our account)
        items[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), params.liabilityVault))
        });
        
        // Step 2: Enable collateral vault as collateral
        items[1] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (address(this), params.collateralVault))
        });
        
        // Step 3: Liquidate - creates our debt, gives us collateral shares
        items[2] = IEVC.BatchItem({
            targetContract: params.liabilityVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEVault.liquidate, (
                params.violator,
                params.collateralVault,
                params.maxRepay,
                0
            ))
        });
        
        // Step 4: Redeem collateral shares → tokens go directly to Euler Swapper
        items[3] = IEVC.BatchItem({
            targetContract: params.collateralVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEVault.redeem, (
                params.maxYield,
                EULER_SWAPPER,  // tokens go to swapper
                address(this)
            ))
        });
        
        // Step 5: Swapper multicall - swaps collateral → liability, repays our debt
        items[4] = IEVC.BatchItem({
            targetContract: EULER_SWAPPER,
            onBehalfOfAccount: address(this),
            value: 0,
            data: params.swapperData  // Already encoded multicall
        });
        
        // Step 6: Disable controller
        items[5] = IEVC.BatchItem({
            targetContract: params.liabilityVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEVault.disableController, ())
        });
        
        // Step 7: Disable collateral
        items[6] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.disableCollateral, (address(this), params.collateralVault))
        });
        
        // Execute atomic batch
        evc.batch(items);
        
        // Sweep any leftover collateral shares to owner
        uint256 remaining = IERC20(params.collateralVault).balanceOf(address(this));
        if (remaining > 0) {
            IERC20(params.collateralVault).transfer(owner, remaining);
        }
    }

    /// @notice Rescue stuck tokens
    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }
}
