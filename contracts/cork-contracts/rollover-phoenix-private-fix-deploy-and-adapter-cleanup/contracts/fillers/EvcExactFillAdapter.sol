// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {LibFillerExecute} from "contracts/libs/LibFillerExecute.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

/// @title EvcExactFillAdapter
/// @notice EVC-aware Exact-bound reference adapter for rollover orders. See
///         {IEvcExactFillAdapter} for the full behaviour contract.
/// @custom:threat-model per-subaccount
/// @custom:caller-binding EVC `onBehalfOfAccount` — each `execute` requires
///         `msg.sender == EVC` AND `IEVC(EVC).getCurrentOnBehalfOfAccount(address(0)) ==
///         AUTHORIZED_CALLER`. One adapter is deployed per curator subaccount; a shared adapter
///         would collapse identities and enable cross-caller theft.
/// @custom:split-rationale Split from `EvcRolloverAdapter` per #43 / RFC 003 §7.3 — the per-
///         subaccount trust anchor is deploy-time, not per-call, and unifying it with the
///         shared-singleton filler via an `IS_PARTIAL` bit crossed two incompatible threat
///         models.
/// @custom:immutable-design Closes #55 / D-7. The deployed shape carries four immutables
///         (`SETTLER`, `EVC`, `AUTHORIZED_CALLER`, `FACTORY`) rather than the two (`SETTLER`,
///         `EVC`) sketched in the RFC §7.3 pseudocode. `AUTHORIZED_CALLER` anchors the per-
///         subaccount model (see `caller-binding` above); it is immutable rather than a storage
///         slot because a single subaccount's trust anchor is deploy-time, not per-call — one
///         adapter is deployed per curator subaccount and the anchor never rotates for its
///         lifetime. `FACTORY` is retained as an immutable on the Exact path purely for
///         deployment-surface and interface parity with `EvcPartialFillAdapter` — the
///         constructor forces `expectedFactory_ == address(0)` so the Exact path never silently
///         binds a factory. The RFC pseudocode update is tracked separately in cork-knowledge
///         (out of scope for this stack).
/// @custom:controller-to-check Closes #56 / D-8 (docs-only hardening). The EVC auth check passes
///         `controllerToCheck = address(0)` to `IEVC.getCurrentOnBehalfOfAccount`, which tells
///         the EVC "return the current on-behalf-of account without asserting any specific
///         controller is enabled." This is deliberate: Cork rollover adapters do NOT depend on
///         an EVC controller being enabled — the adapter's own two guards (`msg.sender == EVC`
///         AND returned account equals `AUTHORIZED_CALLER`) are the full authorization surface.
///         Pinning a specific controller would couple adapter deployment to whichever controller
///         a subaccount happens to use (vault-specific, curator-specific) and reject legitimate
///         calls from subaccounts that rotate controllers between batches. If a future
///         integration needs controller-pinning, introduce a separate adapter variant rather
///         than retrofitting this one.
contract EvcExactFillAdapter is IEvcExactFillAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Threat-model tag surfaced for runtime assertion by the test-spec §138 NatSpec leaf.
    string public constant EXPECTED_THREAT_MODEL = "per-subaccount";

    /// @notice `ExactFillSettler` instance this adapter is bound to.
    address public immutable SETTLER;

    /// @notice Retained for interface parity with the Partial adapter; always `address(0)` on
    ///         the Exact path (the Exact settler needs no cellar factory binding).
    address public immutable FACTORY;

    /// @notice The `EthereumVaultConnector` instance this adapter trusts for caller resolution.
    address public immutable EVC;

    /// @inheritdoc IEvcExactFillAdapter
    address public immutable AUTHORIZED_CALLER;

    /// @param settler_ The Exact settler this adapter drives.
    /// @param expectedFactory_ MUST be `address(0)`. The Exact path does not use `FACTORY`; any
    ///        other value would silently bind a stale factory and is rejected with
    ///        `EvcExactFillAdapter__FactoryMustBeZero`.
    /// @param evc_ The EVC instance the adapter trusts for caller resolution. Must be non-zero.
    /// @param authorizedCaller_ The one EVC subaccount this adapter accepts on every `execute`.
    ///        Must be non-zero.
    constructor(address settler_, address expectedFactory_, address evc_, address authorizedCaller_) {
        if (evc_ == address(0)) revert EvcExactFillAdapter__ZeroEvc();
        if (authorizedCaller_ == address(0)) revert EvcExactFillAdapter__InvalidCaller();
        if (expectedFactory_ != address(0)) revert EvcExactFillAdapter__FactoryMustBeZero(expectedFactory_);
        if (LibFillerExecute.isPartialSettler(settler_)) {
            revert EvcExactFillAdapter__SettlerMismatch();
        }

        SETTLER = settler_;
        FACTORY = address(0);
        EVC = evc_;
        AUTHORIZED_CALLER = authorizedCaller_;
    }

    /// @inheritdoc IEvcExactFillAdapter
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external nonReentrant {
        _requireAuthenticatedEvcCaller();

        if (destination == address(0)) revert EvcExactFillAdapter__ZeroDestination();

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes32 orderId) =
            LibFillerExecute.decodeOrder(orderData, SETTLER);

        uint256 available = IERC20(od.srcCstToken).balanceOf(address(this));
        if (available < srcCstAmount) {
            revert EvcExactFillAdapter__InsufficientTokens(od.srcCstToken, srcCstAmount, available);
        }

        LibFillerExecute.openIfNeeded(SETTLER, orderId, order, signature, originFillerData);

        (bytes memory rolloverFillerData, bytes memory premiumFillerData) =
            LibFillerExecute.buildExactFillerData(destination, debitFrom);

        LibFillerExecute.dispatchBothLegs(
            SETTLER, od.srcCstToken, srcCstAmount, orderId, order, rolloverFillerData, premiumFillerData
        );

        LibFillerExecute.finaliseExact(SETTLER, orderId);
        // No-sweep-of-leftovers per RFC 003 §7.3: surplus srcCST stays on the adapter for a
        // sibling batch item to consume.
    }

    /// @dev Two-guard EVC authentication: direct calls and foreign subaccounts both revert
    ///      `EvcExactFillAdapter__InvalidCaller`.
    /// @dev Intentionally duplicated in each EVC adapter rather than lifted to
    ///      `LibFillerExecute` — the check is the per-subaccount authorization gate
    ///      and must read as first-class per-contract surface, not a library helper.
    function _requireAuthenticatedEvcCaller() private view {
        if (msg.sender != EVC) revert EvcExactFillAdapter__InvalidCaller();
        (bool ok, bytes memory data) =
            EVC.staticcall(abi.encodeWithSelector(IEVC.getCurrentOnBehalfOfAccount.selector, address(0)));
        if (!ok || data.length < 64) revert EvcExactFillAdapter__InvalidCaller();
        (address onBehalfOfAccount,) = abi.decode(data, (address, bool));
        if (onBehalfOfAccount != AUTHORIZED_CALLER) revert EvcExactFillAdapter__InvalidCaller();
    }
}
