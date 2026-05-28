// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Terminal lifecycle state shared by both settlers. `None` is the default pre-open value,
///         `Opened` is the open transition, and {`Settled`, `Refunded`, `Cancelled`} are terminal
///         states that must never transition further. Declared at file scope so both settler
///         interfaces can reference it without import cycles.
enum OrderStatus {
    None,
    Opened,
    Settled,
    Refunded,
    Cancelled
}

/// @notice `msg.sender` is not the order maker for a maker-gated operation (e.g. direct-call
///         cancel without signature). See RFC 003 §6.4.1 (`finalise(toState: Cancelled)` auth).
error NotMaker();

/// @notice Order token shape does not match the settler's invariants (e.g. rollover leg token !=
///         destination-chain cST token, premium leg token != `premiumToken`). Raised during
///         `open` / `openFor` validation.
error InvalidOrderTokenPair();

/// @notice `CellarIntent` is inconsistent with the order: `allowPartialFills` disagrees with the
///         settler identity (Exact vs Partial), or intent fields contradict signed OrderData. See
///         partial-fill extension §13.3 / §13.4.
error InconsistentIntent();

/// @notice Order is not in a state that permits the requested operation. Raised by
///         open/openFor/finalise when `orderStatus` is `None`/`Opened`/terminal inappropriately
///         for the call.
error InvalidOrderStatus();

/// @notice Signature check failed — `openFor` order-signature or cancel signature did not recover
///         to `order.user` via `SignatureChecker` (ECDSA + ERC-1271 fallback).
error InvalidSignature();

/// @notice Supplied `orderId` parameter does not equal the settler's recomputation of RFC 003
///         §A.7 against the order decoded from `originData`.
error OrderIdMismatch();

/// @notice Fill entry past `order.fillDeadline`. Enforced on every `fill` call.
error FillAfterDeadline();

/// @notice Fill entry when `orderStatus[orderId]` is already a terminal state
///         (Settled / Refunded / Cancelled). Fill-before-open is permitted (`None` is accepted)
///         but terminal-before-fill is not.
error OrderInTerminalState();

/// @notice `fillerData`'s leading `outputIndex` byte does not match a known leg (0 = rollover,
///         1 = premium).
error InvalidOutputIndex();

/// @notice `keccak256(abi.encode(intent)) != od.cellarIntentHash`. The UW's signed OrderData
///         binds to exactly one `CellarIntent`; any other intent is rejected. Partial-fill
///         extension §5.4 / INV-P18.
error IntentNotBoundToOrder();

/// @notice `_hashOrder(order) != orderId` (Exact) or `_hashOrder(order) != orderDigest` (Partial)
///         at `finalise*` entry. Extension §13.3 / §13.4.
error DigestMismatch();

/// @notice `finaliseAsRefunded` called before `order.fillDeadline`. Extension §13.3 / §13.4.
error NotExpired();

/// @notice `finaliseAsCancelled` rejected because one or more legs have a fill record. Pre-fill
///         cancel only (RFC 003 §3.2, INV-S6).
error OrderHasFills();

/// @notice `openFor` called with empty `originFillerData`. RFC 003 §A.11 requires
///         `abi.encode(OriginFillerData)` — never empty bytes.
error InvalidOriginFillerData();
