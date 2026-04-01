// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {CustomLiquidatorBase} from "evk-periphery/Liquidator/CustomLiquidatorBase.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @notice Minimal interface for Cork PoolManager exercise functions.
/// @dev All functions on CorkPoolManager are whitelisted — the liquidator contract address
///      must be added to the Cork pool whitelist by Cork governance before deployment.
///      WhitelistManager.addToMarketWhitelist(poolId, address(liquidator)) must be called.
interface ICorkPoolManagerLiquidator {
    /// @notice Exercise cST shares to receive sUSDe. Locks cST + corresponding vbUSDC.
    /// @param poolId The Cork pool identifier.
    /// @param cstSharesIn Amount of cST shares to exercise.
    /// @param receiver Address to receive the sUSDe output.
    /// @return collateralAssetsOut sUSDe received.
    /// @return referenceAssetsIn vbUSDC consumed.
    /// @return fee Fee charged in sUSDe.
    function exercise(bytes32 poolId, uint256 cstSharesIn, address receiver)
        external
        returns (uint256 collateralAssetsOut, uint256 referenceAssetsIn, uint256 fee);

    /// @notice Preview how much sUSDe is returned and vbUSDC consumed for a given cST amount.
    function previewExercise(bytes32 poolId, uint256 cstSharesIn)
        external
        view
        returns (uint256 collateralAssetsOut, uint256 referenceAssetsIn, uint256 fee);
}

