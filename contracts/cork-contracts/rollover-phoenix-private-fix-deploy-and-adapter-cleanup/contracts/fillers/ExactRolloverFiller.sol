// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IBaseSettlerPremium} from "contracts/interfaces/IBaseSettlerPremium.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {IExactRolloverFiller} from "contracts/interfaces/IExactRolloverFiller.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {LibFillerExecute} from "contracts/libs/LibFillerExecute.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

/// @title ExactRolloverFiller
/// @notice Shared-singleton Exact-bound reference filler for rollover orders. See
///         {IExactRolloverFiller} for the full behaviour contract.
/// @custom:threat-model shared-singleton
/// @custom:caller-binding Pashov A2 — each `execute` requires `msg.sender == debitFrom` OR
///         `IERC6909Premium(ERC6909).isOperator(debitFrom, msg.sender)`. One deployed instance
///         services every caller; caller identity is asserted per-call via the ERC-6909 operator
///         ledger rather than at deploy time.
/// @custom:split-rationale Split from `RolloverFiller` per #43 / RFC 003 §7.2 — the shared-
///         singleton and per-subaccount threat models require distinct authentication surfaces
///         and cannot be unified on an `IS_PARTIAL` parameter bit.
contract ExactRolloverFiller is IExactRolloverFiller, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Threat-model tag surfaced for runtime assertion by the test-spec §138 NatSpec leaf.
    string public constant EXPECTED_THREAT_MODEL = "shared-singleton";

    /// @notice `ExactFillSettler` instance this filler is bound to.
    address public immutable SETTLER;

    /// @notice ERC-6909 premium ledger cached from `BaseSettler.erc6909Premium()` at construction.
    ///         Read on every `execute` for the Pashov A2 caller-side dual-auth check.
    address public immutable ERC6909;

    /// @param settler_ The Exact settler this filler drives. Constructor rejects Partial settlers
    ///        via a shape probe: a Partial-only selector (`totalDstCstEscrowed`) MUST NOT succeed
    ///        on the supplied settler.
    /// @param expectedFactory_ Retained for signature parity with the Partial-path filler.
    ///        Exact-path `FACTORY` is unused, so the caller MUST pass `address(0)`. Any other
    ///        value reverts `ExactRolloverFiller__FactoryMustBeZero`.
    constructor(address settler_, address expectedFactory_) {
        if (expectedFactory_ != address(0)) {
            revert ExactRolloverFiller__FactoryMustBeZero(expectedFactory_);
        }
        if (LibFillerExecute.isPartialSettler(settler_)) {
            revert ExactRolloverFiller__SettlerMismatch();
        }
        SETTLER = settler_;
        ERC6909 = IBaseSettlerPremium(settler_).erc6909Premium();
    }

    /// @inheritdoc IExactRolloverFiller
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external nonReentrant {
        if (destination == address(0)) revert ExactRolloverFiller__ZeroDestination();

        // Pashov A2: the filler is a shared singleton authorised by `debitFrom` as an ERC-6909
        // operator. Without this caller-side check a third party could name any `debitFrom` that
        // previously authorised the filler and drain their premium into the attacker's fill.
        if (debitFrom != msg.sender) {
            if (!IERC6909Premium(ERC6909).isOperator(debitFrom, msg.sender)) {
                revert DebitFromNotAuthorizedByCaller(debitFrom, msg.sender);
            }
        }

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes32 orderId) =
            LibFillerExecute.decodeOrder(orderData, SETTLER);

        if (!IERC20(od.srcCstToken).trySafeTransferFrom(msg.sender, address(this), srcCstAmount)) {
            revert SafeERC20.SafeERC20FailedOperation(od.srcCstToken);
        }

        LibFillerExecute.openIfNeeded(SETTLER, orderId, order, signature, originFillerData);

        (bytes memory rolloverFillerData, bytes memory premiumFillerData) =
            LibFillerExecute.buildExactFillerData(destination, debitFrom);

        LibFillerExecute.dispatchBothLegs(
            SETTLER, od.srcCstToken, srcCstAmount, orderId, order, rolloverFillerData, premiumFillerData
        );

        LibFillerExecute.finaliseExact(SETTLER, orderId);

        uint256 leftover = IERC20(od.srcCstToken).balanceOf(address(this));
        if (leftover > 0) IERC20(od.srcCstToken).safeTransfer(msg.sender, leftover);
    }
}
