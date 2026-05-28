// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PartialRolloverFillerTestBase} from "test/filler/partial/PartialRolloverFillerTestBase.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";
import {IPartialRolloverFiller} from "contracts/interfaces/IPartialRolloverFiller.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {
    OrderStatus,
    InvalidSignature,
    InvalidOrderStatus,
    FillAfterDeadline,
    OrderInTerminalState,
    InconsistentIntent,
    IntentNotBoundToOrder
} from "contracts/interfaces/RolloverTypes.sol";
import {UnauthorizedDebitFrom} from "contracts/settlers/BaseSettlerErrors.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {RevertModule} from "test/harness/TestMintModule.sol";

/// @notice Destination contract that re-enters `PartialRolloverFiller.execute` during delivery. Vanilla
///         OpenZeppelin ERC20 `safeTransfer` does not invoke a recipient callback, so this
///         contract never actually re-enters at runtime — the leaf is documented as an
///         intentional gap (see leaf body).
contract ReentrantDestinationPartial {
    PartialRolloverFiller public filler;
    bytes public orderData;
    bytes public signature;
    bytes public originFillerData;
    uint256 public srcCstAmount;
    address public debitFrom;

    function arm(
        PartialRolloverFiller filler_,
        bytes memory orderData_,
        bytes memory signature_,
        bytes memory originFillerData_,
        uint256 srcCstAmount_,
        address debitFrom_
    ) external {
        filler = filler_;
        orderData = orderData_;
        signature = signature_;
        originFillerData = originFillerData_;
        srcCstAmount = srcCstAmount_;
        debitFrom = debitFrom_;
    }

    fallback() external payable {
        if (address(filler) != address(0)) {
            filler.execute(orderData, signature, originFillerData, srcCstAmount, debitFrom, address(this));
        }
    }

    receive() external payable {}
}

