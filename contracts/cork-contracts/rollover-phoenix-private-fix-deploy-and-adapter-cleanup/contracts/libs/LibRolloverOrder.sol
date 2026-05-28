// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";

/// @notice Cork rollover `OrderData`. Carried in `GaslessCrossChainOrder.orderData` /
///         `OnchainCrossChainOrder.orderData` per RFC 003 §A.3 and the partial-fill extension
///         §5.2 schema (no `minFillRatio`; `allowPartialFills` pluralized; `cellarIntentHash`
///         added; `minFillSize` and `exclusiveFiller` added for AS-19/20/21 ingress gates).
/// @dev 19 fields in Solidity. The first 18 (through `premiumHooks`) are hashed into
///      `ORDER_DATA_TYPE_HASH`. The trailing `cellarSignature` is carried for the Exact-path
///      `extractCellarIntentFromOrderData` helper but is NOT part of the EIP-712 type hash.
/// @param minFillSize Minimum per-fill rollover-leg `output.amount` (RFC §6.2 / AS-19). A
///        rollover-leg fill whose `output.amount < minFillSize` is rejected by the settler.
///        `minFillSize == 0` means unconstrained (legacy behaviour). Plan extension AS-22
///        (`ResidualTruncates`) additionally rejects partial-path fills that would leave
///        residual capacity `0 < r < minFillSize`; AS-22 is NOT part of RFC §6.2.
/// @param exclusiveFiller Address with exclusive right to fill. `address(0)` means the order is
///        open to any filler (RFC §6.2 / AS-21). When non-zero, the settler reverts any
///        `fill` whose `msg.sender != exclusiveFiller`.
struct OrderData {
    address receiver;
    MarketId srcPoolId;
    MarketId dstPoolId;
    address srcCstToken;
    address dstCstToken;
    address premiumToken;
    address repaymentToken;
    uint256 repaymentAmount;
    uint256 orderSize;
    uint256 minFillSize;
    bool allowPartialFills;
    bool allowUnderfill;
    address exclusiveFiller;
    uint256 minPremiumPerShare;
    bytes32 cellarIntentHash;
    IOriginSettler.Output[] outputs;
    Call[] rolloverHooks;
    Call[] premiumHooks;
    bytes cellarSignature;
}

/// @notice Exact rollover-leg fillerData (after stripping the `outputIndex` prefix).
///         Per RFC 003 §A.10.
/// @dev Destination is where the filler wants dstCST routed at `finaliseAsSettled`.
struct RolloverFillerData {
    address destination;
}

/// @notice Exact premium-leg fillerData (after stripping the `outputIndex` prefix).
///         Per RFC 003 §A.10.
/// @dev `debitFrom` is the account whose ERC-6909 premium balance is debited.
struct PremiumFillerData {
    address debitFrom;
}

/// @notice Partial-path fillerData (after stripping the `outputIndex` prefix). Per the
///         partial-fill extension §5.4 — carries `intent` and `cellarSig` inline so the same
///         (intent, signature) pair is used across both legs of a given fill.
struct PartialFillerData {
    address destination;
    address debitFrom;
    address targetFiller;
    CellarIntent intent;
    bytes cellarSig;
}

/// @notice Filler-provided payload at `openFor` time. Per RFC 003 §A.11 — feeds
///         `resolveFor` output amount and the relay repayment recipient.
struct OriginFillerData {
    uint256 outputAmount;
    address repaymentTo;
}

