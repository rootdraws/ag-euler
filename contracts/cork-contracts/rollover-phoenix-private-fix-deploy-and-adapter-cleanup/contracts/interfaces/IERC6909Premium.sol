// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IERC6909Premium
/// @notice Filler prepaid-balance contract. Fillers deposit ERC-20 premium tokens ahead of time,
///         then the rollover settler debits the exact `requiredPremium` via `settle()` when both
///         legs of an order are filled. Token IDs are deterministic: `uint256(uint160(token))`.
/// @dev The premium token never enters the settler. Separation of escrow (`ERC6909Premium`) from
///      fill coordination (`Settler`) eliminates AS-10 (locked-premium deadlock, RFC 003 §1).
///      Ownerless, immutable, no pause. `settle()` is dual-authorized: both `msg.sender` and
///      `premiumFiller` must be authorized by `debitFrom` (INV-E2).
interface IERC6909Premium {
    /// @notice Emitted on every successful `settle()`. Off-chain infra uses this event as the
    ///         canonical ledger of premium payments.
    /// @param debitFrom The account whose ERC-6909 balance was debited.
    /// @param premiumFiller The filler that committed the premium leg on the settler.
    /// @param tokenId The ERC-6909 token ID (= `uint256(uint160(premiumToken))`).
    /// @param amount The amount debited and transferred.
    /// @param recipient The recipient of the underlying ERC-20 transfer (the UW's cellar).
    event Settled(
        address indexed debitFrom,
        address indexed premiumFiller,
        uint256 indexed tokenId,
        uint256 amount,
        address recipient
    );

    /// @notice ERC-6909 standard balance-movement event (EIP-6909). Emitted on `deposit`
    ///         (`from == address(0)` — mint), `withdraw` (`to == address(0)` — burn), and any
    ///         internal balance movement caused by `settle` via the ledger (`settle` separately
    ///         emits `Settled`; internal transfers that shift credit between addresses are not
    ///         performed by this contract today but the event stays standards-compliant for any
    ///         future owner-to-owner move).
    /// @param caller `msg.sender` of the operation that triggered the balance change.
    /// @param from Source of the ERC-6909 credit (zero on mint / deposit).
    /// @param to Destination of the ERC-6909 credit (zero on burn / withdraw).
    /// @param id ERC-6909 token ID.
    /// @param amount Amount moved.
    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    /// @notice ERC-6909 standard operator-toggle event (EIP-6909). Emitted by `setOperator` on
    ///         every call — idempotent writes still emit, per the EIP.
    /// @param owner Balance owner that is granting or revoking operator status.
    /// @param operator Operator address whose authorization changed.
    /// @param approved True if the operator was granted authorization, false if revoked.
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    /// @notice `msg.sender` is not authorized to debit `debitFrom` (not `debitFrom` itself and not
    ///         a registered operator). Dual-auth check, first leg.
    error UnauthorizedSettler();

    /// @notice `premiumFiller` is not authorized by `debitFrom`. Dual-auth check, second leg —
    ///         INV-E2.
    error UnauthorizedPremiumFiller();

    /// @notice Requested debit exceeds `balances[debitFrom][tokenId]`.
    error InsufficientBalance();

    /// @notice `withdraw` was called with `to == address(0)`. Guards against accidentally burning
    ///         the underlying ERC-20 via a zero-address transfer — `withdraw` must name a real
    ///         recipient (the ERC-6909 burn is implicit in the balance decrement).
    error InvalidRecipient();

    /// @notice `deposit` observed a post-transfer balance delta that did not match the requested
    ///         `amount`. Fee-on-transfer / rebasing tokens are unsupported (RFC 003 §6.6) and would
    ///         otherwise silently lock credits against a smaller escrowed balance. Fails closed.
    /// @param expected The nominal `amount` passed to `deposit`.
    /// @param actual The actual balance delta observed on the escrow.
    error DepositBalanceMismatch(uint256 expected, uint256 actual);

