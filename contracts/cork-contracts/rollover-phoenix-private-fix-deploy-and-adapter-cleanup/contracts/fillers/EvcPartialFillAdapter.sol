// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {IEvcPartialFillAdapter} from "contracts/interfaces/IEvcPartialFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {LibFillerExecute} from "contracts/libs/LibFillerExecute.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";

/// @title EvcPartialFillAdapter
/// @notice EVC-aware Partial-bound reference adapter for rollover orders. See
///         {IEvcPartialFillAdapter} for the full behaviour contract.
/// @custom:threat-model per-subaccount
/// @custom:caller-binding EVC `onBehalfOfAccount` — identical model to `EvcExactFillAdapter`.
///         One adapter per curator subaccount; the adapter rejects every other subaccount.
/// @custom:split-rationale Split from `EvcRolloverAdapter` per #43 / RFC 003 §7.3. Because
///         `PartialFillSettler` keys per-filler accounting on `msg.sender` (the adapter) and
///         this contract is deployed per subaccount, each subaccount's Partial accounting is
///         naturally partitioned.
/// @custom:immutable-design Closes #55 / D-7. The deployed shape carries four immutables
///         (`SETTLER`, `EVC`, `AUTHORIZED_CALLER`, `FACTORY`) rather than the two (`SETTLER`,
///         `EVC`) sketched in the RFC §7.3 pseudocode. `AUTHORIZED_CALLER` anchors the per-
///         subaccount model (see `caller-binding` above); it is immutable rather than a storage
///         slot because a single subaccount's trust anchor is deploy-time, not per-call — one
///         adapter is deployed per curator subaccount and the anchor never rotates for its
///         lifetime. `FACTORY` caches the cellar factory at construction so the adapter can
///         reconstruct the embedded `CellarIntent.expectedCaller` on every `execute` without
///         an extra `settler.factory()` SLOAD per call; the constructor cross-checks
///         `expectedFactory_ == settler.factory()` so any stale factory fails at deploy time.
///         The RFC pseudocode update is tracked separately in cork-knowledge (out of scope for
///         this stack).
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
contract EvcPartialFillAdapter is IEvcPartialFillAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Threat-model tag surfaced for runtime assertion by the test-spec §138 NatSpec leaf.
    string public constant EXPECTED_THREAT_MODEL = "per-subaccount";

    /// @notice `PartialFillSettler` instance this adapter is bound to.
    address public immutable SETTLER;

    /// @notice Cellar factory cached at construction — used as `intent.expectedCaller` when
    ///         reconstructing the embedded `CellarIntent` on every `execute`.
    address public immutable FACTORY;

    /// @notice The `EthereumVaultConnector` instance this adapter trusts for caller resolution.
    address public immutable EVC;

    /// @inheritdoc IEvcPartialFillAdapter
    address public immutable AUTHORIZED_CALLER;

    /// @param settler_ The Partial settler this adapter drives.
    /// @param expectedFactory_ The factory the caller asserts `settler_` is bound to. The
    ///        constructor cross-checks against `settler_.factory()` and reverts on mismatch.
    /// @param evc_ The EVC instance the adapter trusts for caller resolution. Must be non-zero.
    /// @param authorizedCaller_ The one EVC subaccount this adapter accepts on every `execute`.
    ///        Must be non-zero.
    constructor(address settler_, address expectedFactory_, address evc_, address authorizedCaller_) {
        if (evc_ == address(0)) revert EvcPartialFillAdapter__ZeroEvc();
        if (authorizedCaller_ == address(0)) revert EvcPartialFillAdapter__InvalidCaller();
        if (!LibFillerExecute.isPartialSettler(settler_)) {
            revert EvcPartialFillAdapter__SettlerMismatch();
        }
        address settlerFactory = LibFillerExecute.readSettlerFactory(settler_);
        if (expectedFactory_ != settlerFactory) {
            revert EvcPartialFillAdapter__FactoryMismatch(expectedFactory_, settlerFactory);
        }

        SETTLER = settler_;
        FACTORY = settlerFactory;
        EVC = evc_;
        AUTHORIZED_CALLER = authorizedCaller_;
    }

    /// @inheritdoc IEvcPartialFillAdapter
    function execute(
        bytes calldata orderData,
        bytes calldata signature,
        bytes calldata originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) external nonReentrant {
        _requireAuthenticatedEvcCaller();

        if (destination == address(0)) revert EvcPartialFillAdapter__ZeroDestination();

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes32 orderId) =
            LibFillerExecute.decodeOrder(orderData, SETTLER);

        uint256 available = IERC20(od.srcCstToken).balanceOf(address(this));
        if (available < srcCstAmount) {
            revert EvcPartialFillAdapter__InsufficientTokens(od.srcCstToken, srcCstAmount, available);
        }

        LibFillerExecute.openIfNeeded(SETTLER, orderId, order, signature, originFillerData);

        (bytes memory rolloverFillerData, bytes memory premiumFillerData) =
            LibFillerExecute.buildPartialFillerData(od, order, SETTLER, FACTORY, address(this), destination, debitFrom);

        LibFillerExecute.dispatchBothLegs(
            SETTLER, od.srcCstToken, srcCstAmount, orderId, order, rolloverFillerData, premiumFillerData
        );

        LibFillerExecute.finalisePartial(SETTLER, order, od, address(this));
        // No-sweep-of-leftovers per RFC 003 §7.3: surplus srcCST stays on the adapter for a
        // sibling batch item to consume.
    }

    /// @dev Two-guard EVC authentication: direct calls and foreign subaccounts both revert
    ///      `EvcPartialFillAdapter__InvalidCaller`.
    /// @dev Intentionally duplicated in each EVC adapter rather than lifted to
    ///      `LibFillerExecute` — the check is the per-subaccount authorization gate
    ///      and must read as first-class per-contract surface, not a library helper.
    function _requireAuthenticatedEvcCaller() private view {
        if (msg.sender != EVC) revert EvcPartialFillAdapter__InvalidCaller();
        (bool ok, bytes memory data) =
            EVC.staticcall(abi.encodeWithSelector(IEVC.getCurrentOnBehalfOfAccount.selector, address(0)));
        if (!ok || data.length < 64) revert EvcPartialFillAdapter__InvalidCaller();
        (address onBehalfOfAccount,) = abi.decode(data, (address, bool));
        if (onBehalfOfAccount != AUTHORIZED_CALLER) revert EvcPartialFillAdapter__InvalidCaller();
    }
}