/// @title LibRolloverOrder
/// @notice Encode / decode helpers for the Cork rollover wire formats plus the Exact-path
///         `extractCellarIntentFromOrderData` helper. All functions are pure (the helper is
///         `view` because it delegates to `LibSettlerHashing.computeOrderDigest`).
/// @dev Encode helpers are exercised by tests and off-chain tooling; production settlers inline
///      `abi.encode` at the call site. Decode helpers are used by settlers at fill time.
library LibRolloverOrder {
    // ─────────────────────────────────────────────────────────────────────────────
    // Encode helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice ABI-encode an `OrderData` struct.
    function encodeOrderData(OrderData memory od) internal pure returns (bytes memory) {
        return abi.encode(od);
    }

    /// @notice ABI-encode rollover-leg `fillerData` with the `uint8(0)` outputIndex prefix.
    /// @dev Uses `abi.encodePacked(uint8, abi.encode(fd))` so the first byte is the raw
    ///      outputIndex. This matches `BaseSettler.fill`'s split — it reads
    ///      `uint8(bytes1(fillerData[0:1]))` then `abi.decode(fillerData[1:], (...))`. Pashov A8.
    function encodeRolloverFillerData(RolloverFillerData memory fd) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), abi.encode(fd));
    }

    /// @notice ABI-encode premium-leg `fillerData` with the `uint8(1)` outputIndex prefix.
    /// @dev See `encodeRolloverFillerData` for the wire-format rationale. Pashov A8.
    function encodePremiumFillerData(PremiumFillerData memory fd) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), abi.encode(fd));
    }

    /// @notice ABI-encode partial-path `fillerData` with a caller-supplied outputIndex prefix.
    /// @dev See `encodeRolloverFillerData` for the wire-format rationale. Pashov A8.
    /// @param outputIndex Leg discriminator — 0 for rollover, 1 for premium.
    /// @param fd The `PartialFillerData` payload.
    function encodePartialFillerData(uint8 outputIndex, PartialFillerData memory fd)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(outputIndex, abi.encode(fd));
    }

    /// @notice ABI-encode the `originFillerData` passed at `openFor` time. No outputIndex prefix.
    function encodeOriginFillerData(OriginFillerData memory ofd) internal pure returns (bytes memory) {
        return abi.encode(ofd);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Decode helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Decode an `OrderData` struct from calldata bytes.
    /// @dev Reverts (panics) with the ABI decoder's own error if `data` is not a valid encoding.
    function decodeOrderData(bytes calldata data) internal pure returns (OrderData memory) {
        return abi.decode(data, (OrderData));
    }

    /// @notice Decode `RolloverFillerData` from the bytes remaining after the outputIndex prefix.
    /// @param legData The `fillerData` bytes with the leading `uint8` outputIndex already stripped.
    function decodeRolloverFillerData(bytes calldata legData) internal pure returns (RolloverFillerData memory) {
        return abi.decode(legData, (RolloverFillerData));
    }

    /// @notice Decode `PremiumFillerData` from the bytes remaining after the outputIndex prefix.
    /// @param legData The `fillerData` bytes with the leading `uint8` outputIndex already stripped.
    function decodePremiumFillerData(bytes calldata legData) internal pure returns (PremiumFillerData memory) {
        return abi.decode(legData, (PremiumFillerData));
    }

    /// @notice Decode `PartialFillerData` from the bytes remaining after the outputIndex prefix.
    /// @param legData The `fillerData` bytes with the leading `uint8` outputIndex already stripped.
    function decodePartialFillerData(bytes calldata legData) internal pure returns (PartialFillerData memory) {
        return abi.decode(legData, (PartialFillerData));
    }

    /// @notice Decode `OriginFillerData` (passed at `openFor` time).
    function decodeOriginFillerData(bytes calldata data) internal pure returns (OriginFillerData memory) {
        return abi.decode(data, (OriginFillerData));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Exact-path reconstruction
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Reconstructs the `CellarIntent` + signature for the Exact-path settler. Partial
    ///         settlers carry intent and signature directly in `fillerData`; Exact does not — it
    ///         rebuilds them from `OrderData` fields, the order's `fillDeadline`, the settler
    ///         address, the factory address, and the computed `orderDigest`.
    /// @dev Callers MUST verify `keccak256(abi.encode(intent)) == od.cellarIntentHash` after this
    ///      call to enforce the intent-to-order binding (extension §5.4 / INV-P18). This helper
    ///      does NOT perform that check itself — it only rebuilds the struct.
    /// @param od Decoded `OrderData`.
    /// @param order The gasless cross-chain order.
    /// @param settler The settler contract address.
    /// @param factory The cellar factory address — used as `intent.expectedCaller`.
    /// @return intent The reconstructed `CellarIntent`.
    /// @return cellarSig The UW's signature from `od.cellarSignature`.
    function extractCellarIntentFromOrderData(
        OrderData memory od,
        IOriginSettler.GaslessCrossChainOrder memory order,
        address settler,
        address factory
    ) internal view returns (CellarIntent memory intent, bytes memory cellarSig) {
        intent = CellarIntent({
            orderDigest: LibSettlerHashing.computeOrderDigest(settler, order, od),
            expectedCaller: factory,
            settler: settler,
            deadline: uint256(order.fillDeadline),
            orderSize: od.orderSize,
            allowPartialFills: od.allowPartialFills,
            allowUnderfill: od.allowUnderfill,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        cellarSig = od.cellarSignature;
    }
}
