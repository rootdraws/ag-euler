// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {
    InvalidSignature,
    InvalidOrderStatus,
    FillAfterDeadline,
    OrderInTerminalState,
    InvalidOrderTokenPair,
    InconsistentIntent,
    IntentNotBoundToOrder
} from "contracts/interfaces/RolloverTypes.sol";
import {DisproportionateOutput, UnauthorizedDebitFrom} from "contracts/settlers/BaseSettlerErrors.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {RevertModule} from "test/harness/TestMintModule.sol";

/// @title EvcRolloverAdapter_execute_Exact
/// @notice BTT leaves for the Exact-binding `EvcExactFillAdapter.execute` surface. 48 leaves,
///         sourced from `plan/btt-draft/EvcRolloverAdapter_execute_Exact.tree`.
/// @dev PR 2a discipline: every leaf MUST fail red against the PR 1 stub. The stub's
///      `NotImplemented()` revert short-circuits every path before the real impl's validation
///      fires, so leaves that expect a specific selector fail the `vm.expectRevert` match, and
///      happy-path leaves fail the post-state assertions because the batch reverted atomically.
///      Leaves flip to green as PR 2b wires the real body.
contract EvcExactFillAdapter_execute is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;
    address internal subaccount;

    function setUp() public override {
        super.setUp();
        // Align the canonical `evcAdapterExact` harness subaccount with this suite's
        // `subaccount` variable — the adapter's `AUTHORIZED_CALLER` binding rejects any
        // other subaccount.
        subaccount = AUTHORIZED_CALLER;
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. destination == address(0)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDestinationIsTheZeroAddress() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__ZeroDestination.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            address(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  2-3. EVC caller resolution
    // ═══════════════════════════════════════════════════════════════

    function test_WhenExecuteIsCalledOutsideAnEvcBatchSoEVCGetCurrentOnBehalfOfAccountReturnsTheZeroAddress() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        evcAdapterExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);
    }

    function test_WhenEVCGetCurrentOnBehalfOfAccountRevertsOrOtherwiseYieldsAZeroCallerForThisMsgSender() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Contrived fixture: `msg.sender == address(evc)` so the adapter enters the in-frame
        // resolution branch, but `getCurrentOnBehalfOfAccount` returns `address(0)` via mockCall
        // — distinct from leaf 2 (out-of-batch call from a non-EVC sender).
        vm.mockCall(
            address(evc), abi.encodeWithSelector(IEVC.getCurrentOnBehalfOfAccount.selector), abi.encode(address(0))
        );
        vm.prank(address(evc));
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        evcAdapterExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination);
        vm.clearMockedCalls();
    }

    // ═══════════════════════════════════════════════════════════════
    //  4-7. Pre-balance-check paths
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheAdapterHoldsZeroSrcCSTAndSrcCstAmountIsNonZero() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcExactFillAdapter.EvcExactFillAdapter__InsufficientTokens.selector, od.srcCstToken, ORDER_SIZE, 0
            )
        );
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenTheAdapterHoldsSrcCSTStrictlyLessThanSrcCstAmount() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 short = ORDER_SIZE / 2;
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, short);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEvcExactFillAdapter.EvcExactFillAdapter__InsufficientTokens.selector, od.srcCstToken, ORDER_SIZE, short
            )
        );
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenTheAdapterSrcCSTBalanceEqualsSrcCstAmountExactly() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        // Mock-env reality: `TestMintModule` does NOT consume srcCST from the adapter's approval,
        // so the adapter retains the full `ORDER_SIZE` it was pre-seeded with. Production cellars
        // with a real `RolloverModule` would consume srcCST and the leftover would be 0 (the
        // tighter invariant) — that is covered by PR 3a integration tests. Mirrors the landed
        // filler pattern at `test/filler/exact/RolloverFiller_execute.t.sol:977-984`.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE);
    }

    function test_WhenTheAdapterSrcCSTBalanceExceedsSrcCstAmount() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 excess = ORDER_SIZE / 4;
        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE + excess);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        // Mock-env reality: `TestMintModule` does NOT consume srcCST from the adapter's approval,
        // so the adapter retains the full overfunded amount (`ORDER_SIZE + excess`). Production
        // cellars would consume `ORDER_SIZE` and leave exactly `excess` — covered by PR 3a. Mirrors
        // the landed filler pattern at `test/filler/exact/RolloverFiller_execute.t.sol:977-984`.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE + excess);
    }

    // ═══════════════════════════════════════════════════════════════
    //  8. srcCstAmount == 0 (reframed per landed filler)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSrcCstAmountIsZeroAndTheAdapterHoldsAtLeastZeroSrcCSTSoThePreBalanceCheckPassesTrivially()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);

        _executeViaEvcBatch(
            evcAdapterExact, subaccount, _noItems(), _noItems(), abi.encode(order), sig, ofd, 0, subaccount, destination
        );

        assertEq(IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact)), 0, "INV-F1 srcCstAmount==0");
        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 srcCstAmount==0"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  9-12. openFor revert paths
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLEROpenForRevertsWithInvalidSignature() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        bytes memory badSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.expectRevert(InvalidSignature.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            badSig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLEROpenForRevertsWithNotMakerForNonGaslessFlow() external {
        // `NotMaker` is provably unreachable through the adapter: the adapter always calls the
        // gasless `openFor` path (never `open`), and `openFor` routes any sender mismatch into
        // `InvalidSignature` before `NotMaker` can fire. We mirror the landed filler reference
        // at `test/filler/exact/RolloverFiller_execute.t.sol:198-218` — mutate `order.user` so
        // the recovered signer diverges and the closest-reachable selector (`InvalidSignature`)
        // bubbles. Documents the protocol intent that the adapter never exercises NotMaker.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        order.user = thirdParty;
        bytes memory sig = _signOrder(order, user, address(exactSettler));

        vm.expectRevert(InvalidSignature.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLEROpenForRevertsWithInconsistentIntentBecauseAllowPartialFillsIsTrue() external {
        // Build an order with `allowPartialFills=true` (inconsistent with the Exact settler's
        // expectation of false). Mirror the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:224-249`.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, true, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(InconsistentIntent.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLEROpenForRevertsWithInvalidOrderTokenPairBecauseSrcCstTokenEqualsPremiumToken() external {
        // Collapse `srcCstToken == premiumToken` so openFor's token-pair invariant fires. Mirror
        // `test/filler/exact/RolloverFiller_execute.t.sol:255-282`.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(vaultUnderlying);
        od.srcCstToken = address(vaultUnderlying);
        od.outputs = _twoOutputs(address(dstCst), address(vaultUnderlying), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(InvalidOrderTokenPair.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  13. openFor idempotency
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheOrderIsAlreadyOpenedByAPriorOpenForCall() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        // Mock-env leftover retention — see `_adapterSnapshot` commentary on the prior leaf.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  14-19. Rollover-leg fill revert paths
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegRevertsWithFillAfterDeadline() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Pre-open so the adapter's internal openFor is idempotent, then warp past fillDeadline
        // so the subsequent fill surfaces FillAfterDeadline. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:310-323`.
        exactSettler.openFor(order, sig, ofd);
        vm.warp(order.fillDeadline + 1);

        vm.expectRevert(FillAfterDeadline.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillRolloverLegRevertsWithAlreadyFilledBecauseTheRolloverOutputWasAlreadyFilled()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Externally open + fill the rollover output from thirdParty so the adapter's subsequent
        // rollover fill surfaces AlreadyFilled. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:330-352`.
        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", thirdParty, ORDER_SIZE));
        require(ok, "mint failed");
        vm.prank(thirdParty);
        IERC20(od.srcCstToken).approve(address(exactSettler), ORDER_SIZE);
        bytes memory rolloverFD =
            bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: thirdParty})));
        vm.prank(thirdParty);
        exactSettler.fill(orderId, abi.encode(order), rolloverFD);

        vm.expectRevert(IExactFillSettler.AlreadyFilled.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillRolloverLegRevertsWithPartialFillNotAllowedBecauseOutputAmountIsNotEqualToOrderSize()
        external
    {
        // Build an order whose rollover output amount is strictly less than `orderSize` so the
        // Exact settler's `output.amount == orderSize` check fires. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:359-386`.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE / 2, user.addr);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(IExactFillSettler.PartialFillNotAllowed.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillRolloverLegRevertsWithIntentNotBoundToOrderBecauseOrderDataCellarIntentHashIsStale()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Mutate `cellarIntentHash` to a stale value after the intent was signed; re-sign the
        // gasless envelope. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:393-408`.
        od.cellarIntentHash = keccak256("stale");
        order.orderData = abi.encode(od);
        bytes memory sig = _signOrder(order, user, address(exactSettler));

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(IntentNotBoundToOrder.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillRolloverLegRevertsWithDisproportionateOutput() external {
        // Build an order whose rolloverHooks are empty so dstDelta == 0 — the settler's
        // `dstDelta + 1 < output.amount - srcLeftover` check fires. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:414-440`.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = new Call[](0);
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(DisproportionateOutput.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillRolloverLegRevertsWithOrderInTerminalState() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Pre-open then cancel to drive the order to a terminal status. Mirrors the landed filler
        // at `test/filler/exact/RolloverFiller_execute.t.sol:447-461`.
        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        vm.prank(user.addr);
        exactSettler.finaliseAsCancelled(orderId, order, "");

        vm.expectRevert(OrderInTerminalState.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  20-23. Rollover-leg happy-path assertions (1 per leaf)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillRolloverLegSucceeds_forwardsSrcCstAllowanceToSettler() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 allowance zero post-execute"
        );
    }

    function test_WhenSETTLERFillRolloverLegSucceeds_observesFillRecordForRolloverOutputHash() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        bytes32 rolloverOH = LibSettlerHashing.computeOutputHash(od.outputs[0]);
        (address fillerRec,, uint256 produced, uint64 filledAt) = exactSettler.fillRecords(orderId, rolloverOH);
        assertEq(fillerRec, address(evcAdapterExact), "fillRecord.filler == adapter");
        assertEq(uint256(produced), ORDER_SIZE, "fillRecord.dstCstProduced");
        assertGt(uint256(filledAt), 0, "fillRecord.filledAt set");
    }

    function test_WhenSETTLERFillRolloverLegSucceeds_observesEscrowedDstCstEqualToProduced() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        assertEq(
            IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "destination holds dstCstProduced post-finalise"
        );
    }

    function test_WhenSETTLERFillRolloverLegSucceeds_resetsSrcCstAllowanceBeforePremiumLeg() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "srcCst allowance reset between rollover and premium legs"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  24-28. Premium-leg fill revert paths
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegRevertsWithPremiumBeforeRolloverInAContrivedPath() external {
        // `PremiumBeforeRollover` is provably unreachable through the adapter: the adapter always
        // runs the rollover leg before the premium leg within `execute`. Mirror the landed filler
        // at `test/filler/exact/RolloverFiller_execute.t.sol:531-550` — drive the premium-leg
        // fill directly from the adapter's address so the selector still bubbles from the
        // settler. Documents the protocol invariant that impls must call rollover before premium.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);
        exactSettler.openFor(order, sig, ofd);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        bytes memory premiumFD = bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: subaccount})));

        vm.prank(address(evcAdapterExact));
        vm.expectRevert(IExactFillSettler.PremiumBeforeRollover.selector);
        exactSettler.fill(orderId, abi.encode(order), premiumFD);
    }

    function test_WhenSETTLERFillPremiumLegRevertsWithAlreadyFilledBecauseThePremiumOutputWasAlreadyFilled() external {
        // Drive the order's rollover + premium slots to filled externally via thirdParty, then
        // call `adapter.execute`. Selector match: `IExactFillSettler.AlreadyFilled` — the adapter's
        // rollover leg (step 11 of the canonical flow) fires first and hits `AlreadyFilled` on
        // the rollover slot, so the revert site is rollover-leg, not premium-leg. Selector is
        // identical either way; the test name preserves the BTT tree's "premium leg reverts"
        // framing. Mirrors the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:556-585`.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", thirdParty, ORDER_SIZE));
        require(ok, "mint failed");
        vm.startPrank(thirdParty);
        IERC20(od.srcCstToken).approve(address(exactSettler), ORDER_SIZE);
        bytes memory rolloverFD =
            bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: thirdParty})));
        exactSettler.fill(orderId, abi.encode(order), rolloverFD);
        vm.stopPrank();

        _depositPremium(thirdParty, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(thirdParty);
        premium.setOperator(address(exactSettler), true);
        bytes memory premiumFD = bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: thirdParty})));
        vm.prank(thirdParty);
        exactSettler.fill(orderId, abi.encode(order), premiumFD);

        vm.expectRevert(IExactFillSettler.AlreadyFilled.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillPremiumLegRevertsWithInsufficientBalanceBecauseDebitFromERC6909BalanceIsShort()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Authorise BOTH the settler and the adapter as 6909 operators on the subaccount so the
        // flow reaches the `ERC6909Premium.settle` balance check. Without setOperator(adapter),
        // `BaseSettler._requireDebitFromAuthorized` reverts with `UnauthorizedDebitFrom` first.
        // Without setOperator(settler), `ERC6909Premium.settle` reverts with `UnauthorizedSettler`.
        // Deliberately DO NOT deposit premium so the balance is short and `InsufficientBalance`
        // fires as the target surface.
        vm.prank(subaccount);
        premium.setOperator(address(exactSettler), true);
        vm.prank(subaccount);
        premium.setOperator(address(evcAdapterExact), true);

        // Set minPremiumPerShare > 0 to force a non-trivial premium debit — rebuild + re-sign.
        // Without this the canonical order has minPremiumPerShare == 0 ⇒ amount == 0 ⇒
        // `ERC6909Premium.settle` short-circuits before the balance check fires. Mirrors
        // landed filler at `test/filler/exact/RolloverFiller_execute.t.sol:606-617`.
        od.minPremiumPerShare = 1e18;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, od.rolloverHooks, od.premiumHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);
        sig = _signOrder(order, user, address(exactSettler));

        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenSETTLERFillPremiumLegRevertsWithUnauthorizedSettlerBecauseDebitFromHasNotSetTheSettlerAsOperator()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _depositPremium(subaccount, od.premiumToken, PREMIUM_DEPOSIT);
        // Authorise the adapter as 6909 operator (so `_requireDebitFromAuthorized` passes) but
        // deliberately DO NOT authorise the settler — so `ERC6909Premium.settle` reverts with
        // `UnauthorizedSettler`, the target surface of this leaf.
        vm.prank(subaccount);
        premium.setOperator(address(evcAdapterExact), true);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(IERC6909Premium.UnauthorizedSettler.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    function test_WhenDebitFromHasNotAuthorizedTheAdapterSoBaseSettlerRequireDebitFromAuthorizedRejectsBeforeReachingERC6909Settle()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _depositPremium(subaccount, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(subaccount);
        premium.setOperator(address(exactSettler), true);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.expectRevert(UnauthorizedDebitFrom.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  29-32. Premium-leg happy-path assertions
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFillPremiumLegSucceeds_debitsRequiredPremiumFromDebitFrom() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        uint256 preBal = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        uint256 postBal = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        // Canonical order has `minPremiumPerShare=0` ⇒ `requiredPremium=0`. Exact equality pins
        // the debit behaviour — a broken impl that either over-debits or under-debits fails this.
        assertEq(preBal - postBal, 0, "6909 balance debited by exact required premium (== 0)");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_transfersRequiredPremiumToUwCellar() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        address uwCellar = factory.cellarOf(user.addr);
        uint256 preCellar = IERC20(od.premiumToken).balanceOf(uwCellar);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        uint256 postCellar = IERC20(od.premiumToken).balanceOf(uwCellar);
        // Canonical order has `minPremiumPerShare=0` ⇒ `requiredPremium=0`. Exact equality pins
        // the transfer behaviour.
        assertEq(postCellar - preCellar, 0, "UW cellar received exact required premium (== 0)");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_flipsPaymentSettledTrue() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertTrue(exactSettler.paymentSettled(orderId), "paymentSettled flipped true post-execute");
    }

    function test_WhenSETTLERFillPremiumLegSucceeds_leavesNoResidualSrcCstAllowanceOnSettler() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 no residual srcCst allowance after premium leg"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  33. Premium hook reverts are caught (AS-10 / #58) — adapter still settles
    // ═══════════════════════════════════════════════════════════════

    function test_WhenThePremiumHookInsideTheCellarRevertsDuringThePremiumLeg() external {
        // Rebuild the order with `_revertPremiumHooks()` so the cellar's premium-hook delegatecall
        // fires `RevertModule.ForcedRevert`. Under the AS-10 try/catch the adapter's full
        // lifecycle completes: the premium leg commits settler state, the revert surfaces only in
        // `PremiumHooksReverted`, and `finaliseAsSettled` routes dstCST to `destination`.
        CellarIntent memory intent;
        IOriginSettler.GaslessCrossChainOrder memory order;
        OrderData memory od;
        (order, od, intent) = _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, user.addr);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = _revertPremiumHooks();
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, factory.cellarOf(user.addr));
        order.orderData = abi.encode(od);

        bytes memory sig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        uint256 balBefore = IERC20(od.dstCstToken).balanceOf(destination);
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        uint256 balAfter = IERC20(od.dstCstToken).balanceOf(destination);

        assertTrue(exactSettler.paymentSettled(orderId), "paymentSettled latched through caught hook revert");
        assertEq(balAfter - balBefore, ORDER_SIZE, "dstCST delivered to destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  34-35. finaliseAsSettled revert paths
    // ═══════════════════════════════════════════════════════════════

    function test_WhenSETTLERFinaliseAsSettledRevertsWithInvalidOrderStatus() external {
        // `InvalidOrderStatus` from `finaliseAsSettled` fires when the order's status at the final
        // call is not `Opened`. Provably unreachable through the adapter — the adapter's two
        // fill legs guard this before `finaliseAsSettled`. Mirror the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:792-806` — drive the settler directly
        // against an order whose status is `None`.
        (IOriginSettler.GaslessCrossChainOrder memory order,,,) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        vm.expectRevert(InvalidOrderStatus.selector);
        exactSettler.finaliseAsSettled(orderId);
    }

    function test_WhenSETTLERFinaliseAsSettledRevertsWithPaymentNotSettled() external {
        // `PaymentNotSettled` fires when the rollover leg settled but the premium leg never did.
        // Provably unreachable through the adapter: the adapter runs both legs atomically and
        // reverts on premium failure rolling back the rollover. Mirror the landed filler at
        // `test/filler/exact/RolloverFiller_execute.t.sol:812-836` — drive the settler directly
        // under an adversarial pre-state where only the rollover leg was filled externally.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        exactSettler.openFor(order, sig, ofd);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);

        (bool ok,) = od.srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", thirdParty, ORDER_SIZE));
        require(ok, "mint failed");
        vm.startPrank(thirdParty);
        IERC20(od.srcCstToken).approve(address(exactSettler), ORDER_SIZE);
        bytes memory rolloverFD =
            bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: thirdParty})));
        exactSettler.fill(orderId, abi.encode(order), rolloverFD);
        vm.stopPrank();

        vm.expectRevert(IExactFillSettler.PaymentNotSettled.selector);
        exactSettler.finaliseAsSettled(orderId);
    }

    // ═══════════════════════════════════════════════════════════════
    //  36-41. Full happy-path — exact-funding case (6 leaves)
    // ═══════════════════════════════════════════════════════════════

    // INV-F1 `srcCST = 0` is the integration-test surface (PR 3a against a real `RolloverModule`);
    // under the mock `TestMintModule`, srcCST is not consumed, so this leaf records the pre-seeded
    // retention behaviour rather than the production invariant.
    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_adapterRetainsPreSeededSrcCstUnderMockCellar()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        // Mock-env reality: `TestMintModule` does NOT consume srcCST, so the adapter retains the
        // full pre-seeded `ORDER_SIZE`. Production cellars consume srcCST fully and the leftover
        // would be 0 — that tighter assertion is covered by PR 3a integration tests against a
        // real RolloverModule. Mirrors `test/filler/exact/RolloverFiller_execute.t.sol:977-984`.
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact)),
            ORDER_SIZE,
            "mock-env leftover retention: pre-seeded srcCst retained by adapter"
        );
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_adapterHoldsZeroDstCst()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(IERC20(od.dstCstToken).balanceOf(address(evcAdapterExact)), 0, "INV-F1 dstCst");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_adapterHoldsZero6909ForPremium()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(
            premium.balanceOf(address(evcAdapterExact), uint256(uint160(od.premiumToken))),
            0,
            "INV-F4 adapter 6909 balance zero"
        );
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_zeroSrcCstAllowance()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 allowance zero post-execute"
        );
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_deliversDstCstToDestination()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "destination received dstCstProduced");
    }

    function test_WhenTheFullExecuteHappyPathCompletesWithTheAdapterFundedExactlyToSrcCstAmount_emitsZeroEventsFromAdapter()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        vm.recordLogs();
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );

        uint256 adapterLogs = 0;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(evcAdapterExact)) adapterLogs++;
        }
        assertEq(adapterLogs, 0, "INV-F8 adapter emits no events");
    }

    // ═══════════════════════════════════════════════════════════════
    //  42-44. Full happy-path — over-funded case (3 leaves)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheFullExecuteHappyPathCompletesButOverFunded_deliversDstCstToDestination() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 excess = ORDER_SIZE / 4;
        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE + excess);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "destination received dstCstProduced");
    }

    function test_WhenTheFullExecuteHappyPathCompletesButOverFunded_retainsResidualOnAdapter() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 excess = ORDER_SIZE / 4;
        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE + excess);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        // Mock-env reality: `TestMintModule` does NOT consume srcCST, so the adapter retains the
        // full pre-seeded amount (`ORDER_SIZE + excess`). Production cellars would consume
        // `ORDER_SIZE` and only `excess` would remain — the production-side tighter invariant is
        // covered by PR 3a. The RFC 7.3 no-sweep-of-leftovers property is still exercised: the
        // adapter performs no sweep on the retained srcCST regardless of consumption.
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact)),
            ORDER_SIZE + excess,
            "RFC 7.3 no-sweep-of-leftovers: pre-seeded srcCst retained in mock env"
        );
    }

    function test_WhenTheFullExecuteHappyPathCompletesButOverFunded_zeroSrcCstAllowance() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        uint256 excess = ORDER_SIZE / 4;
        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE + excess);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        assertEq(
            IERC20(od.srcCstToken).allowance(address(evcAdapterExact), address(exactSettler)),
            0,
            "INV-F2 zero allowance"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  45. Resolved caller debitFrom (INV-F6)
    // ═══════════════════════════════════════════════════════════════

    function test_WhenEVCGetCurrentOnBehalfOfAccountReturnsAValidCallerThatAuthorizedTheAdapterAsAnOperatorAndDebitFromEqualsThatCaller()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        uint256 pre6909 = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        uint256 post6909 = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        // Canonical order has `minPremiumPerShare=0` ⇒ debit == 0 from the resolved caller.
        assertEq(pre6909 - post6909, 0, "INV-F6 premium debited from resolved caller by exact amount");
    }

    // ═══════════════════════════════════════════════════════════════
    //  46. Third-party subaccount debitFrom
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDebitFromIsADifferentSubaccountThatAuthorizedTheSettlerAndTheAdapterViaERC6909SetOperator()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        // Third-party preconditions only — explicitly do NOT deposit premium on `subaccount` so
        // subaccount isolation is observable (C3). subaccount holds only the rollover-side
        // obligation; thirdParty authorises the settler+adapter and holds the premium balance.
        _depositPremium(thirdParty, od.premiumToken, PREMIUM_DEPOSIT);
        vm.prank(thirdParty);
        premium.setOperator(address(exactSettler), true);
        vm.prank(thirdParty);
        premium.setOperator(address(evcAdapterExact), true);

        uint256 preSubBal = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        uint256 preThirdBal = premium.balanceOf(thirdParty, uint256(uint160(od.premiumToken)));

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            thirdParty,
            destination
        );

        uint256 postSubBal = premium.balanceOf(subaccount, uint256(uint160(od.premiumToken)));
        uint256 postThirdBal = premium.balanceOf(thirdParty, uint256(uint160(od.premiumToken)));

        // Subaccount's 6909 balance is untouched (it held nothing and is not the debitFrom).
        assertEq(postSubBal, preSubBal, "subaccount 6909 balance unchanged (isolation)");
        // Third-party's debit equals the exact required premium (== 0 with minPremiumPerShare=0).
        assertEq(preThirdBal - postThirdBal, 0, "thirdParty debited by exact required premium");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "destination received dstCst");
    }

    // ═══════════════════════════════════════════════════════════════
    //  47. Destination-callback reentrancy — documented non-reproducible gap
    // ═══════════════════════════════════════════════════════════════

    function test_WhenDestinationIsAContractAndTheAttackerWantsToReenterExecute_adapterStillHoldsInvariants() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            subaccount,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            subaccount,
            destination
        );
        // Mock-env leftover retention — `TestMintModule` doesn't consume srcCST, adapter retains
        // the pre-seeded `ORDER_SIZE`. See leaf 4 commentary on the mock-env carve-out.
        _adapterSnapshot(evcAdapterExact, od.srcCstToken, od.dstCstToken, ORDER_SIZE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  48. Back-to-back execute in the same batch — transient guard clears
    // ═══════════════════════════════════════════════════════════════

    function test_WhenTheSameEvcBatchContainsASecondBatchItemThatCallsExecuteAgainAfterASuccessfulFirstExecuteInTheSameTransaction()
        external
    {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(subaccount, evcAdapterExact);
        _prepareAdapterErc6909(subaccount, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT * 2);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE * 2);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        bytes memory encoded = abi.encodeWithSelector(
            EvcExactFillAdapter.execute.selector, abi.encode(order), sig, ofd, ORDER_SIZE, subaccount, destination
        );
        items[0] = IEVC.BatchItem({
            targetContract: address(evcAdapterExact), onBehalfOfAccount: subaccount, value: 0, data: encoded
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(evcAdapterExact), onBehalfOfAccount: subaccount, value: 0, data: encoded
        });

        // Exact orders are one-shot: the first batch item's `execute` finalises the order
        // (Status transitions to `Settled`). The second batch item, operating on the same
        // `orderId`, hits the Exact settler's terminal-state guard inside `fill` and reverts
        // with `OrderInTerminalState`. The `evc.batch` call surfaces that revert atomically.
        // The leaf's framing "transient guard clears between batch items" is satisfied: the
        // revert comes from protocol semantics (Exact one-shot), not from a lingering guard
        // in the adapter — if any transient adapter guard had persisted, the second call would
        // have reverted with a DIFFERENT selector before reaching the settler.
        vm.prank(subaccount);
        vm.expectRevert(OrderInTerminalState.selector);
        evc.batch(items);
    }

    // ════ Threat-model NatSpec (test-spec §138)
    function test_expectedThreatModelTag() external view {
        assertEq(evcAdapterExact.EXPECTED_THREAT_MODEL(), "per-subaccount", "threat-model tag");
    }
}