    /// @notice `settle` observed a post-transfer `recipient` balance delta that did not match the
    ///         requested `amount`. Mirrors `DepositBalanceMismatch` on the payout leg — fee-on-
    ///         transfer / rebasing tokens are unsupported (RFC 003 §6.6); without this check the
    ///         debit would land in full but the cellar would receive strictly less than `amount`,
    ///         leaving the difference stranded on the escrow and silently under-paying the UW.
    ///         Fails closed.
    /// @param expected The nominal `amount` passed to `settle`.
    /// @param received The actual balance delta observed at `recipient`.
    error SettleBalanceMismatch(uint256 expected, uint256 received);

    /// @notice Pulls `amount` of `token` from `msg.sender` and credits it to
    ///         `balances[to][uint256(uint160(token))]`.
    /// @dev Uses `SafeERC20.safeTransferFrom`. Fee-on-transfer / rebasing tokens are not supported
    ///      (RFC 003 §6.6); the credited balance equals the nominal `amount`. A post-transfer
    ///      balance-delta check reverts with `DepositBalanceMismatch` when the received delta
    ///      differs from `amount`, failing closed instead of silently locking credits.
    /// @param token ERC-20 token to deposit.
    /// @param to Recipient of the ERC-6909 credit.
    /// @param amount Token amount.
    function deposit(address token, address to, uint256 amount) external;

    /// @notice Debits `amount` from `balances[msg.sender][tokenId]` and transfers the underlying
    ///         ERC-20 to `to`.
    /// @dev Reverts with `InsufficientBalance` if the caller's balance is below `amount`.
    /// @param tokenId ERC-6909 token ID (= `uint256(uint160(token))`).
    /// @param to Recipient of the underlying ERC-20.
    /// @param amount Token amount.
    function withdraw(uint256 tokenId, address to, uint256 amount) external;

    /// @notice Settler-only entry: debits `debitFrom`'s ERC-6909 balance and transfers the
    ///         underlying ERC-20 to `recipient` (the UW's cellar).
    /// @dev Dual-authorization (INV-E2): `msg.sender` AND `premiumFiller` must each be
    ///      authorized by `debitFrom` (either `== debitFrom` or a registered operator).
    ///      `amount == 0` short-circuits with no state change (INV-S10). Reentrancy-guarded so
    ///      that tokens with recipient-callback hooks cannot re-enter during the post-transfer
    ///      window. A post-transfer balance-delta check on `recipient` reverts with
    ///      `SettleBalanceMismatch` when the received delta differs from `amount`, failing
    ///      closed on FoT / rebasing tokens (§6.6 — unsupported). Emits `Settled`. RFC 003 §A.5.
    /// @param debitFrom Whose ERC-6909 balance to debit.
    /// @param premiumFiller Filler that committed the premium leg on the settler.
    /// @param tokenId ERC-6909 token ID.
    /// @param amount Amount to debit and transfer.
    /// @param recipient ERC-20 recipient.
    function settle(address debitFrom, address premiumFiller, uint256 tokenId, uint256 amount, address recipient)
        external;

    /// @notice Standard ERC-6909 operator toggle. `operator` may debit `msg.sender`'s balance for
    ///         any `tokenId` while `approved == true`.
    /// @param operator Operator address.
    /// @param approved True to grant, false to revoke.
    function setOperator(address operator, bool approved) external;

    /// @notice Returns the credited balance for `(account, tokenId)`.
    /// @param account Balance owner.
    /// @param tokenId ERC-6909 token ID.
    /// @return amount Credited balance.
    function balanceOf(address account, uint256 tokenId) external view returns (uint256 amount);

    /// @notice Returns whether `operator` is authorized by `account` (ERC-6909 standard).
    /// @param account Balance owner.
    /// @param operator Operator address.
    /// @return approved True iff `operator` was granted authorization.
    function isOperator(address account, address operator) external view returns (bool approved);

    /// @notice EIP-165 interface-detection entry point. Returns true for ERC-165, ERC-6909, and
    ///         `IERC6909Premium`'s own interface ID.
    /// @param interfaceId Candidate interface identifier.
    /// @return supported Whether this contract declares support for `interfaceId`.
    function supportsInterface(bytes4 interfaceId) external view returns (bool supported);
}
