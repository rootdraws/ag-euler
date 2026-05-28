// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CellarIntent} from "cellar/ICorkCellar.sol";
import {IBaseSettlerFactory} from "contracts/interfaces/IBaseSettlerFactory.sol";
import {IDestinationSettler} from "contracts/interfaces/IDestinationSettler.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOrderStatusView} from "contracts/interfaces/IOrderStatusView.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {
    LibRolloverOrder,
    OrderData,
    PartialFillerData,
    PremiumFillerData,
    RolloverFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";

/// @title LibFillerExecute
/// @notice Shared pure/internal primitives used by all four reference filler contracts
///         (`ExactRolloverFiller`, `PartialRolloverFiller`, `EvcExactFillAdapter`,
///         `EvcPartialFillAdapter`). The library replaces the `IS_PARTIAL` strategy bit that
///         previously collapsed two distinct threat models into a single `RolloverFiller` /
///         `EvcRolloverAdapter` pair (see #43, RFC 003 §7.2/§7.3). Code reuse lives here;
///         threat-model identity lives at the concrete filler layer.
/// @dev All helpers are `internal` and stateless. They compose raw settler calls and fillerData
///      byte-strings; they do NOT hold state, custody tokens, or make authentication decisions.
///      Each concrete filler is free to layer caller-side authentication (Pashov A2 for
///      shared-singleton fillers, EVC `onBehalfOfAccount` binding for per-subaccount adapters)
///      around these primitives without the library dictating a policy.
library LibFillerExecute {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Order decode helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Decode `orderData` into `(GaslessCrossChainOrder, OrderData, orderId)` as consumed
    ///         by every filler / adapter variant. Pulled into a helper so all 4 concrete fillers
    ///         share the same decode shape.
    function decodeOrder(bytes calldata orderData, address settler)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes32 orderId)
    {
        order = abi.decode(orderData, (IOriginSettler.GaslessCrossChainOrder));
        od = abi.decode(order.orderData, (OrderData));
        orderId = LibSettlerHashing.computeOrderId(settler, order);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  openFor dispatch
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Idempotent `openFor` — calls the settler only if the order status is `None`.
    function openIfNeeded(
        address settler,
        bytes32 orderId,
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes calldata signature,
        bytes calldata originFillerData
    ) internal {
        if (IOrderStatusView(settler).orderStatus(orderId) == OrderStatus.None) {
            IExactFillSettler(settler).openFor(order, signature, originFillerData);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  fillerData assembly
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Build the `(rolloverFillerData, premiumFillerData)` byte pair for the Exact path.
    ///         Encodes `RolloverFillerData` / `PremiumFillerData` with the ERC-7683 `outputIndex`
    ///         prefix byte (`0` = rollover leg, `1` = premium leg).
    function buildExactFillerData(address destination, address debitFrom)
        internal
        pure
        returns (bytes memory rolloverFillerData, bytes memory premiumFillerData)
    {
        rolloverFillerData = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: destination})));
        premiumFillerData = abi.encodePacked(uint8(1), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
    }

    /// @notice Build the `(rolloverFillerData, premiumFillerData)` byte pair for the Partial path.
    ///         Extracts the embedded `CellarIntent` from the gasless envelope using the factory
    ///         cached on the concrete filler, then encodes a `PartialFillerData` for each leg.
    /// @param od The decoded `OrderData` from the gasless envelope.
    /// @param order The gasless envelope itself — required by `extractCellarIntentFromOrderData`
    ///        to reconstruct the deterministic intent.
    /// @param settler The settler the concrete filler is bound to.
    /// @param factory The cellar factory cached on the concrete filler (non-zero on the Partial
    ///        path; zero on Exact — this helper is Partial-only).
    /// @param filler The filler / adapter instance itself — embedded as `targetFiller` on both
    ///        legs so the settler's per-filler accounting keys on the right address.
    /// @param destination dstCST recipient for the rollover leg.
    /// @param debitFrom ERC-6909 premium source for the premium leg.
    function buildPartialFillerData(
        OrderData memory od,
        IOriginSettler.GaslessCrossChainOrder memory order,
        address settler,
        address factory,
        address filler,
        address destination,
        address debitFrom
    ) internal view returns (bytes memory rolloverFillerData, bytes memory premiumFillerData) {
        (CellarIntent memory intent, bytes memory cellarSig) =
            LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);
        rolloverFillerData = abi.encodePacked(
            uint8(0),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: filler,
                    intent: intent,
                    cellarSig: cellarSig
                })
            )
        );
        premiumFillerData = abi.encodePacked(
            uint8(1),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom,
                    targetFiller: filler,
                    intent: intent,
                    cellarSig: cellarSig
                })
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Destination-settler dispatch (both legs + allowance flip)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Drive both legs of the destination-settler fill. Approves the settler for
    ///         `srcCstAmount` on the rollover leg, resets allowance to zero between legs, and
    ///         invokes the premium leg. The caller is responsible for `finaliseAsSettled`.
    function dispatchBothLegs(
        address settler,
        address srcCstToken,
        uint256 srcCstAmount,
        bytes32 orderId,
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes memory rolloverFillerData,
        bytes memory premiumFillerData
    ) internal {
        IERC20(srcCstToken).forceApprove(settler, srcCstAmount);

        bytes memory originDataForFill = abi.encode(order);

        IDestinationSettler(settler).fill(orderId, originDataForFill, rolloverFillerData);

        IERC20(srcCstToken).forceApprove(settler, 0);

        IDestinationSettler(settler).fill(orderId, originDataForFill, premiumFillerData);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  finaliseAsSettled dispatch
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Finalise an Exact-bound order with the terminal settler call. `orderId` is the
    ///         computed ERC-7683 identifier.
    function finaliseExact(address settler, bytes32 orderId) internal {
        IExactFillSettler(settler).finaliseAsSettled(orderId);
    }

    /// @notice Finalise a Partial-bound order with the terminal settler call. The settler keys on
    ///         `orderDigest` + `[filler]` for the single-filler reference adapters.
    function finalisePartial(
        address settler,
        IOriginSettler.GaslessCrossChainOrder memory order,
        OrderData memory od,
        address filler
    ) internal {
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(settler, order, od);
        address[] memory fillers = new address[](1);
        fillers[0] = filler;
        IPartialFillSettler(settler).finaliseAsSettled(orderDigest, fillers);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Constructor-time binding checks
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Probe whether the supplied settler exposes a Partial-only selector
    ///         (`totalDstCstEscrowed`). Concrete fillers compare the result against their own
    ///         asserted shape and revert through their own error namespace on mismatch.
    /// @return partialProbeSucceeded Whether the Partial-only selector probe succeeded.
    function isPartialSettler(address settler) internal view returns (bool partialProbeSucceeded) {
        try IPartialFillSettler(settler).totalDstCstEscrowed(bytes32(0)) returns (uint256) {
            partialProbeSucceeded = true;
        } catch {
            partialProbeSucceeded = false;
        }
    }

    /// @notice Read the settler's `factory()` immutable. Reverts the low-level call if the
    ///         supplied settler does not expose the selector.
    function readSettlerFactory(address settler) internal view returns (address) {
        return IBaseSettlerFactory(settler).factory();
    }
}
