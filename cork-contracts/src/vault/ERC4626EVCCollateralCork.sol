// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {ERC4626EVCCollateralCapped, ERC4626EVCCollateral, ERC4626EVC} from "evk-periphery/Vault/implementation/ERC4626EVCCollateralCapped.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @title ERC4626EVCCollateralCork
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs / Alpha Growth
/// @notice EVC-compatible collateral-only ERC4626 vault for Cork Protected Loop.
///
/// @dev Two instances are deployed: one for vbUSDC (REF, isRefVault=true) and one for cST (isRefVault=false).
///
/// @dev WITHDRAWAL PROTECTION (_withdraw override):
///      Replaces the external hook approach (ERC4626EVCCollateral does not expose setHookConfig).
///      Invariants enforced inline on every withdraw/redeem.
///
///      NOTE: transfer()/transferFrom() on vault shares bypass these overrides (OZ ERC20 goes
///      through _update, not _withdraw). The EVC account status check (health factor via oracle)
///      is the protection for that path. If a transfer reduces cST below the 1:1 pairing, the
///      oracle prices less REF, collateral value drops, and the EVC reverts if the position
///      becomes unhealthy. For accounts with sufficient margin, a cosmetic pairing break is
///      possible but economically handled by the oracle.
///
///      cST vault (isRefVault=false):
///        If the owner has any sUSDe debt -> revert. cST cannot be removed while borrowing.
///
///      vbUSDC vault (isRefVault=true):
///        If the owner has sUSDe debt -> require pairedVault (cST vault) balance > 0.
///        Partial vbUSDC withdrawal is allowed as long as cST coverage exists.
///        If pairedVault is not yet configured (address(0)), the check is skipped.
///        Governor must call setPairedVault() after both vaults are deployed.
contract ERC4626EVCCollateralCork is ERC4626EVCCollateralCapped {
    /// @notice The sUSDe borrow vault. Used for debtOf() checks in _withdraw/_deposit.
    address public immutable borrowVault;

    /// @notice True for the vbUSDC (REF) vault, false for the cST vault.
    bool public immutable isRefVault;

    /// @notice The paired collateral vault. Both vaults must have this set after deployment.
    ///         For vbUSDC vault: set to the cST vault (used by _withdraw and _deposit to check cST coverage).
    ///         For cST vault: set to the vbUSDC vault (used by _withdraw no-debt case to check remaining REF).
    address public pairedVault;

    error HasDebt();
    error NoPairedCoverage();
    error WithdrawalBreaksPairing();
    error DepositWouldBreakPairing();

    event PairedVaultSet(address indexed pairedVault);

    /// @param evc The EVC address.
    /// @param permit2 The Permit2 contract address.
    /// @param admin The governor admin address.
    /// @param _borrowVault The sUSDe borrow vault address (deployed first, passed here).
    /// @param asset The underlying token (vbUSDC or cST).
    /// @param _name The vault share token name.
    /// @param _symbol The vault share token symbol.
    /// @param _isRefVault True for the vbUSDC vault, false for the cST vault.
    constructor(
        address evc,
        address permit2,
        address admin,
        address _borrowVault,
        address asset,
        string memory _name,
        string memory _symbol,
        bool _isRefVault
    ) ERC4626EVC(evc, permit2, asset, _name, _symbol) ERC4626EVCCollateralCapped(admin) {
        borrowVault = _borrowVault;
        isRefVault = _isRefVault;
    }

    /// @notice Set the paired vault address (governor only, called after both vaults are deployed).
    function setPairedVault(address _pairedVault) external onlyEVCAccountOwner governorOnly {
        pairedVault = _pairedVault;
        emit PairedVaultSet(_pairedVault);
    }

    /// @notice Enforces Cork pairing invariants on every withdraw and redeem.
    /// @dev Called by both withdraw() and redeem() in the ERC4626 base.
    ///      `owner` is the account whose shares are burned (the collateral holder).
    ///
    ///      Spec (cork-euler.md Section 3.2):
    ///        - cST withdrawals forbidden while debt exists.
    ///        - REF withdrawals forbidden if they would break REF=cST pairing.
    ///        - Without debt: both may be withdrawn, but must not break pairing.
    ///
    ///      Pairing invariant: cST_shares >= REF_shares * 1e12 (1:1 token parity, 18 dec vs 6 dec).
    ///      A full exit (REF -> 0) is always permitted since 0 REF needs 0 cST coverage.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        if (!isRefVault) {
            if (IEVault(borrowVault).debtOf(owner) > 0) revert HasDebt();

            if (pairedVault != address(0)) {
                uint256 cstSharesAfter = super.balanceOf(owner) - shares;
                uint256 refShares = _balanceOf(pairedVault, owner);
                if (cstSharesAfter < refShares * 1e12) revert WithdrawalBreaksPairing();
            }
        } else {
            if (pairedVault != address(0)) {
                uint256 refSharesAfter = super.balanceOf(owner) - shares;
                if (refSharesAfter > 0 && _balanceOf(pairedVault, owner) < refSharesAfter * 1e12) {
                    revert NoPairedCoverage();
                }
            }
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Enforces Cork deposit invariants on the REF vault.
    /// @dev When the depositor already has sUSDe debt, a REF deposit must not push REF above cST
    ///      coverage (would create uncovered collateral with no atomic liquidation path).
    ///      cST vault deposits are never restricted — more cST always improves coverage.
    ///      `receiver` is the EVC account that receives the shares (who holds the debt).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        if (isRefVault && pairedVault != address(0)) {
            if (IEVault(borrowVault).debtOf(receiver) > 0) {
                uint256 cstShares = _balanceOf(pairedVault, receiver);
                uint256 refSharesAfter = super.balanceOf(receiver) + shares;
                if (cstShares < refSharesAfter * 1e12) revert DepositWouldBreakPairing();
            }
        }
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Read the share balance of `account` from another vault via staticcall.
    function _balanceOf(address vault, address account) private view returns (uint256 bal) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeCall(this.balanceOf, (account)));
        if (ok && data.length == 32) bal = abi.decode(data, (uint256));
    }

    /// @dev No per-address-prefix cache needed for this simple collateral vault.
    function _updateCache() internal virtual override {}
}
