// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {BaseHookTarget} from "evk-periphery/HookTarget/BaseHookTarget.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

/// @title ProtectedLoopHook
/// @custom:security-contact security@euler.xyz
/// @author Alpha Growth (https://alphagrowth.fun/)
/// @notice Enforces vbUSDC + cST pairing invariants for Cork Protected Loop vaults.
///
/// @dev Hook mechanics (from EVault Base.sol invokeHookTarget):
///      The vault appends the original caller address as 20 bytes to msg.data and calls
///      the hook target. BaseHookTarget._msgSender() extracts this caller from calldata.
///      If the hook reverts, the vault operation is blocked.
///      Hooks fire BEFORE the operation executes, so balanceOf reflects pre-op state.
///
/// @dev This hook is attached ONLY to the sUSDe borrow vault (hookedOps = OP_BORROW = 64).
///      Collateral vault withdraw/deposit protections are handled by _withdraw/_deposit overrides
///      in ERC4626EVCCollateralCork, not by this hook.
///
/// @dev Invariant enforced (on borrow):
///      - Account must have vbUSDC vault shares > 0
///      - Account must have cST vault shares > 0
///      - cST shares must be >= vbUSDC shares normalized (cstShares >= refShares * 1e12)
///        i.e., for every 1 vbUSDC (6 dec, 1e6 units), must have >= 1 cST (18 dec, 1e18 units)
///      - cST must not be expired
contract ProtectedLoopHook is BaseHookTarget {
    /// @notice The EVC address, used to verify EVC context if needed.
    address public immutable evc;

    /// @notice The vbUSDC ERC4626EVCCollateralCork vault address.
    address public immutable refVault;

    /// @notice The cST ERC4626EVCCollateralCork vault address.
    address public immutable cstVault;

    /// @notice The sUSDe borrow vault address (standard EVK).
    address public immutable borrowVault;

    /// @notice The raw cST token address (for expiry check).
    address public immutable cstToken;

    /// @notice Unix timestamp when cST expires. After this, borrowing is blocked.
    uint256 public immutable cstExpiry;

    error NoREFCollateral();
    error NoCSTCollateral();
    error REFCSTMismatch();
    error CSTExpired();

    /// @param _eVaultFactory The EVault factory (for BaseHookTarget.isProxy check).
    /// @param _evc The EVC address.
    /// @param _refVault The vbUSDC collateral vault.
    /// @param _cstVault The cST collateral vault.
    /// @param _borrowVault The sUSDe borrow vault.
    /// @param _cstToken The raw cST token.
    /// @param _cstExpiry Unix timestamp of cST expiry (1776686400 = April 19, 2026).
    constructor(
        address _eVaultFactory,
        address _evc,
        address _refVault,
        address _cstVault,
        address _borrowVault,
        address _cstToken,
        uint256 _cstExpiry
    ) BaseHookTarget(_eVaultFactory) {
        evc = _evc;
        refVault = _refVault;
        cstVault = _cstVault;
        borrowVault = _borrowVault;
        cstToken = _cstToken;
        cstExpiry = _cstExpiry;
    }

    /// @notice Hook entrypoint. Checks borrow invariant when called by the sUSDe borrow vault.
    /// @dev Receives original vault calldata + 20-byte caller appended by invokeHookTarget.
    ///      msg.sender = the vault that called the hook.
    ///      _msgSender() = the original caller of the vault operation.
    fallback() external {
        if (msg.sender == borrowVault) {
            _checkBorrow(_msgSender());
        }
    }

    /// @notice Invariant A: borrow is allowed only when vbUSDC and cST are properly paired.
    function _checkBorrow(address account) internal view {
        uint256 refShares = IERC4626(refVault).balanceOf(account);
        uint256 cstShares = IERC4626(cstVault).balanceOf(account);

        if (refShares == 0) revert NoREFCollateral();
        if (cstShares == 0) revert NoCSTCollateral();

        // Normalize: vbUSDC is 6 decimals, cST is 18 decimals. For 1:1 token pairing:
        // require cstShares (18-dec units) >= refShares (6-dec units) * 1e12
        // i.e., cST tokens (amount/1e18) >= vbUSDC tokens (amount/1e6)
        if (!_normalizedEqual(refShares, cstShares)) revert REFCSTMismatch();

        if (block.timestamp >= cstExpiry) revert CSTExpired();
    }

    /// @notice Checks if cST shares cover vbUSDC shares 1:1 after decimal normalization.
    /// @param refShares vbUSDC vault shares (underlying: 6 decimals).
    /// @param cstShares cST vault shares (underlying: 18 decimals).
    /// @return True if cST token amount >= vbUSDC token amount.
    function _normalizedEqual(uint256 refShares, uint256 cstShares) internal pure returns (bool) {
        // 1e12 = 1e18 / 1e6 = decimal normalization factor between cST (18 dec) and vbUSDC (6 dec)
        return cstShares >= refShares * 1e12;
    }
}
