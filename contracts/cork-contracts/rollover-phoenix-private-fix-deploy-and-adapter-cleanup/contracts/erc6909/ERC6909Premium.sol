// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";

/// @title ERC6909Premium
/// @notice Ownerless, immutable, no-pause prepaid-balance ledger keyed by
///         `tokenId = uint256(uint160(premiumToken))`. Fillers deposit up-front; the rollover
///         settler debits via `settle()` under a dual-authorization model (RFC 003 §A.5).
/// @dev Interface NatSpec on `IERC6909Premium` is authoritative for function semantics.
contract ERC6909Premium is IERC6909Premium, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev EIP-6909 interface id (per EIP-6909 specification).
    bytes4 private constant _ERC6909_INTERFACE_ID = 0x0f632fb3;

    /// @dev EIP-165 interface id.
    bytes4 private constant _ERC165_INTERFACE_ID = 0x01ffc9a7;

    // owner => tokenId => credited balance
    mapping(address account => mapping(uint256 tokenId => uint256 balance)) internal _balances;

    // owner => operator => approved
    mapping(address owner => mapping(address operator => bool approved)) internal _operators;

    // ─── External entry points ──────────────────────────────────────────────────────────────

    /// @inheritdoc IERC6909Premium
    function deposit(address token, address to, uint256 amount) external {
        if (to == address(0)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            return;
        }
        uint256 tokenId = uint256(uint160(token));
        // A4: measure the post-transfer delta to fail closed on FoT / rebasing tokens. RFC 003 §6.6
        // declares these unsupported; without this check the credited balance would exceed the
        // escrowed ERC-20, locking other depositors' funds.
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received != amount) {
            revert DepositBalanceMismatch(amount, received);
        }
        _balances[to][tokenId] += amount;
        emit Transfer(msg.sender, address(0), to, tokenId, amount);
    }

    /// @inheritdoc IERC6909Premium
    function withdraw(uint256 tokenId, address to, uint256 amount) external nonReentrant {
        if (to == address(0)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            return;
        }
        uint256 balance = _balances[msg.sender][tokenId];
        if (balance < amount) {
            revert InsufficientBalance();
        }
        // CEI: decrement before external call. On transfer revert the whole transaction rolls
        // back so the net effect on `_balances` is zero — satisfies the tree spec's "leave
        // balance unchanged on revert" requirement.
        _balances[msg.sender][tokenId] = balance - amount;
        IERC20(address(uint160(tokenId))).safeTransfer(to, amount);
        emit Transfer(msg.sender, msg.sender, address(0), tokenId, amount);
    }

    /// @inheritdoc IERC6909Premium
    function settle(address debitFrom, address premiumFiller, uint256 tokenId, uint256 amount, address recipient)
        external
        nonReentrant
    {
        if (!_isAuthorized(debitFrom, msg.sender)) {
            revert UnauthorizedSettler();
        }
        if (!_isAuthorized(debitFrom, premiumFiller)) {
            revert UnauthorizedPremiumFiller();
        }
        // INV-S10: zero-amount settle is a no-op that still emits `Settled` so off-chain ledgers
        // record the settler's ack. No balance mutation, no ERC-20 transfer.
        if (amount == 0) {
            emit Settled(debitFrom, premiumFiller, tokenId, 0, recipient);
            return;
        }
        uint256 balance = _balances[debitFrom][tokenId];
        if (balance < amount) {
            revert InsufficientBalance();
        }
        _balances[debitFrom][tokenId] = balance - amount;
        emit Transfer(msg.sender, debitFrom, address(0), tokenId, amount);
        // Symmetric with `deposit`'s A4 fail-closed check. RFC 003 §6.6 declares FoT / rebasing
        // tokens unsupported; without this check the debit would land in full but the recipient
        // would receive strictly less than `amount`, stranding the difference on the escrow and
        // silently under-paying the UW. Revert rolls back the balance decrement above.
        IERC20 token = IERC20(address(uint160(tokenId)));
        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 received = token.balanceOf(recipient) - recipientBefore;
        if (received != amount) {
            revert SettleBalanceMismatch(amount, received);
        }
        emit Settled(debitFrom, premiumFiller, tokenId, amount, recipient);
    }

    /// @inheritdoc IERC6909Premium
    function setOperator(address operator, bool approved) external {
        _operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    // ─── Views ──────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC6909Premium
    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return _balances[account][tokenId];
    }

    /// @inheritdoc IERC6909Premium
    function isOperator(address account, address operator) external view returns (bool) {
        return _operators[account][operator];
    }

    /// @inheritdoc IERC6909Premium
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC6909Premium).interfaceId || interfaceId == _ERC6909_INTERFACE_ID
            || interfaceId == _ERC165_INTERFACE_ID;
    }

    // ─── Internal helpers ──────────────────────────────────────────────────────────────────

    /// @dev An address is authorized to act on `owner`'s behalf iff it IS `owner` or a registered
    ///      ERC-6909 operator. Used by `settle`'s dual-auth check (INV-E2).
    function _isAuthorized(address owner, address caller) internal view returns (bool) {
        return caller == owner || _operators[owner][caller];
    }
}
