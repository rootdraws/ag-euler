// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IBaseSettlerPremium} from "contracts/interfaces/IBaseSettlerPremium.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialRolloverFiller} from "contracts/interfaces/IPartialRolloverFiller.sol";
import {LibFillerExecute} from "contracts/libs/LibFillerExecute.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

/// @title PartialRolloverFiller
/// @notice Shared-singleton Partial-bound reference filler for rollover orders. See
///         {IPartialRolloverFiller} for the full behaviour contract.
/// @custom:threat-model shared-singleton
/// @custom:caller-binding Pashov A2 — each `execute` requires `msg.sender == debitFrom` OR
///         `IERC6909Premium(ERC6909).isOperator(debitFrom, msg.sender)`. One deployed instance
///         services every caller; caller identity is asserted per-call via the ERC-6909 operator
///         ledger rather than at deploy time.
/// @custom:split-rationale Split from `RolloverFiller` per #43 / RFC 003 §7.2. The per-filler
///         accounting in `PartialFillSettler` keys on `msg.sender`, so production Partial callers
///         SHOULD deploy their own instance; this contract is a canonical reference binding only.
contract PartialRolloverFiller is IPartialRolloverFiller, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Threat-model tag surfaced for runtime assertion by the test-spec §138 NatSpec leaf.
    string public constant EXPECTED_THREAT_MODEL = "shared-singleton";

    /// @notice `PartialFillSettler` instance this filler is bound to.
    address public immutable SETTLER;

    /// @notice Cellar factory cached at construction — used as `intent.expectedCaller` when
    ///         reconstructing the embedded `CellarIntent` on every `execute`.
    address public immutable FACTORY;

    /// @notice ERC-6909 premium ledger cached from `BaseSettler.erc6909Premium()` at construction.
    ///         Read on every `execute` for the Pashov A2 caller-side dual-auth check.
    address public immutable ERC6909;

    /// @param settler_ The Partial settler this filler drives. Constructor probes a Partial-only
    ///        selector — if the probe fails, `settler_` is not a Partial settler and the
    ///        constructor reverts `PartialRolloverFiller__SettlerMismatch`.
    /// @param expectedFactory_ The factory the caller asserts `settler_` is bound to. The
    ///        constructor cross-checks against `settler_.factory()` and reverts on mismatch.
    constructor(address settler_, address expectedFactory_) {
        if (!LibFillerExecute.isPartialSettler(settler_)) {
            revert PartialRolloverFiller__SettlerMismatch();
        }
        address settlerFactory = LibFillerExecute.readSettlerFactory(settler_);
        if (expectedFactory_ != settlerFactory) {
            revert PartialRolloverFiller__FactoryMismatch(expectedFactory_, settlerFactory);
        }
        SETTLER = settler_;
        FACTORY = settlerFactory;
        ERC6909 = IBaseSettlerPremium(settler_).erc6909Premium();
    }

    /// @inheritdoc IPartialRolloverFiller
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external nonReentrant {
        if (destination == address(0)) revert PartialRolloverFiller__ZeroDestination();

        // Pashov A2: identical to ExactRolloverFiller — see there for rationale.
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
            LibFillerExecute.buildPartialFillerData(od, order, SETTLER, FACTORY, address(this), destination, debitFrom);

        LibFillerExecute.dispatchBothLegs(
            SETTLER, od.srcCstToken, srcCstAmount, orderId, order, rolloverFillerData, premiumFillerData
        );

        LibFillerExecute.finalisePartial(SETTLER, order, od, address(this));

        uint256 leftover = IERC20(od.srcCstToken).balanceOf(address(this));
        if (leftover > 0) IERC20(od.srcCstToken).safeTransfer(msg.sender, leftover);
    }
}
