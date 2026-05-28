// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

// EIP-712 type hash for Cork's `OrderData` struct, per test-spec §2.5 and partial-fill
// extension §5.2 (minFillRatio removed, `allowPartialFills` pluralized, `cellarIntentHash`
// added). Per RFC 003 §A.3 / §6.2 this also covers the AS-19/20/21 ingress-gate fields
// (`minFillSize`, `exclusiveFiller`). The pre-image string is the canonical, whitespace-free
// EIP-712 `encodeType` form over the 18 hashable `OrderData` fields (the Solidity struct has a
// 19th `bytes cellarSignature` field that is NOT part of the type hash).
// solhint-disable-next-line max-line-length
bytes32 constant ORDER_DATA_TYPE_HASH = keccak256(
    // solhint-disable-next-line max-line-length
    "OrderData(address receiver,MarketId srcPoolId,MarketId dstPoolId,address srcCstToken,address dstCstToken,address premiumToken,address repaymentToken,uint256 repaymentAmount,uint256 orderSize,uint256 minFillSize,bool allowPartialFills,bool allowUnderfill,address exclusiveFiller,uint256 minPremiumPerShare,bytes32 cellarIntentHash,Output[] outputs,Call[] rolloverHooks,Call[] premiumHooks)"
);

// RFC 003 §A.2 — `orderDataType` discriminator for the ERC-7683 order body.
bytes32 constant CORK_ROLLOVER_ORDER_TYPE = keccak256("CorkRolloverOrder_v1");

// EIP-712 type hash for the canonical ERC-7683 GaslessCrossChainOrder struct (maker digest).
// solhint-disable-next-line max-line-length
bytes32 constant GASLESS_ORDER_TYPE_HASH = keccak256(
    "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,"
    "uint256 originChainId,uint32 openDeadline,uint32 fillDeadline," "bytes32 orderDataType,bytes orderData)"
);

// EIP-712 type hash for the Cancel struct (used in cancel/refund flow per L1).
bytes32 constant CANCEL_TYPE_HASH = keccak256("Cancel(bytes32 orderId,uint256 cancelDeadline)");

// EIP-712 type hash for the `rescueSettled` authorization struct (PR 6 — filler-pull path over
// the `_rescueable` mapping credited by `finaliseAsSettled` when the dstCST payout reverts;
// closes #44). The filler signs over `(orderDigest, orderId, fallbackDestination)` under the
// settler's EIP-712 domain so a single typed-data signature proves the filler is authorising
// `fallbackDestination` to receive the stranded credit. Both concretes consume the same
// typehash: Partial keys its `_rescueable` by `orderDigest` and Exact by `orderId`, but the
// EIP-712 struct carries both so the signature remains unambiguous across settlers.
bytes32 constant RESCUE_TYPEHASH =
    keccak256("RescueSettled(bytes32 orderDigest,bytes32 orderId,address fallbackDestination)");