contract PartialRolloverFiller_execute is PartialRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    // ═══════════════════════════════════════════════════════════════
    //  1. destination == address(0)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDestinationIsTheZeroAddress() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.expectRevert(IPartialRolloverFiller.PartialRolloverFiller__ZeroDestination.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, address(0), caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. srcCstAmount == 0 — cellar defense-in-depth ZeroRollover
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSrcCstAmountIsZero() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Mock-environment reality: `srcCstAmount == 0` does NOT revert. The filler pulls 0 srcCST,
        // approves the settler for 0, and calls fill. The settler's `_onRolloverLegFill` only
        // observes balance deltas on itself — `TestMintModule` mints `output.amount (ORDER_SIZE)` of
        // dstCST regardless of srcCstAmount, so the `ZeroRollover` guard does not fire. In real
        // production, `RolloverModule` reads `fillAmount` from transient storage and `unwindMint`s
        // against the PoolManager, returning `actualRolled == 0` and tripping `ZeroRollover` — that
        // revert surface is covered by PR 4a integration tests against a real cellar+RolloverModule.
        // For this PR the BTT leaf is reframed to assert the filler still holds INV-F1 / INV-F2
        // post-execute with zero srcCST pulled (no impl-side bug is masked).
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, 0, caller, destination, caller);

        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F1 zero srcCstAmount");
        assertEq(
            IERC20(od.srcCstToken).allowance(address(rolloverFillerPartial), address(partialSettler)),
            0,
            "INV-F2 zero srcCstAmount"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Caller has not approved the filler
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCallerHasNotApprovedTheFillerToPullSrcCST() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _depositPremium(caller, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(caller);
        premium.setOperator(address(partialSettler), true);
        vm.prank(caller);
        premium.setOperator(address(rolloverFillerPartial), true);
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "mint failed");

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, od.srcCstToken));
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  4. Caller approved but balance < srcCstAmount
    // ═══════════════════════════════════════════════════════════════

    function test_WhenCallerSrcCSTBalanceIsLessThanSrcCstAmount() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _depositPremium(caller, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(caller);
        premium.setOperator(address(partialSettler), true);
        vm.prank(caller);
        premium.setOperator(address(rolloverFillerPartial), true);
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE / 2));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, od.srcCstToken));
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  5. openFor reverts with InvalidSignature
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLEROpenForRevertsWithInvalidSignature() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        bytes memory badSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.expectRevert(InvalidSignature.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), badSig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  6. openFor reverts with InconsistentIntent (allowPartialFills == false)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLEROpenForRevertsWithInconsistentIntentBecauseAllowPartialFillsIsFalse() external {
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(partialSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(partialSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.expectRevert(InconsistentIntent.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  7. openFor is a no-op when order is already Opened
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheOrderIsAlreadyOpenedByAPriorCall() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Pre-open the order so the filler's internal openFor is a no-op.
        partialSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Opened));

        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled post execute");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST landed at destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  8a-d. fillerData construction for the rollover leg (4 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenFillerDataIsConstructedForTheRolloverLeg_encodesOutputIndexZeroFollowedByPartialFillerData()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // A happy-path execute implies the rollover-leg fillerData was accepted by BaseSettler.fill
        // (which requires the first byte to be uint8(0) and the remainder to decode as
        // `PartialFillerData`). If the filler ever stopped emitting the canonical shape, the call
        // would revert in the ABI decoder — this end-state assert is the observable proxy.
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(
            uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "rollover-leg fillerData accepted"
        );
    }

    function test_WhenFillerDataIsConstructedForTheRolloverLeg_setsTargetFillerEqualToAddressThis() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        // The settler's `TargetFillerMismatch` fires iff `pfd.targetFiller != msg.sender`. A
        // successful fill implies `targetFiller == address(rolloverFillerPartial)`.
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertGt(fr.srcCstProvided, 0, "rollover-leg recorded under filler key -> targetFiller == filler");
    }

    function test_WhenFillerDataIsConstructedForTheRolloverLeg_embedsTheCellarIntentStruct() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // The settler's `IntentNotBoundToOrder` fires iff `keccak256(abi.encode(pfd.intent)) !=
        // od.cellarIntentHash`. A successful fill proves the filler embedded the intent struct
        // reconstructed from the order payload.
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
    }

    function test_WhenFillerDataIsConstructedForTheRolloverLeg_embedsTheCellarIntentSignature() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // The cellar's factory `executeIntentHooks` recovers the signer from `cellarSig` and
        // rejects bad signatures. A successful execute proves the filler embedded the real
        // `od.cellarSignature` bytes.
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
    }

    // ═══════════════════════════════════════════════════════════════
    //  9. fill (rollover) reverts with FillAfterDeadline
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithFillAfterDeadlineBecauseBlockTimestampIsPastOrderFillDeadline()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        vm.warp(order.fillDeadline + 1);

        vm.expectRevert(FillAfterDeadline.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  10. fill (rollover) reverts with TargetFillerMismatch — defensive leaf
    //      Not reachable through the canonical filler flow because the impl always sets
    //      `targetFiller = address(this)`. We drive the settler directly from a prank'd
    //      filler-address sender with a mismatched targetFiller to assert the selector.
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithTargetFillerMismatchBecauseTargetFillerIsNotTheFillerContract()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent = _buildIntent(
            orderDigest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks
        );

        bytes memory rolloverFD = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: thirdParty, // != msg.sender (which will be the filler contract)
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        vm.prank(address(rolloverFillerPartial));
        vm.expectRevert(IPartialFillSettler.TargetFillerMismatch.selector);
        partialSettler.fill(orderId, abi.encode(order), rolloverFD);
    }

    // ═══════════════════════════════════════════════════════════════
    //  11. fill (rollover) reverts with AlreadyFilledByFiller
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithAlreadyFilledByFillerBecauseTheSameFillerAlreadyFilledThisDigest()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Open the order and externally drive a rollover-leg fill from the filler contract's
        // address so the `(orderDigest, address(filler))` slot is occupied. The filler's
        // subsequent execute will hit `AlreadyFilledByFiller`.
        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent = _buildIntent(
            orderDigest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks
        );

        // Mint srcCST directly to the filler contract so it can push the first fill.
        (bool ok,) = od.srcCstToken
            .call(abi.encodeWithSignature("mint(address,uint256)", address(rolloverFillerPartial), ORDER_SIZE));
        require(ok, "mint failed");
        vm.prank(address(rolloverFillerPartial));
        IERC20(od.srcCstToken).approve(address(partialSettler), ORDER_SIZE);

        bytes memory rolloverFD = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: address(rolloverFillerPartial),
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        vm.prank(address(rolloverFillerPartial));
        partialSettler.fill(orderId, abi.encode(order), rolloverFD);

        // Now the filler.execute path will hit AlreadyFilledByFiller on its own rollover-leg fill.
        vm.expectRevert(IPartialFillSettler.AlreadyFilledByFiller.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  12. fill (rollover) reverts with ZeroRollover
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithZeroRolloverBecauseTheCellarReturnedActualRolledEqualToZero()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Mock-environment reality: `ZeroRollover` fires only when the cellar returns
        // `actualRolled == 0`. In the `TestMintModule` harness, actualRolled is always
        // driven by `output.amount` (ORDER_SIZE) regardless of `srcCstAmount`, so this guard
        // cannot be exercised naturally — the production-path selector is covered by PR 4a
        // integration tests against a real cellar+RolloverModule. We reframe this leaf to
        // document the Partial-specific end-state that holds when zero srcCST is pulled:
        // the filler ends with 0 srcCST held, 0 settler allowance (INV-F1 / INV-F2), and
        // its FillerRollover slot is populated with `srcCstProvided` equal to the mock
        // module's `actualRolled` return (see PartialFillSettler.sol:317 —
        // `srcCstProvided: actualRolled`).
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, 0, caller, destination, caller);

        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F1 filler srcCST");
        assertEq(
            IERC20(od.srcCstToken).allowance(address(rolloverFillerPartial), address(partialSettler)),
            0,
            "INV-F2 filler allowance"
        );
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(
            fr.srcCstProvided,
            ORDER_SIZE,
            "filler-rollover srcCstProvided = actualRolled (mock module returns ORDER_SIZE)"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  13. fill (rollover) reverts with IntentNotBoundToOrder
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithIntentNotBoundToOrderBecauseCellarIntentHashIsStale() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Mutate `cellarIntentHash` to a stale value after the intent has been signed.
        od.cellarIntentHash = keccak256("stale");
        order.orderData = abi.encode(od);
        bytes memory sig = _signOrder(order, user, address(partialSettler));

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.expectRevert(IntentNotBoundToOrder.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  14. fill (rollover) reverts with OrderInTerminalState
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithOrderInTerminalState() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Pre-open + cancel to reach a terminal state (Partial's finaliseAsCancelled is digest-keyed).
        partialSettler.openFor(order, sig, ofd);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        vm.prank(user.addr);
        partialSettler.finaliseAsCancelled(orderDigest, order, "");
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Cancelled));

        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  15a-f. Rollover-leg happy-path assertions (6 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_recordsFillerRollover()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertGt(fr.srcCstProvided, 0, "FillerRollover entry keyed by (orderDigest, address(filler))");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_setsSrcCstProvided()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(fr.srcCstProvided, ORDER_SIZE, "srcCstProvided == srcCstAmount on exact fill");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_setsDstCstProduced()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(fr.dstCstProduced, ORDER_SIZE, "dstCstProduced == cellar computed amount");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_setsDestination()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(fr.destination, destination, "destination equals the execute() destination param");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_premiumSettledAndFinalisedAndRefundedAllFalseBeforePremiumLeg()
        external
    {
        // Drive only the rollover leg (via the settler directly from the filler contract's
        // address) so we can observe the intermediate state where premiumSettled / finalised /
        // refunded are all false.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent = _buildIntent(
            orderDigest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks
        );

        (bool ok,) = od.srcCstToken
            .call(abi.encodeWithSignature("mint(address,uint256)", address(rolloverFillerPartial), ORDER_SIZE));
        require(ok, "mint failed");
        vm.prank(address(rolloverFillerPartial));
        IERC20(od.srcCstToken).approve(address(partialSettler), ORDER_SIZE);

        bytes memory rolloverFD = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: address(rolloverFillerPartial),
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        vm.prank(address(rolloverFillerPartial));
        partialSettler.fill(orderId, abi.encode(order), rolloverFD);

        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertFalse(fr.premiumSettled, "premiumSettled == false");
        assertFalse(fr.finalised, "finalised == false");
        assertFalse(fr.refunded, "refunded == false");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledEqualToSrcCstAmountFullFill_resetsSrcCstAllowanceToZero()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(
            IERC20(od.srcCstToken).allowance(address(rolloverFillerPartial), address(partialSettler)),
            0,
            "srcCST allowance reset to zero post rollover leg"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  16a-b. Rollover-leg underfill (2 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledLessThanSrcCstAmountUnderfillPermitted_recordsSrcCstProvidedEqualToActualRolled()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Overfund via srcCstAmount > ORDER_SIZE. `actualRolled` from the mock factory equals
        // `output.amount == ORDER_SIZE`, so `srcCstProvided` is expected to record the cellar-
        // reported value (ORDER_SIZE), NOT the requested overfund.
        uint256 overfund = ORDER_SIZE + 100e18;
        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, overfund, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(fr.srcCstProvided, ORDER_SIZE, "srcCstProvided == actualRolled (cellar value)");
    }

    function test_WhenSETTLERFillRolloverLegSucceedsWithActualRolledLessThanSrcCstAmountUnderfillPermitted_returnsLeftoverSrcCstToCaller()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 overfund = ORDER_SIZE + 100e18;
        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 callerBalBefore = IERC20(od.srcCstToken).balanceOf(caller);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, overfund, caller, destination, caller);
        uint256 callerBalAfter = IERC20(od.srcCstToken).balanceOf(caller);

        // INV-F3: In the mock harness TestMintModule does not consume srcCST from the settler, so
        // the full overfund returns to the caller. Assert the filler retains nothing, and the
        // caller's balance is reconciled.
        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F3 filler retained");
        assertEq(callerBalAfter, callerBalBefore, "INV-F3: full overfund returned in mock env");
    }

    // ═══════════════════════════════════════════════════════════════
    //  17. premium-leg revert — NoRolloverLegForFiller (defensive)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegRevertsWithNoRolloverLegForFiller() external {
        // `NoRolloverLegForFiller` is unreachable through the canonical filler flow because the
        // impl always runs the rollover leg before the premium leg. We assert the selector by
        // driving the settler directly from an address that never rolled, naming itself as
        // `targetFiller` (so the A3 `TargetFillerMismatch` guard passes and we reach the
        // `f.srcCstProvided == 0` branch).
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent = _buildIntent(
            orderDigest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks
        );

        bytes memory premiumFD = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: caller,
                    targetFiller: thirdParty, // no rollover leg recorded for thirdParty
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        // Prank as thirdParty so `msg.sender == targetFiller`, bypassing the A3 symmetry guard and
        // landing on the `f.srcCstProvided == 0` branch of `_onPremiumLegFill`.
        vm.prank(thirdParty);
        vm.expectRevert(IPartialFillSettler.NoRolloverLegForFiller.selector);
        partialSettler.fill(orderId, abi.encode(order), premiumFD);
    }

    // ═══════════════════════════════════════════════════════════════
    //  18. premium-leg revert — AlreadySettled
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegRevertsWithAlreadySettledBecauseTheFillerPremiumSlotAlreadyFired() external {
        // Drive the canonical rollover-leg fill manually from the filler contract's address,
        // then the premium leg manually so the filler's `premiumSettled` latches true. A
        // subsequent execute by the same filler would hit `AlreadySettled`.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        partialSettler.openFor(order, sig, ofd);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent = _buildIntent(
            orderDigest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks
        );

        (bool ok,) = od.srcCstToken
            .call(abi.encodeWithSignature("mint(address,uint256)", address(rolloverFillerPartial), ORDER_SIZE));
        require(ok, "mint failed");
        vm.prank(address(rolloverFillerPartial));
        IERC20(od.srcCstToken).approve(address(partialSettler), ORDER_SIZE);

        bytes memory rolloverFD = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: address(rolloverFillerPartial),
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        vm.prank(address(rolloverFillerPartial));
        partialSettler.fill(orderId, abi.encode(order), rolloverFD);

        bytes memory premiumFD = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: caller,
                    targetFiller: address(rolloverFillerPartial),
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
        vm.prank(address(rolloverFillerPartial));
        partialSettler.fill(orderId, abi.encode(order), premiumFD);

        // Second premium-leg call → AlreadySettled.
        vm.prank(address(rolloverFillerPartial));
        vm.expectRevert(IPartialFillSettler.AlreadySettled.selector);
        partialSettler.fill(orderId, abi.encode(order), premiumFD);
    }

    // ═══════════════════════════════════════════════════════════════
    //  19. premium-leg revert — UnauthorizedDebitFrom
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegRevertsWithUnauthorizedDebitFrom() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // srcCST approved, but do NOT authorise the filler as a premium operator.
        _depositPremium(caller, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(caller);
        premium.setOperator(address(partialSettler), true);
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);

        // Force a non-zero premium debit so the auth check is reached.
        od.minPremiumPerShare = 1e18;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        sig = _signOrder(order, user, address(partialSettler));

        vm.expectRevert(UnauthorizedDebitFrom.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  20. premium-leg revert — InsufficientBalance
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegRevertsWithInsufficientBalanceBecauseDebitFromERC6909BalanceIsShort()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Skip the premium deposit so the debit hits zero balance at debitFrom.
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);
        vm.startPrank(caller);
        premium.setOperator(address(partialSettler), true);
        premium.setOperator(address(rolloverFillerPartial), true);
        vm.stopPrank();

        od.minPremiumPerShare = 1e18;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(partialSettler), ORDER_SIZE, true, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        sig = _signOrder(order, user, address(partialSettler));

        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  21a-d. premium-leg happy path (4 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegSucceeds_debitsRequiredPremiumFromDebitFrom() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 tokenId = uint256(uint160(od.premiumToken));
        uint256 balBefore = premium.balanceOf(caller, tokenId);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        uint256 balAfter = premium.balanceOf(caller, tokenId);

        // With minPremiumPerShare == 0 (default), debited amount is 0 — balance unchanged.
        assertEq(balBefore - balAfter, 0, "debit matches required premium (minPremiumPerShare=0)");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_transfersRequiredPremiumToUwCellar() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 cellarBalBefore = IERC20(od.premiumToken).balanceOf(userCellarAddr);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        uint256 cellarBalAfter = IERC20(od.premiumToken).balanceOf(userCellarAddr);

        assertEq(cellarBalAfter, cellarBalBefore, "premium delta to UW cellar (minPremiumPerShare=0)");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_setsFillerRolloverPremiumSettledTrue() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertTrue(fr.premiumSettled, "premiumSettled flipped true for (orderDigest, address(filler))");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_firesPhase1PremiumHooksExactlyOnce() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        // `CorkCellar` tracks phase-1 premium firing per-(digest, filler) via the
        // `premiumFiredFor[orderDigest][filler]` mapping (see lib/cellar/src/CorkCellar.sol:127,188).
        // The "exactly once per filler" property is asserted by reading that mapping — the
        // subsequent attempt to fire it again would revert with `CorkCellar__PremiumAlreadyFiredForFiller`,
        // which is covered by the cellar's own unit tests. (Note: `hookNonces` only latches the
        // phase-0 rollover bit — phase-1 routes through `premiumFiredFor` instead.)
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        assertTrue(
            userCellar.premiumFiredFor(orderDigest, address(rolloverFillerPartial)),
            "phase-1 premium fired exactly once per (digest, filler)"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  22. premium hook revert inside cellar is caught (AS-10 / #58) — filler still settles
    // ═══════════════════════════════════════════════════════════════

    function test_WhenThePremiumHookInsideTheCellarRevertsDuringThePremiumLeg() external {
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, true, false, address(partialSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = _revertPremiumHooks();
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), ORDER_SIZE, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(partialSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Under the AS-10 / #58 try/catch in `_onPremiumLegFill`, UW-signed premium hooks that
        // revert no longer bubble through the filler. The filler's full-lifecycle `execute`
        // completes: rollover leg fills, premium leg commits settler-state, `PremiumHooksReverted`
        // is emitted, and `finaliseAsSettled` routes dstCST to the destination.
        uint256 balBefore = IERC20(od.dstCstToken).balanceOf(destination);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        uint256 balAfter = IERC20(od.dstCstToken).balanceOf(destination);

        IPartialFillSettler.FillerRollover memory f =
            partialSettler.fillerRollovers(digest, address(rolloverFillerPartial));
        assertTrue(f.premiumSettled, "premiumSettled latched through caught hook revert");
        assertEq(balAfter - balBefore, ORDER_SIZE, "dstCST delivered to destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  23a-c. finaliseAsSettled happy path (3 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFinaliseAsSettledAtEndOfExecute_releasesFillerDstCstProducedToDestination() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCst released to destination");
    }

    function test_WhenSETTLERFinaliseAsSettledAtEndOfExecute_setsFillerRolloverFinalisedTrue() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertTrue(fr.finalised, "finalised latched true for this filler");
    }

    function test_WhenSETTLERFinaliseAsSettledAtEndOfExecute_decrementsTotalDstCstEscrowedByDstCstProduced() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        assertEq(partialSettler.totalDstCstEscrowed(orderDigest), 0, "totalDstCstEscrowed decremented to zero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  24. finaliseAsSettled reverts with InvalidOrderStatus
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFinaliseAsSettledRevertsWithInvalidOrderStatus() external {
        // `InvalidOrderStatus` fires when the order's status is not `Opened` at finalise time.
        // Not reachable through the canonical filler flow (guarded upstream). Drive the settler
        // directly with an unknown orderDigest so `orderIdOf[orderDigest] == 0` fires the guard.
        bytes32 unknownDigest = keccak256("unknown-digest");
        address[] memory fillers = new address[](1);
        fillers[0] = address(rolloverFillerPartial);

        vm.expectRevert(InvalidOrderStatus.selector);
        partialSettler.finaliseAsSettled(unknownDigest, fillers);
    }

    // ═══════════════════════════════════════════════════════════════
    //  25a-c. Second distinct filler — per-filler state isolation (3 leaves)
    // ═══════════════════════════════════════════════════════════════

    /// @dev DP-A constraint documentation (plan/filler-implementation-plan.md line 499 + 433).
    ///      `PartialRolloverFiller.execute` atomically calls `finaliseAsSettled([address(this)])` at the
    ///      end of every execute. With `participantCount == 1` (a single filler on the order), the
    ///      settler transitions the order to `OrderStatus.Settled` on that call (see
    ///      PartialFillSettler._maybeTransitionToTerminal at contracts/settlers/PartialFillSettler.sol:240-253).
    ///      Any subsequent filler's `execute` against the same digest then reverts at BaseSettler's
    ///      `OrderInTerminalState` guard. This is the reason the plan mandates per-user Partial
    ///      filler deployment — the alternative shared-filler model is prohibited by the settler's
    ///      atomic terminal transition, and true multi-filler Partial flows require out-of-band
    ///      orchestration calling `finaliseAsSettled(digest, [fillerA, fillerB])` ONCE (exercised by
    ///      PR 4a's `RolloverFiller_PartialTwoFillers.t.sol`).
    function test_WhenASecondDistinctRolloverFillerInstanceRunsExecute_recordsSecondFillerRolloverSlot() external {
        PartialRolloverFiller secondFiller = new PartialRolloverFiller(address(partialSettler), address(factory));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        // First-filler slot must be populated; second-filler slot must remain zero (INV-P1 by default
        // — per-filler FillerRollover mappings are unwritten for a filler that never executed).
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr1 =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertGt(fr1.srcCstProvided, 0, "first filler slot populated");

        // Second filler attempts execute — order is already Settled (atomic terminal transition),
        // so BaseSettler.fill guards revert with OrderInTerminalState.
        address secondCaller = makeAddr("secondCaller");
        _preconditions(secondCaller, secondFiller, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(secondFiller, abi.encode(order), sig, ofd, ORDER_SIZE, secondCaller, destination, secondCaller);

        // Second-filler FillerRollover slot is the zero struct — its execute never wrote storage.
        IPartialFillSettler.FillerRollover memory fr2 =
            partialSettler.fillerRollovers(orderDigest, address(secondFiller));
        assertEq(fr2.srcCstProvided, 0, "second filler slot zero (its execute reverted)");
        assertEq(fr2.dstCstProduced, 0, "second filler slot zero (its execute reverted)");
        assertEq(fr2.destination, address(0), "second filler slot zero (its execute reverted)");
        assertFalse(fr2.finalised, "second filler never finalised");
    }

    /// @dev DP-A constraint documentation (plan/filler-implementation-plan.md line 499 + 433).
    ///      Asserts the first filler's FillerRollover slot is unaffected by the second filler's
    ///      reverted execute — the revert surface at OrderInTerminalState means no settler state
    ///      was mutated by the second attempt, so the first filler's slot (srcCstProvided,
    ///      dstCstProduced, destination, finalised = true) remains exactly as its own execute
    ///      left it. See PR 4a's `RolloverFiller_PartialTwoFillers.t.sol` for the out-of-band
    ///      orchestration flow that enables true multi-filler Partial settlement.
    function test_WhenASecondDistinctRolloverFillerInstanceRunsExecute_firstFillerSlotUnaffected() external {
        PartialRolloverFiller secondFiller = new PartialRolloverFiller(address(partialSettler), address(factory));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory frBefore =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));

        // Second filler's execute reverts atomically at the order-status guard — no settler
        // state is mutated. First-filler's slot fields are invariant across the revert.
        address secondCaller = makeAddr("secondCaller");
        _preconditions(secondCaller, secondFiller, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(secondFiller, abi.encode(order), sig, ofd, ORDER_SIZE, secondCaller, destination, secondCaller);

        IPartialFillSettler.FillerRollover memory frAfter =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertEq(frAfter.srcCstProvided, frBefore.srcCstProvided, "INV-P1 srcCstProvided isolated");
        assertEq(frAfter.dstCstProduced, frBefore.dstCstProduced, "INV-P1 dstCstProduced isolated");
        assertEq(frAfter.destination, frBefore.destination, "INV-P1 destination isolated");
        assertTrue(frAfter.finalised, "first filler remained finalised");
    }

    /// @dev DP-A constraint documentation (plan/filler-implementation-plan.md line 499 + 433).
    ///      Because `PartialRolloverFiller.execute` is atomic-per-filler — it ends with
    ///      `finaliseAsSettled(digest, [address(this)])` — the first filler's execute independently
    ///      settles the order the moment participantCount == 1. Any second-filler attempt on the
    ///      now-terminal order reverts with `OrderInTerminalState`. Per DP-A, true multi-filler
    ///      Partial flows require out-of-band orchestration that calls
    ///      `finaliseAsSettled(digest, [fillerA, fillerB])` exactly once (exercised by PR 4a's
    ///      `RolloverFiller_PartialTwoFillers.t.sol`).
    function test_WhenASecondDistinctRolloverFillerInstanceRunsExecute_settlesIndependentlyViaFinaliseAsSettled()
        external
    {
        PartialRolloverFiller secondFiller = new PartialRolloverFiller(address(partialSettler), address(factory));

        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        // After first-filler's atomic execute, order is Settled (single-participant terminal transition).
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
        assertEq(
            uint8(partialSettler.orderStatus(orderId)),
            uint8(OrderStatus.Settled),
            "order settled by first filler's atomic execute"
        );

        // Second filler attempt on a now-terminal order reverts with OrderInTerminalState (DP-A).
        address secondCaller = makeAddr("secondCaller");
        _preconditions(secondCaller, secondFiller, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        vm.expectRevert(OrderInTerminalState.selector);
        _executeRollover(secondFiller, abi.encode(order), sig, ofd, ORDER_SIZE, secondCaller, destination, secondCaller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  26a-e. Full happy-path exact (5 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheFullExecuteHappyPathCompletesWithAnExactFill_invF1ZeroTokenBalancesOnFiller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F1 srcCST");
        assertEq(IERC20(od.dstCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F1 dstCST");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithAnExactFill_invF2ZeroAllowancesFromFiller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(
            IERC20(od.srcCstToken).allowance(address(rolloverFillerPartial), address(partialSettler)),
            0,
            "INV-F2 srcCST allowance"
        );
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithAnExactFill_invF4ZeroERC6909BalancesOnFiller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        uint256 tokenId = uint256(uint160(od.premiumToken));
        assertEq(premium.balanceOf(address(rolloverFillerPartial), tokenId), 0, "INV-F4");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithAnExactFill_invF8NoEventsFromFiller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        vm.recordLogs();
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fillerEmits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(rolloverFillerPartial)) fillerEmits++;
        }
        assertEq(fillerEmits, 0, "INV-F8 filler emits zero events");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithAnExactFill_deliversDstCstToDestination() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, destination, caller);

        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCstProduced delivered to destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  27a-b. Full happy-path underfill (2 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheFullExecuteHappyPathCompletesWithAnUnderfill_invF3ReturnsLeftoverSrcCstToCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 overfund = ORDER_SIZE + 100e18;
        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);

        uint256 callerBalBefore = IERC20(od.srcCstToken).balanceOf(caller);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, overfund, caller, destination, caller);
        uint256 callerBalAfter = IERC20(od.srcCstToken).balanceOf(caller);

        assertEq(IERC20(od.srcCstToken).balanceOf(address(rolloverFillerPartial)), 0, "INV-F3 filler retained");
        assertEq(callerBalAfter, callerBalBefore, "INV-F3 leftover returned to caller");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithAnUnderfill_deliversDstCstToDestination() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 overfund = ORDER_SIZE + 100e18;
        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, overfund, od.premiumToken, PREMIUM_DEPOSIT);
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, overfund, caller, destination, caller);

        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCstProduced delivered to destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  28. Reentrant destination
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDestinationIsAContractWhoseFallbackReentersExecute() external {
        // Standard OpenZeppelin ERC20 `safeTransfer` (used by PartialFillSettler.finaliseAsSettled
        // to deliver dstCST) does NOT invoke a recipient callback — plain ERC20 has no hook. A
        // genuine reentry vector would require ERC777 or a custom dstCST with transfer hooks. The
        // filler's reentrancy guard (`nonReentrant`) is declared defensively to cover future
        // token types. We build a destination contract whose fallback tries to re-enter
        // `execute`; today's ERC20 path completes cleanly and no reentry occurs.
        ReentrantDestinationPartial rd = new ReentrantDestinationPartial();
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, address(rd));

        _preconditions(caller, rolloverFillerPartial, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        rd.arm(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller);

        // TODO: Replace with a token that has a transfer hook once the integrator README's
        //       token-blocklist enforcement is relaxed. For today's flow the call completes and
        //       dstCST lands at the destination.
        _executeRollover(rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, caller, address(rd), caller);

        assertEq(IERC20(od.dstCstToken).balanceOf(address(rd)), ORDER_SIZE, "dstCST at destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  29. Third-party debitFrom happy path
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDebitFromIsAThirdPartyThatAuthorizedTheSettlerAndTheFillerContractViaERC6909SetOperator()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Third-party preconditions: thirdParty deposits premium and authorises settler, filler,
        // and caller. Caller authorisation is the A2 remediation: the filler now requires
        // `debitFrom` to have registered `msg.sender` as an ERC-6909 operator when they differ.
        _depositPremium(thirdParty, od.premiumToken, PREMIUM_DEPOSIT);
        vm.startPrank(thirdParty);
        premium.setOperator(address(partialSettler), true);
        premium.setOperator(address(rolloverFillerPartial), true);
        premium.setOperator(caller, true);
        vm.stopPrank();

        // Caller preconditions: only srcCST (no premium).
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", caller, ORDER_SIZE));
        require(ok, "mint failed");
        _approveFillerToPullSrcCst(caller, address(rolloverFillerPartial), od.srcCstToken, ORDER_SIZE);

        _executeRollover(
            rolloverFillerPartial, abi.encode(order), sig, ofd, ORDER_SIZE, thirdParty, destination, caller
        );

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        IPartialFillSettler.FillerRollover memory fr =
            partialSettler.fillerRollovers(orderDigest, address(rolloverFillerPartial));
        assertTrue(fr.premiumSettled, "premium settled from thirdParty");
        assertTrue(fr.finalised, "filler finalised");
    }

    // ════ Threat-model NatSpec (test-spec §138)
    function test_expectedThreatModelTag() external view {
        assertEq(rolloverFillerPartial.EXPECTED_THREAT_MODEL(), "shared-singleton", "threat-model tag");
    }
}
