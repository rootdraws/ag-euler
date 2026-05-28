// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {IPoolShare} from "phoenix/interfaces/IPoolShare.sol";

import {IBaseSettlerFactory} from "contracts/interfaces/IBaseSettlerFactory.sol";
import {IDestinationSettler} from "contracts/interfaces/IDestinationSettler.sol";
import {IOrderStatusView} from "contracts/interfaces/IOrderStatusView.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {
    OrderStatus,
    InvalidSignature,
    InvalidOrderStatus,
    OrderIdMismatch,
    FillAfterDeadline,
    OrderInTerminalState,
    InvalidOutputIndex,
    NotMaker
} from "contracts/interfaces/RolloverTypes.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, RESCUE_TYPEHASH} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {ICorkCellarPremiumView} from "contracts/interfaces/ICorkCellarPremiumView.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {
    NotImplemented,
    InvalidDestination,
    UnauthorizedDebitFrom,
    WrongOriginSettler,
    WrongOriginChain,
    OpenDeadlinePassed,
    NotExclusiveFiller,
    BelowMinFillSize,
    DecimalTruncates,
    ResidualTruncates,
    NothingToRescue,
    InvalidRescueSignature
} from "contracts/settlers/BaseSettlerErrors.sol";

/// @title BaseSettler
/// @notice Abstract shared base for ExactFillSettler and PartialFillSettler.
/// @dev Token choreography (#46 / M2). The settler mediates three parties (UW, filler, cellar)
///      across two legs and a terminal payout. The table below names which actor holds which
///      token at each phase — reviewers SHOULD audit new flows against it to catch accidental
///      cross-party leaks.
///
///      | phase                 | UW              | filler                    | cellar                | settler                         | ERC6909Premium       |
///      |-----------------------|-----------------|---------------------------|-----------------------|---------------------------------|----------------------|
///      | phase-0 (rollover)    | srcCST → cellar | (push) srcCST to cellar   | holds srcCST, mints   | holds dstCST (escrow)           | —                    |
///      |                       |                 |                           | dstCST → settler      |                                 |                      |
///      | phase-1 (premium)     | —               | holds cST receipt         | receives premiumToken | escrows dstCST (unchanged)      | debits `debitFrom`'s |
///      |                       |                 | (via debitFrom)           | (ERC-20)              |                                 | ERC-6909 balance,    |
///      |                       |                 |                           |                       |                                 | transfers premium-   |
///      |                       |                 |                           |                       |                                 | Token to cellar      |
///      | finaliseAsSettled     | —               | receives dstCST (payout)  | —                     | transfers dstCST out, holds     | —                    |
///      |                       |                 | or rescueable credit      |                       | zero (or remaining-slot escrow) |                      |
///
///      Balance floor invariant (#46): after the `finaliseAsSettled` transfer loop the settler's
///      live `dstCST.balanceOf` MUST be >= the order's `totalDstCstEscrowed` for any unfinalised
///      slots. Violation reverts `BalanceFloorViolated` — a silent-siphon tripwire.
abstract contract BaseSettler is
    IOriginSettler,
    IDestinationSettler,
    IBaseSettlerFactory,
    IOrderStatusView,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @notice `externalSafeTransfer` was called from outside this contract. The entry point
    ///         exists only so `finaliseAsSettled`'s payout loop can wrap `SafeERC20.safeTransfer`
    ///         in a `try/catch` (Solidity's `try` requires an external call); it is never
    ///         intended for third-party invocation.
    error NotSelfCall();

    address public immutable factory;
    address public immutable erc6909Premium;

    mapping(bytes32 orderId => OrderStatus) public orderStatus;

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    /// @notice Settler-internal transient-storage slot. The premium-leg writes `pfd.targetFiller`
    ///         (Exact: `rolloverRec.filler`) here before forwarding to
    ///         `CorkCellarFactory.executeIntentHooks`, and reads it back via the
    ///         `premiumFillerSlot()` view. The value is exposed to the cellar's `_runPremiumPhase`
    ///         through that view — not through a direct cross-contract `tload` — because EIP-1153
    ///         transient storage is per-contract scoped (a cellar-side `tload` of this slot would
    ///         read zero from the cellar's own context).
    /// @dev **Not a cross-repo ABI element.** The slot value is a settler-private implementation
    ///      detail and can change without coordinating with cellar-private, provided
    ///      `premiumFillerSlot()` continues to `tload` the same slot the premium leg `tstore`s.
    ///      The cross-repo contract is the `premiumFillerSlot()` view's selector plus the
    ///      invariant that it returns the filler the settler advertised in the current phase-1
    ///      window — see `premiumFillerSlot()` for the cross-repo surface. The `- 1` shift in the
    ///      derivation (`keccak256("cork.rollover.premiumFiller") - 1`) follows EIP-1967
    ///      precedent, avoiding collision with any `keccak256`-derived mapping slot.
    bytes32 internal constant PREMIUM_FILLER_SLOT = 0x571389150f3d88f9ddeb42326f95be755e3c98904617911d31601c6b30ea6052;

    constructor(address factory_, address erc6909Premium_) {
        factory = factory_;
        erc6909Premium = erc6909Premium_;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    // ═══════════════════════════════════════════════════════════════
    //  EIP-712
    // ═══════════════════════════════════════════════════════════════

    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _computeDomainSeparator();
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CorkRolloverSettler"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Template methods
    // ═══════════════════════════════════════════════════════════════

    function open(OnchainCrossChainOrder calldata) external virtual {
        revert NotImplemented();
    }

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata sig, bytes calldata originFillerData)
        external
    {
        (bytes32 orderId, bool opened) = _openForCore(order, sig, originFillerData);
        if (opened) {
            emit Open(orderId, _resolveFor(order, originFillerData));
        }
    }

    function _openForCore(GaslessCrossChainOrder calldata order, bytes calldata sig, bytes calldata originFillerData)
        private
        returns (bytes32 orderId, bool opened)
    {
        // ERC-7683 guards (H4)
        if (order.originSettler != address(this)) revert WrongOriginSettler();
        if (order.originChainId != block.chainid) revert WrongOriginChain();
        uint256 effectiveOpenDeadline = order.openDeadline == 0 ? order.fillDeadline : order.openDeadline;
        if (block.timestamp > effectiveOpenDeadline) revert OpenDeadlinePassed();

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        _validateOpen(od);

        orderId = LibSettlerHashing.computeOrderId(address(this), order);

        // Idempotency / terminal short-circuit before sig recovery (N3)
        OrderStatus status = orderStatus[orderId];
        if (_isTerminal(status)) revert InvalidOrderStatus();
        if (status == OrderStatus.Opened) return (orderId, false);

        // Canonical ERC-7683 maker signature verification (H6)
        bytes32 makerDigest = LibSettlerHashing.computeOpenForDigest(order);
        _recover(makerDigest, order.user, sig);

        // Internal cellar/intents digest (unchanged routing)
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(this), order, od);
        _validateOriginFillerData(originFillerData);
        _onOpenForDecoded(orderId, abi.decode(originFillerData, (OriginFillerData)));

        _onOpenTransitionToOpened(orderId, orderDigest, order.user);
        orderStatus[orderId] = OrderStatus.Opened;
        opened = true;
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external nonReentrant {
        GaslessCrossChainOrder memory order = abi.decode(originData, (GaslessCrossChainOrder));
        if (_hashOrder(order) != orderId) revert OrderIdMismatch();

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        if (block.timestamp > order.fillDeadline) revert FillAfterDeadline();

        OrderStatus status = orderStatus[orderId];
        if (_isTerminal(status)) revert OrderInTerminalState();

        // AS-21 (RFC §6.2) — exclusive-filler authorization. Placed BEFORE `_validateOpen` so a
        // caller with an `exclusiveFiller` mismatch sees the authorization error rather than an
        // order-shape validation error. Matches RFC §6.2 pseudocode ordering.
        if (od.exclusiveFiller != address(0) && msg.sender != od.exclusiveFiller) {
            revert NotExclusiveFiller();
        }

        _validateOpen(od);

        uint8 outputIndex = uint8(bytes1(fillerData[0:1]));
        bytes calldata legData = fillerData[1:];

        Output memory legOutput;
        if (outputIndex == 0) {
            legOutput = od.outputs[0];
        } else if (outputIndex == 1) {
            legOutput = od.outputs[1];
        } else {
            revert InvalidOutputIndex();
        }

        // Rollover-leg ingress gates — all three are share-unit / pool-decimal defences and are
        // meaningless on the premium leg, whose `legOutput.amount` is denominated in the premium
        // token (not the rollover share unit).
        //  • AS-19 (RFC §6.2) — `BelowMinFillSize`    — rejects dust rollover legs.
        //  • AS-20 (RFC §6.2) — `DecimalTruncates`    — rejects fills that fail the per-fill pool
        //                                                decimal-offset modulo check.
        //  • AS-22 (plan extension §PR 1) — `ResidualTruncates` — Partial-only; rejects a fill
        //                                                that would leave residual capacity
        //                                                `0 < r < minFillSize` (Exact is
        //                                                single-fill-per-order and overrides with
        //                                                the default no-op).
        if (outputIndex == 0) {
            if (od.minFillSize != 0 && legOutput.amount < od.minFillSize) {
                revert BelowMinFillSize();
            }
            _enforceDecimalTruncates(od, legOutput.amount);
            if (od.minFillSize != 0) {
                _enforceResidualTruncates(od, orderId, legOutput.amount);
            }
            _onRolloverLegFill(order, od, legOutput, legData);
        } else {
            _onPremiumLegFill(order, od, legOutput, legData);
        }
    }

    function resolve(OnchainCrossChainOrder calldata) external view virtual returns (ResolvedCrossChainOrder memory) {
        revert NotImplemented();
    }

    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        virtual
        returns (ResolvedCrossChainOrder memory resolved)
    {
        resolved = _resolveFor(order, originFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal primitives
    // ═══════════════════════════════════════════════════════════════

    function _requireDestination(address destination) internal pure {
        if (destination == address(0)) revert InvalidDestination();
    }

    function _requireDebitFromAuthorized(address debitFrom) internal view {
        if (debitFrom != msg.sender && !IERC6909Premium(erc6909Premium).isOperator(debitFrom, msg.sender)) {
            revert UnauthorizedDebitFrom();
        }
    }

    function _recover(bytes32 digest, address user_, bytes calldata signature) internal view {
        if (signature.length == 0) revert InvalidSignature();
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), digest));
        if (!SignatureChecker.isValidSignatureNow(user_, eip712Hash, signature)) {
            revert InvalidSignature();
        }
    }

    function _recoverCancel(bytes32 orderId, bytes calldata cancelSig, address user_) internal view {
        if (cancelSig.length < 32) revert NotMaker();
        uint256 cancelDeadline = abi.decode(cancelSig[:32], (uint256));
        if (block.timestamp > cancelDeadline) revert NotMaker();
        bytes32 cancelDigest = LibSettlerHashing.computeCancelDigest(orderId, cancelDeadline);
        bytes calldata sig = cancelSig[32:];
        try this.verifyCancel(cancelDigest, user_, sig) {}
        catch {
            revert NotMaker();
        }
    }

    function verifyCancel(bytes32 digest, address user_, bytes calldata sig) external view {
        _recover(digest, user_, sig);
    }

    /// @notice Self-call trampoline so `finaliseAsSettled`'s payout loop can wrap
    ///         `SafeERC20.safeTransfer` in `try/catch`. Solidity's `try` only supports external
    ///         / `new` calls — an in-contract `safeTransfer` revert is not catchable. By routing
    ///         the call through `this.externalSafeTransfer(...)` the payout-loop gets a catchable
    ///         revert boundary while preserving `SafeERC20`'s check semantics (silent-false,
    ///         non-returning tokens, etc.).
    /// @dev Access is restricted to `this` — third-party calls MUST revert with `NotSelfCall`.
    ///      No state mutation here; this only forwards to `SafeERC20.safeTransfer` and bubbles
    ///      any revert. Blacklist-style tokens like USDC surface their `address frozen` revert
    ///      verbatim via this path.
    /// @dev SAFETY INVARIANT — the OUTER caller of this trampoline MUST be `nonReentrant`.
    ///      Reentrancy safety of this function depends on `finaliseAsSettled` (the only current
    ///      caller) holding `ReentrancyGuard._status = ENTERED` for the duration of the payout
    ///      loop. The trampoline itself does NOT and MUST NOT carry the `nonReentrant` modifier:
    ///      OpenZeppelin's guard would revert the nested self-call because the outer frame has
    ///      already set `_status = ENTERED`. A future refactor that invokes `externalSafeTransfer`
    ///      from an un-guarded entry point would silently break the reentrancy argument — any
    ///      new caller MUST itself be `nonReentrant`.
    /// @param token ERC-20 token to transfer.
    /// @param to Recipient of the transfer.
    /// @param amount Amount to transfer.
    function externalSafeTransfer(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelfCall();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Forwards a phase-keyed call through `CorkCellarFactory.executeIntentHooks` — the
    ///         single path by which settler-side action touches the cellar. The factory's
    ///         `blockedSettlers[msg.sender]` gate — where `msg.sender` is this settler contract —
    ///         is checked atomically inside this forward; a blocked settler reverts here and every
    ///         state mutation in the current transaction rolls back with it.
    /// @dev **Atomic-revert invariant (closes #64 / Integ M4 — RFC §9.2 filler trust-boundary).**
    ///      State-modifying writes in `_onRolloverLegFill` / `_onPremiumLegFill` (and any
    ///      other leg-level hook that calls into this helper) MUST precede the call so the
    ///      blocklist revert unwinds them. Factory blocklist enforcement depends on atomic revert
    ///      through this forward — any future settler variant that removes or defers the forward
    ///      (e.g. a rollover-only variant that never settles on the cellar) MUST implement its
    ///      own blocklist awareness. `grep "block"` in this repo currently returns nothing on the
    ///      settler side; today's safety is solely the factory-side check reached via this call.
    /// @custom:atomic-revert-invariant forward
    /// @param cellar Cellar bound to the order (Partial: `cellarOf[orderDigest]`; Exact:
    ///        `cellarOf[orderId]`).
    /// @param orderDigest Order binding digest — routed through to the cellar.
    /// @param phase `0` for rollover leg, `1` for premium leg.
    /// @param intent `CellarIntent` prepared by the filler (rollover) or carried from phase-0
    ///        (premium).
    /// @param cellarSig UW signature over the `CellarIntent`.
    /// @param fillAmount Leg-specific amount (share units for the rollover leg; ERC-6909
    ///        premium-token units for the premium leg).
    /// @param filler Caller credited with the leg.
    /// @return actualRolled Amount the cellar reports as actually rolled on phase-0; ignored on
    ///         phase-1.
    function _forwardToFactory(
        address cellar,
        bytes32 orderDigest,
        uint8 phase,
        CellarIntent memory intent,
        bytes memory cellarSig,
        uint256 fillAmount,
        address filler
    ) internal returns (uint256 actualRolled) {
        actualRolled = ICorkCellarFactory(factory)
            .executeIntentHooks(cellar, orderDigest, phase, intent, cellarSig, fillAmount, filler);
    }

    /// @notice Cross-repo ABI element (#63). Returns the filler identity the settler published to
    ///         its own `PREMIUM_FILLER_SLOT` before calling `executeIntentHooks` on the current
    ///         phase-1 forward; outside that window returns zero (transient storage clears on
    ///         transaction end).
    /// @dev **This selector — `premiumFillerSlot()` — plus the invariant that it returns the
    ///      filler the settler advertised in the current phase-1 window — is the cross-repo
    ///      contract.** The underlying slot constant is settler-internal and may change without
    ///      coordinating with cellar-private provided this view continues to return the
    ///      `tload`ed value. The cellar-side `_runPremiumPhase` (cellar-private companion)
    ///      resolves the originating settler via
    ///      `ICorkCellarFactory(msg.sender).originatingSettler()` and calls this view to
    ///      cross-check the advertised filler against the `filler` arg the factory relayed.
    ///      A direct `tload(PREMIUM_FILLER_SLOT)` from the cellar's own context would return
    ///      zero (EIP-1153 scopes transient storage per contract), hence this accessor.
    function premiumFillerSlot() external view returns (address filler) {
        bytes32 slot = PREMIUM_FILLER_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            filler := tload(slot)
        }
    }

    function _settlePremium(uint256 tokenId, uint256 amount, address debitFrom, address premiumFiller, address cellar)
        internal
    {
        IERC6909Premium(erc6909Premium).settle(debitFrom, premiumFiller, tokenId, amount, cellar);
    }

    function _hashOrder(GaslessCrossChainOrder memory order) internal view returns (bytes32) {
        return LibSettlerHashing.computeOrderId(address(this), order);
    }

    function _toGasless(OnchainCrossChainOrder calldata order) internal view returns (GaslessCrossChainOrder memory) {
        return GaslessCrossChainOrder({
            originSettler: address(this),
            user: msg.sender,
            nonce: 0,
            originChainId: block.chainid,
            openDeadline: 0,
            fillDeadline: order.fillDeadline,
            orderDataType: order.orderDataType,
            orderData: order.orderData
        });
    }

    // ═══════════════════════════════════════════════════════════════
    //  Shared filler-escrow primitives (PR 3 — Task 8)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Common view shape for per-filler rollover-leg escrow. Unified across Exact
    ///         (single-participant, stored per `(orderId, outputHash)`) and Partial (multi-
    ///         participant, stored per `(orderDigest, filler)`); each concrete maps its native
    ///         storage into this shape via `_lookupFillerEscrow`.
    /// @dev `dstCstProduced` is `uint256` in both concretes (PR 3 / #53 unified the width —
    ///      previously Exact used `uint128` and could silently narrow on large rolls).
    /// @param filler Address credited with the rollover-leg fill. Partial: `msg.sender` on the
    ///        rollover leg. Exact: `msg.sender` on the rollover leg.
    /// @param destination Filler's chosen dstCST recipient at finalise time. Partial: `pfd.destination`.
    ///        Exact: `rfd.destination`.
    /// @param srcCstProvided srcCST the filler supplied (Partial: `actualRolled`; Exact: `output.amount`).
    /// @param dstCstProduced dstCST escrowed on the settler from the rollover delta.
    /// @param filledAt Block timestamp of the rollover-leg fill (0 means "no record").
    /// @param premiumSettled Partial-only latch. Exact tracks this via `paymentSettled[orderId]`
    ///        and always reports `false` on the rollover record.
    /// @param finalised Partial-only latch; Exact reports `false` (its terminal path is single-shot).
    /// @param refunded Partial-only latch; Exact reports `false` (refund path is order-level).
    struct FillerEscrow {
        address filler;
        address destination;
        uint256 srcCstProvided;
        uint256 dstCstProduced;
        uint64 filledAt;
        bool premiumSettled;
        bool finalised;
        bool refunded;
    }

    /// @notice Write primitive — records a rollover-leg escrow entry in the concrete's native
    ///         storage. Exact and Partial override with their respective mapping shapes; the
    ///         default is a no-op so `MockBaseSettler` and any future base-only concrete stays
    ///         compilable without escrow storage.
    /// @param orderKey Partial: `orderDigest`. Exact: `orderId` (the Exact concrete re-derives
    ///        `outputHash` internally from its cached `_rolloverOutputHash[orderId]`).
    /// @param filler Rollover-leg filler (caller).
    /// @param srcCstProvided srcCST committed (Partial: `actualRolled`; Exact: `output.amount`).
    /// @param dstCstProduced dstCST delta escrowed on the settler.
    /// @param destination Filler's chosen dstCST recipient.
    function _recordFillerEscrow(
        bytes32 orderKey,
        address filler,
        uint256 srcCstProvided,
        uint256 dstCstProduced,
        address destination
    ) internal virtual {}

    /// @notice Read primitive — returns the `FillerEscrow` for a `(orderKey, filler)` pair,
    ///         mapped from the concrete's native storage. A zero struct means "no record".
    /// @param orderKey Partial: `orderDigest`. Exact: `orderId`.
    /// @param filler Rollover-leg filler.
    function _lookupFillerEscrow(bytes32 orderKey, address filler)
        internal
        view
        virtual
        returns (FillerEscrow memory)
    {}

    /// @notice Read primitive — returns the amount of dstCST credited as rescueable for
    ///         `(orderKey, filler)`. A rescueable credit is booked by `finaliseAsSettled` when the
    ///         concrete's dstCST `safeTransfer` to the filler's chosen destination reverts (e.g. a
    ///         blacklist-style token like USDC with a non-compliant destination): the filler's slot
    ///         is still latched as finalised so the order terminal predicate is not blocked, but
    ///         the payout is deferred for withdrawal via PR 6's `rescueSettled` entry point.
    /// @dev Concretes override with their native rescueable mapping. PR 5 introduces the mapping
    ///      and the writes from `finaliseAsSettled`; PR 6 introduces the filler-authenticated
    ///      withdrawal entry point that reads this view uniformly. Partial: `orderKey == orderDigest`.
    ///      Exact: `orderKey == orderId`. Default returns 0 so base-only concretes (e.g.
    ///      `MockBaseSettler`) stay compilable without rescueable storage.
    /// @param orderKey Order identifier used by the concrete (digest for Partial, id for Exact).
    /// @param filler Rollover-leg filler whose payout was deferred.
    /// @return amount dstCST amount currently credited as rescueable.
    function rescueableOf(bytes32 orderKey, address filler) external view virtual returns (uint256 amount) {}

    // ═══════════════════════════════════════════════════════════════
    //  Filler-pull path: rescueSettled (PR 6 — closes #44)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Shared core for the filler-authenticated rescue withdrawal. Concretes expose a
    ///         thin `rescueSettled` entry point that marks `nonReentrant` and forwards to this
    ///         helper; the split keeps the signature-verification / CEI / transfer sequence in a
    ///         single place while letting each concrete pick the native `_rescueable` key shape
    ///         (Partial: `orderDigest`; Exact: `orderId`) via the virtual `_consumeRescueable`
    ///         hook. The EIP-712 struct always carries BOTH `(orderDigest, orderId)` so a signed
    ///         rescue authorisation is unambiguous across settler variants — Partial reads
    ///         `orderDigest` against its mapping and Exact reads `orderId`, but the signed
    ///         pre-image is identical in shape.
    /// @dev    CEI layout — the mapping slot is zeroed inside `_consumeRescueable` BEFORE the
    ///         external `safeTransfer`. This makes the function trivially replay-safe: a second
    ///         submission of the same signature reverts `NothingToRescue` because the slot is
    ///         now zero. `nonReentrant` is applied on the concrete's external wrapper — the
    ///         helper itself MUST NOT carry the modifier, see `externalSafeTransfer` for the
    ///         symmetric constraint on that trampoline.
    /// @param orderDigest Partial's `_rescueable` key. Exact passes the order's digest here too
    ///        so the signature pre-image is stable across concretes; Exact's mapping ignores it.
    /// @param orderId Exact's `_rescueable` key. Partial passes the canonical `orderIdOf[digest]`
    ///        so the pre-image shape is uniform; Partial's mapping ignores it.
    /// @param filler Address authorising the withdrawal — the same address credited by
    ///        `finaliseAsSettled`'s blacklist-catch branch. Also the only address that can have
    ///        signed the recovery digest.
    /// @param fallbackDestination Recipient chosen by the filler for the stranded dstCST. MUST NOT
    ///        be `address(0)` — the `_requireDestination` invariant that guards the rollover-leg
    ///        destination also guards the rescue path so callers cannot burn funds.
    ///        **Self-foot-shooting surface (PR 6 deferred concern).** `_requireDestination` only
    ///        rejects the zero-address — `fallbackDestination == address(this)` is accepted and
    ///        will permanently strand the rescue credit inside the settler: the mapping slot is
    ///        zeroed by `_consumeRescueable` BEFORE the transfer (CEI) and no second-pass recovery
    ///        path exists. Requires the filler's own EIP-712 signature over `(orderDigest, orderId,
    ///        fallbackDestination)` so the surface is self-only — not third-party-exploitable — but
    ///        filler frontends MUST refuse (or at minimum loudly warn) when the requested
    ///        `fallbackDestination` equals the settler address.
    /// @param sig Filler's EIP-712 signature over
    ///        `keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination))`.
    ///        Verified via `SignatureChecker.isValidSignatureNow` so EOA and ERC-1271 smart-wallet
    ///        fillers both work.
    /// @param token dstCST address to transfer. Concretes look this up from their native
    ///        per-order mapping (Partial keys by `orderDigest`, Exact by `orderId`) and pass it
    ///        through — the helper stays storage-agnostic.
    /// @return amount dstCST released to `fallbackDestination`.
    function _rescueSettled(
        bytes32 orderDigest,
        bytes32 orderId,
        address filler,
        address fallbackDestination,
        bytes calldata sig,
        address token
    ) internal returns (uint256 amount) {
        _requireDestination(fallbackDestination);

        bytes32 structHash = keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination));
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        if (!SignatureChecker.isValidSignatureNow(filler, eip712Hash, sig)) {
            revert InvalidRescueSignature();
        }

        // CEI: zero the mapping slot (inside `_consumeRescueable`) BEFORE the external transfer.
        // A zero credit — either never-booked or already-consumed — surfaces as `NothingToRescue`.
        amount = _consumeRescueable(orderDigest, orderId, filler);
        if (amount == 0) revert NothingToRescue();

        IERC20(token).safeTransfer(fallbackDestination, amount);
    }

    /// @notice Resolves the `cellarFiller` value for an `OrderAttribution` emission. The cellar's
    ///         `premiumFiredFor(orderDigest, filler)` view is a trust-boundary call at finalise
    ///         time — wrapped in `try/catch` so a reverting / gas-griefing cellar cannot strand
    ///         dstCST payouts. A caught revert (or `fired == false`) returns `address(0)` — drift
    ///         signal for off-chain consumers, consistent with the "cellar never latched"
    ///         semantic on the premium-hook catch branch. Closes cycle-1 C2.
    /// @param cellar Cellar address bound to the order (Partial: `cellarOf[orderDigest]`; Exact:
    ///        `cellarOf[orderId]`).
    /// @param orderDigest Order binding digest — the key the cellar's `premiumFiredFor` mapping
    ///        expects on both variants.
    /// @param filler Rollover-leg filler identity to probe against the cellar's latch.
    /// @return cellarFiller `filler` on `fired == true`; `address(0)` on `fired == false` or any
    ///         revert from the cellar view.
    function _cellarFillerOf(address cellar, bytes32 orderDigest, address filler)
        internal
        view
        returns (address cellarFiller)
    {
        try ICorkCellarPremiumView(cellar).premiumFiredFor(orderDigest, filler) returns (bool fired) {
            if (fired) cellarFiller = filler;
        } catch {}
    }

    /// @notice Write primitive — zero the native `_rescueable` slot for the concrete's key shape
    ///         and return the prior credit. Concretes override with their native mapping
    ///         (Partial: `_rescueable[orderDigest][filler]`; Exact: `_rescueable[orderId][filler]`).
    ///         Default returns 0 so base-only concretes (e.g. `MockBaseSettler`) stay compilable
    ///         without rescueable storage.
    /// @dev Zero-before-transfer is load-bearing — the payout in `_rescueSettled` runs AFTER this
    ///      hook returns, so a reentrant re-entry on the transfer cannot read a non-zero credit.
    /// @param orderDigest Partial mapping key.
    /// @param orderId Exact mapping key.
    /// @param filler Rollover-leg filler whose credit is being consumed.
    /// @return amount Prior credited amount (pre-zero). A second call for the same pair returns 0.
    function _consumeRescueable(bytes32 orderDigest, bytes32 orderId, address filler)
        internal
        virtual
        returns (uint256 amount)
    {}

    // ═══════════════════════════════════════════════════════════════
    //  Shared terminal-predicate primitive (PR 3 — Task 8)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Shared terminal-transition predicate. Implements the Partial batch-finalise terminal
    ///         predicate (previously the private `_maybeTransitionToTerminal`), promoted here so
    ///         the check is co-located with the other shared filler-escrow primitives.
    /// @dev Exact's terminal path is structurally different — single-participant, no enumeration,
    ///      and `finaliseAsSettled` commits `OrderStatus.Settled` inline after a payment-settled
    ///      precondition. Exact therefore does NOT route through this predicate; the predicate
    ///      governs the Partial batch-finalise flow where the terminal check fires only once every
    ///      filler has been processed.
    ///
    ///      MUST preserve the `participantCount > 0` early-return guard from `fafcf65` (Pashov A1):
    ///      without it an `open` followed immediately by a zero-fill `finaliseAsRefunded` would
    ///      satisfy `refundedCount == participantCount == 0` and drift the order to `Refunded`.
    /// @dev **Cellar trust boundary (closes #49 / Rollover L1 — RFC §9.2 filler trust-boundary
    ///      table).** The Settled-vs-Refunded dispatch below consults
    ///      `_hookPhase0Done(orderDigest)`, which on Partial reads `cellar.hookNonces(orderDigest)
    ///      & 1`. That bit is written by the cellar and is therefore maker-controlled — the settler
    ///      trusts the cellar to honour INV-C14 (permanence of the phase-0 marker) combined with
    ///      INV-C12 (the marker is flipped only on the terminal phase-0 fill). An honest cellar preserves the invariant; a
    ///      compromised or bespoke cellar can force the Settled-vs-Refunded choice of its maker's
    ///      picking. Blast radius is bounded because dstCST destinations are pre-committed at
    ///      phase-0 fill time (`FillerRollover.destination`) — the cellar cannot redirect payouts —
    ///      but the dispatch itself is documented as trust-dependent here rather than replicated as
    ///      a settler-side bit (see #49 suggested fix (a), minimum-intervention path). Any future
    ///      settler that seeks trust independence on the terminal dispatch MUST mirror the
    ///      hook-nonce phase-0 bit locally and use the local copy as ground truth.
    /// @custom:trust-boundary cellar
    /// @param orderDigest Order binding digest (Partial key).
    /// @param orderId Canonical order identifier — used to flip `orderStatus`.
    function _transitionIfTerminal(bytes32 orderDigest, bytes32 orderId) internal {
        uint256 participants = _participantCountOf(orderDigest);
        // Pashov A1 early-return guard — a zero-participant finalise must NEVER transition the
        // order. Checked first so the tautological `0 + 0 == 0` branch below cannot fire.
        if (participants == 0) return;

        uint256 finalised = _finalisedCountOf(orderDigest);
        uint256 refunded = _refundedCountOf(orderDigest);
        if (finalised + refunded != participants) return;
        if (_totalDstCstEscrowedOf(orderDigest) != 0) return;

        if (finalised > 0 && _hookPhase0Done(orderDigest)) {
            orderStatus[orderId] = OrderStatus.Settled;
            _emitOrderFinalised(orderId, OrderStatus.Settled, orderDigest);
        } else if (refunded == participants) {
            orderStatus[orderId] = OrderStatus.Refunded;
            _emitOrderFinalised(orderId, OrderStatus.Refunded, orderDigest);
        }
    }

    /// @notice Emission hook for the concrete-level `OrderFinalised` event. Partial overrides to
    ///         emit its interface event; the default is a no-op so `MockBaseSettler` and any
    ///         base-only concrete stay compilable without an `OrderFinalised` event declaration.
    function _emitOrderFinalised(bytes32, OrderStatus, bytes32) internal virtual {}

    // ═══════════════════════════════════════════════════════════════
    //  Virtual hooks
    // ═══════════════════════════════════════════════════════════════

    /// @notice Per-order participant count — number of fillers that have landed a rollover leg.
    ///         Partial overrides; Exact keeps the default 0 (its single-shot finalise bypasses
    ///         the shared predicate entirely).
    function _participantCountOf(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Per-order count of fillers whose `finaliseAsSettled` entry has landed. Partial
    ///         overrides; Exact keeps the default 0.
    function _finalisedCountOf(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Per-order count of fillers whose `finaliseAsRefunded` entry has landed. Partial
    ///         overrides; Exact keeps the default 0.
    function _refundedCountOf(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Sum of escrowed dstCST across all non-finalised fillers. Reaches zero once every
    ///         filler has been settled or refunded. Partial overrides; Exact keeps the default 0.
    function _totalDstCstEscrowedOf(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Returns whether the cellar has flipped its phase-0 hook-done bit for the order.
    ///         Partial overrides via `ICorkCellar.hookNonces`; Exact keeps the default `false`.
    function _hookPhase0Done(bytes32) internal view virtual returns (bool) {
        return false;
    }

    function _validateOpen(OrderData memory) internal view virtual {}

    function _onRolloverLegFill(GaslessCrossChainOrder memory, OrderData memory, Output memory, bytes calldata)
        internal
        virtual {}

    function _onPremiumLegFill(GaslessCrossChainOrder memory, OrderData memory, Output memory, bytes calldata)
        internal
        virtual {}

    function _onOpenForDecoded(bytes32, OriginFillerData memory) internal virtual {}

    function _onOpenTransitionToOpened(bytes32, bytes32, address) internal virtual {}

    function _validateOriginFillerData(bytes calldata) internal view virtual {}

    /// @notice AS-22 residual-truncation hook (plan-only; not in RFC §6.2). Concretes that
    ///         support multi-fill orders (`Partial`) override to revert with `ResidualTruncates`
    ///         when the incoming rollover leg would leave residual capacity
    ///         `0 < residual < minFillSize`. The `Exact` path keeps the default no-op because
    ///         each order accepts exactly one rollover fill — the residual after a successful
    ///         fill is `0` by construction.
    /// @dev Implementations track per-order cumulative filled amount keyed on `orderId` (not on
    ///      the pre-PR-2 `orderDigest`, which currently omits `minFillSize` / `exclusiveFiller`
    ///      and therefore collides across semantically distinct orders). The caller has already
    ///      verified `od.minFillSize != 0` and that the leg is the rollover leg
    ///      (`outputIndex == 0`).
    /// @param od Decoded `OrderData` for convenience.
    /// @param orderId The canonical order identifier (used as the cumulative-ledger key).
    /// @param fillAmount The rollover leg's incoming `output.amount`.
    function _enforceResidualTruncates(OrderData memory od, bytes32 orderId, uint256 fillAmount)
        internal
        view
        virtual {}

    /// @notice AS-20 decimal-truncation gate (RFC §6.2). Reverts with `DecimalTruncates` when the
    ///         incoming rollover leg's `fillAmount` fails the per-fill pool-decimal-offset modulo
    ///         check. Reads the collateral asset's decimals via
    ///         `IPoolManager.market(od.srcPoolId).collateralAsset` (RFC §6.2 line 2009); a no-op
    ///         when the underlying collateral is 18-decimal (`decimalOffset == 0`).
    /// @dev Caller has already verified the leg is the rollover leg (`outputIndex == 0`). The cST
    ///      token's own `decimals()` is NOT the correct source — per RFC §A.3 the cST wrapper is
    ///      18-decimal on the reference cellar, which would short-circuit the gate for every real
    ///      order and defeat its purpose. The decimal offset comes from the pool's underlying
    ///      collateral (e.g. USDC = 6, WBTC = 8), matching the cellar-side
    ///      `RolloverModule.TruncationDetected` check this gate is paired with.
    /// @param od Decoded `OrderData`; `od.srcCstToken` sources the pool manager via
    ///        `IPoolShare.poolManager()`, and `od.srcPoolId` identifies the market whose
    ///        `collateralAsset` supplies the decimal offset.
    /// @param fillAmount The rollover leg's incoming `output.amount`.
    function _enforceDecimalTruncates(OrderData memory od, uint256 fillAmount) internal view virtual {
        // Cast via `address` to bridge the two `IPoolManager` / `MarketId` types whose import
        // paths differ: `IPoolShare` (phoenix-internal) uses `contracts/interfaces/...` while
        // `OrderData.srcPoolId` is typed via `phoenix/interfaces/...`. Both import paths resolve
        // to the same physical file — the re-cast makes Solidity's type checker accept what is
        // structurally identical.
        address poolManager_ = address(IPoolShare(od.srcCstToken).poolManager());
        address collateralAsset = IPoolManager(poolManager_).market(od.srcPoolId).collateralAsset;
        uint8 decimals_ = IERC20Metadata(collateralAsset).decimals();
        if (decimals_ >= 18) return;
        uint256 factor = 10 ** (18 - decimals_);
        if (fillAmount % factor != 0) revert DecimalTruncates();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Private helpers
    // ═══════════════════════════════════════════════════════════════

    function _resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        internal
        view
        returns (ResolvedCrossChainOrder memory resolved)
    {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        uint256 overrideAmount;
        if (originFillerData.length > 0) {
            overrideAmount = abi.decode(originFillerData, (OriginFillerData)).outputAmount;
        }
        resolved = _buildResolved(order, od, overrideAmount);
    }

    function _buildResolved(GaslessCrossChainOrder memory order, OrderData memory od, uint256 overrideAmount)
        internal
        view
        returns (ResolvedCrossChainOrder memory)
    {
        uint256 len = od.outputs.length;
        Output[] memory outputs = new Output[](len);
        FillInstruction[] memory fills = new FillInstruction[](len);
        bytes32 settler = bytes32(uint256(uint160(address(this))));
        bytes memory originData = abi.encode(order);

        for (uint256 i; i < len; ++i) {
            Output memory out = od.outputs[i];
            outputs[i] = Output({
                token: out.token,
                amount: (i == 0 && overrideAmount > 0) ? overrideAmount : out.amount,
                recipient: out.recipient,
                chainId: out.chainId
            });
            fills[i] =
                FillInstruction({destinationChainId: out.chainId, destinationSettler: settler, originData: originData});
        }

        return ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            orderId: _hashOrder(order),
            maxSpent: outputs,
            minReceived: outputs,
            fillInstructions: fills
        });
    }

    function _isTerminal(OrderStatus status) private pure returns (bool) {
        return status == OrderStatus.Settled || status == OrderStatus.Refunded || status == OrderStatus.Cancelled;
    }
}