/// @title LibSettlerHashing
/// @notice Pure hashing primitives for Cork rollover orders. Each function implements one of the
///         canonical hashes in RFC 003 §§A.6–A.8 (with the partial-fill extension §5.2 schema
///         override on `orderDigest`).
/// @dev Hashes that depend on `block.chainid` (orderId, orderDigest) are `view`; the plain
///      `Output` hash is `pure`. Callers MUST pass the settler contract address explicitly — a
///      library's `address(this)` is brittle across call/delegatecall and is not used.
library LibSettlerHashing {
    /// @notice RFC 003 §A.6 — canonical `outputHash` for one ERC-7683 `Output`.
    /// @param output The output whose hash is being computed.
    /// @return The keccak256 ABI-encoded hash of `(token, amount, recipient, chainId)`.
    function computeOutputHash(IOriginSettler.Output memory output) internal pure returns (bytes32) {
        return keccak256(abi.encode(output.token, output.amount, output.recipient, output.chainId));
    }

    /// @notice RFC 003 §A.7 — canonical `orderId` for a `GaslessCrossChainOrder`.
    /// @dev The 9th field is `keccak256(order.orderData)`. Production callers pass
    ///      `address(this)` as `settler`; this library takes it as a parameter so callers can be
    ///      tested in isolation and so library semantics don't depend on call context.
    /// @param settler The settler contract address.
    /// @param order The gasless cross-chain order.
    /// @return The canonical `orderId`.
    function computeOrderId(address settler, IOriginSettler.GaslessCrossChainOrder memory order)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                block.chainid,
                settler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
    }

    /// @notice Canonical ERC-7683 maker-digest: EIP-712 `hashStruct` over the
    ///         `GaslessCrossChainOrder`. Used by `openFor` to recover/verify the maker's signature.
    /// @dev Dynamic `bytes orderData` is encoded as `keccak256(order.orderData)` per EIP-712 §5.
    /// @param order The gasless cross-chain order.
    /// @return The EIP-712 struct hash.
    function computeOpenForDigest(IOriginSettler.GaslessCrossChainOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GASLESS_ORDER_TYPE_HASH,
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
    }

    /// @notice EIP-712 `hashStruct` for a Cancel message. Used by cancel/refund to verify the
    ///         maker authorized the cancellation.
    /// @param orderId The canonical order identifier.
    /// @param cancelDeadline Unix timestamp after which the cancel authorization expires.
    /// @return The EIP-712 struct hash.
    function computeCancelDigest(bytes32 orderId, uint256 cancelDeadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, cancelDeadline));
    }

    /// @notice RFC 003 §A.8 with partial-fill extension §5.2 schema and PR 2 identity expansion —
    ///         non-recursive `orderDigest` that binds order identity to all semantically-meaningful
    ///         `OrderData` fields (excluding `cellarSignature` and `cellarIntentHash`, both of
    ///         which transitively depend on the digest — see dev notes below).
    /// @dev The digest is `keccak256(bytes.concat(first, second))`, mirroring the two `abi.encode`
    ///      chunks the implementation concatenates. Fields are listed in encoding order (D-9 / #57).
    ///      `first` (order envelope + pool + token context, 12 fields): `block.chainid`, `settler`,
    ///      `order.user`, `order.nonce`, `order.originChainId`, `order.openDeadline`,
    ///      `order.fillDeadline`, `od.srcPoolId`, `od.dstPoolId`, `od.srcCstToken`,
    ///      `od.dstCstToken`, `od.premiumToken`.
    ///      `second` (economics + hooks + flags + identity, 13 fields, further split into
    ///      `a` / `b` halves inside `_encodeOrderDigestSecondChunk` to stay under the via-IR 16-slot
    ///      stack limit): `od.repaymentToken`, `od.repaymentAmount`, `od.orderSize`,
    ///      `od.minFillSize`, `od.minPremiumPerShare`, `keccak256(abi.encode(od.outputs))`,
    ///      `keccak256(abi.encode(od.rolloverHooks))`, `keccak256(abi.encode(od.premiumHooks))`,
    ///      `od.allowPartialFills`, `od.allowUnderfill`, `od.exclusiveFiller`,
    ///      `order.orderDataType`, `od.receiver`.
    ///      RFC 003 issue #41 — collision scenario: two maker-identical orders differing only in
    ///      `rolloverHooks` (or `premiumHooks`, `repaymentToken`, `repaymentAmount`) used to share a
    ///      digest and so share settler state slots keyed by that digest. PR 2 binds all four of
    ///      those fields plus the PR-1 AS-19/21 additions (`minFillSize`, `exclusiveFiller`)
    ///      directly. `cellarIntentHash` is DELIBERATELY omitted: `od.cellarIntentHash =
    ///      keccak256(abi.encode(intent))` where `intent.orderDigest = computeOrderDigest(od)` —
    ///      binding it here would create a fixed-point at maker-construction time (the RFC §A.8
    ///      "circular dependency" concern). The direct hook hash inclusion already makes any
    ///      intent-field change surface in the digest (every `CellarIntent` field derives from
    ///      hashed OrderData fields), so omitting `cellarIntentHash` does not reopen the #41 gap.
    ///      `minFillRatio` is NOT included — it was removed by the partial-fill extension.
    ///      `cellarSignature` is NOT included — it is signed over this digest.
    /// @param settler The settler contract address.
    /// @param order The gasless cross-chain order.
    /// @param od Decoded `OrderData`.
    /// @return The identity-complete digest.
    function computeOrderDigest(
        address settler,
        IOriginSettler.GaslessCrossChainOrder memory order,
        OrderData memory od
    ) internal view returns (bytes32) {
        bytes memory first = abi.encode(
            block.chainid,
            settler,
            order.user,
            order.nonce,
            order.originChainId,
            order.openDeadline,
            order.fillDeadline,
            od.srcPoolId,
            od.dstPoolId,
            od.srcCstToken,
            od.dstCstToken,
            od.premiumToken
        );
        bytes memory second = _encodeOrderDigestSecondChunk(order, od);
        return keccak256(bytes.concat(first, second));
    }

    /// @dev Second-chunk encoding for `computeOrderDigest`. Pulled into its own function and
    ///      further split into `a` / `b` halves so via-IR does not blow the stack — the merged
    ///      13-field `abi.encode` exceeded the compiler's 16-slot limit.
    function _encodeOrderDigestSecondChunk(IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
        private
        pure
        returns (bytes memory)
    {
        bytes memory a = abi.encode(
            od.repaymentToken,
            od.repaymentAmount,
            od.orderSize,
            od.minFillSize,
            od.minPremiumPerShare,
            keccak256(abi.encode(od.outputs)),
            keccak256(abi.encode(od.rolloverHooks))
        );
        bytes memory b = abi.encode(
            keccak256(abi.encode(od.premiumHooks)),
            od.allowPartialFills,
            od.allowUnderfill,
            od.exclusiveFiller,
            order.orderDataType,
            od.receiver
        );
        return bytes.concat(a, b);
    }
}