/// @title CorkProtectedLoopLiquidator
/// @custom:security-contact security@euler.xyz
/// @author Alpha Growth (https://alphagrowth.fun/)
/// @notice Liquidates Cork Protected Loop positions on Euler.
///
/// @dev Liquidation flow (all within a single EVC batch):
///      1. Account falls below LLTV (85% for vbUSDC/sUSDe).
///      2. Outer caller calls liquidate(receiver, sUsdeVault, violator, vbUSDCVault, repay, minYield).
///      3. _customLiquidation seizes cST vault shares first via EVK liquidate(). Because cST
///         is priced at zero (CSTZeroOracle), EVK's "worthless collateral" path
///         (Liquidation.sol L155-163) seizes ALL cST shares with zero debt repay.
///         ORDER MATTERS: cST must be seized while the violator still has non-zero liability,
///         otherwise EVK returns early (liability == 0 → no-op).
///      4. _customLiquidation seizes vbUSDC vault shares via standard EVK liquidate() with
///         price-based discount. This transfers debt from violator to this contract.
///      5. Pulls debt to the calling operator via pullDebt.
///      6. Redeems both vault share positions for underlying tokens (vbUSDC + cST).
///      7. Approves tokens to CorkPoolManager and calls exercise() → receives sUSDe.
///      8. Transfers all sUSDe and leftover vbUSDC to receiver.
///
/// @dev Debt repayment is the caller's responsibility within the EVC batch.
///      After _customLiquidation returns, the bot must repay the liability vault
///      using the sUSDe transferred to `receiver`. See SBLiquidator for the pattern.
///
/// @dev Prerequisites:
///      - Liquidator contract must be whitelisted on the Cork pool (Cork governance action).
///      - Caller (liquidator bot) must approve this contract as an EVC operator.
///      - cST must be a recognized collateral on the liability vault (setLTV called, even
///        with LTV=0), so that EVK's isRecognizedCollateral check passes.
///
/// @dev Call this contract's liquidate() with collateral = vbUSDCVault. The cST vault
///      liquidation is handled internally within _customLiquidation.
contract CorkProtectedLoopLiquidator is CustomLiquidatorBase {
    using SafeERC20 for IERC20;

    /// @notice The CorkPoolManager contract (whitelist-gated).
    address public immutable corkPoolManager;

    /// @notice The Cork pool ID.
    bytes32 public immutable poolId;

    /// @notice The vbUSDC ERC4626EVCCollateralCork vault.
    address public immutable refVault;

    /// @notice The cST ERC4626EVCCollateralCork vault.
    address public immutable cstVault;

    /// @notice The raw vbUSDC token.
    address public immutable vbUSDC;

    /// @notice The raw cST token.
    address public immutable cstToken;

    /// @notice The raw sUSDe token.
    address public immutable sUsdeToken;

    constructor(
        address evc,
        address owner,
        address _corkPoolManager,
        bytes32 _poolId,
        address _refVault,
        address _cstVault,
        address _vbUSDC,
        address _cstToken,
        address _sUsdeToken
    ) CustomLiquidatorBase(evc, owner, _buildCustomVaults(_refVault, _cstVault)) {
        corkPoolManager = _corkPoolManager;
        poolId = _poolId;
        refVault = _refVault;
        cstVault = _cstVault;
        vbUSDC = _vbUSDC;
        cstToken = _cstToken;
        sUsdeToken = _sUsdeToken;
    }

    /// @dev Helper to build the customLiquidationVaults array for the base constructor.
    function _buildCustomVaults(address _refVault, address _cstVault)
        private
        pure
        returns (address[] memory vaults)
    {
        vaults = new address[](2);
        vaults[0] = _refVault;
        vaults[1] = _cstVault;
    }

    error LiquidateViaRefVaultOnly();

    /// @notice Execute Cork-specific liquidation: seize both collaterals, exercise, send proceeds.
    /// @dev Called when collateral == refVault (vbUSDCVault). Also seizes cST internally.
    ///      Must be called with collateral = refVault; cST seizure is handled inside this function.
    function _customLiquidation(
        address receiver,
        address liability,
        address violator,
        address collateral,
        uint256 repayAssets,
        uint256 minYieldBalance
    ) internal override {
        if (collateral != refVault) revert LiquidateViaRefVaultOnly();

        uint256 refSharesSeized;
        uint256 cstSharesSeized;

        // Phase A: Seize collaterals.
        //
        // cST MUST be seized before vbUSDC. EVK's Liquidation.sol has an early return:
        //   if (liqCache.liability.isZero()) return liqCache;   // L101
        // If vbUSDC is seized first with full repayAssets, the violator's debt drops to zero
        // and the subsequent cST liquidation becomes a no-op. By seizing cST first (while
        // the violator still has full liability), EVK's worthless-collateral path activates:
        //   if (collateralValue == 0) {                         // L155
        //       liqCache.yieldBalance = collateralBalance;      // L162: seize ALL
        //       return liqCache;                                // L163: repay stays 0
        //   }
        // The sUSDe vault (the violator's controller) executes controlCollateral internally,
        // so no authorization issue — only the controller can seize, and it does.
        {
            // A.1: Seize ALL cST for free (zero-priced → worthless collateral claim, zero debt transfer).
            uint256 cstBefore = IEVault(cstVault).balanceOf(address(this));
            IEVault(liability).liquidate(violator, cstVault, type(uint256).max, 0);
            cstSharesSeized = IEVault(cstVault).balanceOf(address(this)) - cstBefore;

            // A.2: Seize vbUSDC via standard price-based EVK liquidation (transfers debt).
            uint256 refBefore = IEVault(refVault).balanceOf(address(this));
            IEVault(liability).liquidate(violator, refVault, repayAssets, minYieldBalance);
            refSharesSeized = IEVault(refVault).balanceOf(address(this)) - refBefore;
        }

        // Phase B: Pull debt to the calling operator.
        evc.call(
            liability,
            _msgSender(),
            0,
            abi.encodeCall(IEVault(liability).pullDebt, (type(uint256).max, address(this)))
        );

        // Phase C: Redeem shares, exercise in Cork pool, send all proceeds to receiver.
        //
        // We seize ALL cST (free claim) but only partial vbUSDC (proportional to the
        // liquidation discount). Cork's exercise() consumes both cST and vbUSDC at the
        // pool's swapRate — if we try to exercise more cST than our vbUSDC can cover,
        // it reverts. Use previewExercise to cap the cST exercise amount.
        {
            uint256 vbUSDCAmount = IEVault(refVault).redeem(refSharesSeized, address(this), address(this));
            uint256 cstAmount = IEVault(cstVault).redeem(cstSharesSeized, address(this), address(this));

            IERC20(vbUSDC).approve(corkPoolManager, type(uint256).max);
            IERC20(cstToken).approve(corkPoolManager, type(uint256).max);

            uint256 cstToExercise = cstAmount;
            if (cstAmount > 0) {
                (, uint256 vbUsdcNeeded,) =
                    ICorkPoolManagerLiquidator(corkPoolManager).previewExercise(poolId, cstAmount);

                if (vbUsdcNeeded > vbUSDCAmount) {
                    cstToExercise = cstAmount * vbUSDCAmount / vbUsdcNeeded;
                }

                if (cstToExercise > 0) {
                    ICorkPoolManagerLiquidator(corkPoolManager).exercise(poolId, cstToExercise, address(this));
                }
            }
        }

        // Transfer all remaining tokens to receiver. The calling bot is responsible for
        // repaying debt in the same EVC batch using the sUSDe proceeds.
        {
            uint256 sUsdeBal = IERC20(sUsdeToken).balanceOf(address(this));
            if (sUsdeBal > 0) IERC20(sUsdeToken).safeTransfer(receiver, sUsdeBal);

            uint256 vbUsdcLeft = IERC20(vbUSDC).balanceOf(address(this));
            if (vbUsdcLeft > 0) IERC20(vbUSDC).safeTransfer(receiver, vbUsdcLeft);

            uint256 cstLeft = IERC20(cstToken).balanceOf(address(this));
            if (cstLeft > 0) IERC20(cstToken).safeTransfer(receiver, cstLeft);

            IERC20(vbUSDC).approve(corkPoolManager, 0);
            IERC20(cstToken).approve(corkPoolManager, 0);
        }
    }
}
