// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTestSettler} from "test/BaseTestSettler.sol";
import {TestMintModule, RevertModule, ConditionalRevertModule} from "test/harness/TestMintModule.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {BlacklistableERC20} from "test/harness/mocks/BlacklistableERC20.sol";

import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {
    OrderData,
    OriginFillerData,
    RolloverFillerData,
    PremiumFillerData,
    PartialFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH, RESCUE_TYPEHASH} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidSignature, InconsistentIntent} from "contracts/interfaces/RolloverTypes.sol";
import {WrongOriginSettler} from "contracts/settlers/BaseSettlerErrors.sol";

import {CellarIntent, Call, ICorkCellar, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {CorkCellar} from "cellar/CorkCellar.sol";
import {CorkCellarFactory} from "cellar/CorkCellarFactory.sol";

import {AttestationRequest, ModuleType} from "registry/DataTypes.sol";

contract RolloverLifecycleTest is BaseTestSettler {
    TestMintModule internal testMintModule;
    RevertModule internal revertModule;
    DummyERC20 internal premToken;
    DummyERC20 internal dstCst;

    address internal filler1;
    address internal filler2;
    address internal filler3;

    function setUp() public override {
        super.setUp();

        testMintModule = new TestMintModule();
        revertModule = new RevertModule();
        premToken = new DummyERC20("PremiumToken", "PTK", 18);
        dstCst = new DummyERC20("DstCST", "dCST", 18);

        _registerTestModule(address(testMintModule));
        _registerTestModule(address(revertModule));

        filler1 = makeAddr("filler1");
        filler2 = makeAddr("filler2");
        filler3 = makeAddr("filler3");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Abstract implementations
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 h = keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, h);
        return abi.encodePacked(r, s, v);
    }

    function _signOrderWithSmartWallet(IOriginSettler.GaslessCrossChainOrder memory, address, address)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signCancel(bytes32 orderId, uint256 deadline, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 cd = keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, deadline));
        bytes32 h = keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), cd));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, h);
        return abi.encodePacked(deadline, abi.encodePacked(r, s, v));
    }

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory) {
        return SettlerSnapshot(0, 0, 0, 0, 0);
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}

    // ═══════════════════════════════════════════════════════════════
    //  INT-1: Exact fill full lifecycle
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_exactFill_fullLifecycle() public {
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        _openExact(order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Opened));

        _fillExactRollover(order, orderId, filler1, filler1);
        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), DEFAULT_ORDER_SIZE, "escrow after rollover");

        uint256 nonces = userCellar.hookNonces(orderDigest);
        assertEq(nonces & 1, 1, "phase-0 bit set");

        _authorizePremiumFiller(filler1);
        _fillExactPremium(order, orderId, filler1, filler1);
        assertTrue(exactSettler.paymentSettled(orderId));

        uint256 before = IERC20(od.dstCstToken).balanceOf(filler1);
        exactSettler.finaliseAsSettled(orderId);
        uint256 after_ = IERC20(od.dstCstToken).balanceOf(filler1);

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
        assertEq(after_ - before, DEFAULT_ORDER_SIZE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-2: Exact refund after premium dodge
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_exactFill_refundAfterPremiumDodge() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes32 orderId,) =
            _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        _openExact(order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Opened), "status after open");

        _fillExactRollover(order, orderId, filler1, filler1);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Opened), "status after rollover fill");
        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), DEFAULT_ORDER_SIZE, "escrow after rollover");

        vm.warp(order.fillDeadline + 1);

        uint256 before = IERC20(od.dstCstToken).balanceOf(userCellarAddr);
        exactSettler.finaliseAsRefunded(orderId, order);
        uint256 after_ = IERC20(od.dstCstToken).balanceOf(userCellarAddr);

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Refunded));
        assertEq(after_ - before, DEFAULT_ORDER_SIZE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-3: Exact cancel before fill
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_exactFill_cancelBeforeFill() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,, bytes32 orderId,) =
            _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        _openExact(order);

        vm.prank(user.addr);
        exactSettler.finaliseAsCancelled(orderId, order, "");

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Cancelled));
        assertEq(IERC20(od.dstCstToken).balanceOf(address(exactSettler)), 0, "no escrow on cancel");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-3b: Fill before open reverts (cellarOf not set)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_exactFill_fillBeforeOpen() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,, bytes32 orderId,) =
            _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        bytes memory fd = _rolloverFD(filler1);
        vm.prank(filler1);
        vm.expectRevert(CorkCellarFactory.CorkCellarFactory__CellarNotDeployed.selector);
        exactSettler.fill(orderId, abi.encode(order), fd);

        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.None), "status None after reverted fill");

        _openExact(order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Opened), "status Opened after open");

        _fillExactRollover(order, orderId, filler1, filler1);

        _authorizePremiumFiller(filler1);
        _fillExactPremium(order, orderId, filler1, filler1);

        exactSettler.finaliseAsSettled(orderId);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-4a: Partial — two fillers complete, third reverts
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioA_terminalAtFillTwo() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);

        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        uint256 nonces = userCellar.hookNonces(orderDigest);
        assertEq(nonces & 1, 1, "phase-0 bit set");

        bytes memory fd3 = _partialRolloverFD(filler3, od, intent);
        vm.prank(filler3);
        vm.expectRevert(CorkCellar.CorkCellar__PhaseAlreadyConsumed.selector);
        partialSettler.fill(orderId, abi.encode(order), fd3);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-4b: Partial — two fillers, both settle, order settled
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_threeSequentialFills_alternate() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);

        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        _settlePartialPremium(order, orderId, filler1, od, intent);
        _settlePartialPremium(order, orderId, filler2, od, intent);

        uint256 b1 = IERC20(od.dstCstToken).balanceOf(filler1);
        uint256 b2 = IERC20(od.dstCstToken).balanceOf(filler2);

        address[] memory fillers = new address[](2);
        fillers[0] = filler1;
        fillers[1] = filler2;
        partialSettler.finaliseAsSettled(orderDigest, fillers);

        assertEq(partialSettler.participantCount(orderDigest), 2, "participantCount");
        assertEq(IERC20(od.dstCstToken).balanceOf(filler1) - b1, perFill);
        assertEq(IERC20(od.dstCstToken).balanceOf(filler2) - b2, perFill);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-5: Partial underfill flag set (happy path)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioB_underfillMid() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrderUnderfill(S, perFill, true);

        _openPartial(order);

        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        _settlePartialPremium(order, orderId, filler1, od, intent);
        _settlePartialPremium(order, orderId, filler2, od, intent);

        uint256 b1 = IERC20(od.dstCstToken).balanceOf(filler1);
        uint256 b2 = IERC20(od.dstCstToken).balanceOf(filler2);

        address[] memory fillers = new address[](2);
        fillers[0] = filler1;
        fillers[1] = filler2;
        partialSettler.finaliseAsSettled(orderDigest, fillers);

        assertEq(
            IERC20(od.dstCstToken).balanceOf(filler1) - b1 + IERC20(od.dstCstToken).balanceOf(filler2) - b2,
            S,
            "cumulative rolled matches orderSize"
        );
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled));
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-6: Partial expiration mid-fill, refund
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioC_expirationMidFill() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);

        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        vm.warp(order.fillDeadline + 1);

        uint256 before = IERC20(od.dstCstToken).balanceOf(userCellarAddr);
        address[] memory fillers = new address[](2);
        fillers[0] = filler1;
        fillers[1] = filler2;
        partialSettler.finaliseAsRefunded(orderDigest, order, fillers);

        assertEq(IERC20(od.dstCstToken).balanceOf(userCellarAddr) - before, S);
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Refunded));
        assertEq(partialSettler.totalDstCstEscrowed(orderDigest), 0, "escrow cleared after refund");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-7a: Both fillers revert at ceiling
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioD_bothRevertAtCeiling() public {
        uint256 S = 1000e18;
        uint256 perFill = 600e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);

        bytes memory fd2 = _partialRolloverFD(filler2, od, intent);
        vm.prank(filler2);
        vm.expectRevert(CorkCellar.CorkCellar__OverfillCeiling.selector);
        partialSettler.fill(orderId, abi.encode(order), fd2);

        bytes memory fd3 = _partialRolloverFD(filler3, od, intent);
        vm.prank(filler3);
        vm.expectRevert(CorkCellar.CorkCellar__OverfillCeiling.selector);
        partialSettler.fill(orderId, abi.encode(order), fd3);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-7b: One wins after smaller request
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioD_oneWinsSmaller() public {
        uint256 S = 1000e18;
        uint256 perFill = 400e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        bytes memory fd3 = _partialRolloverFD(filler3, od, intent);
        vm.prank(filler3);
        vm.expectRevert(CorkCellar.CorkCellar__OverfillCeiling.selector);
        partialSettler.fill(orderId, abi.encode(order), fd3);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-8: Underfill disallowed — overfill revert
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_scenarioE_underfillDisallowed() public {
        uint256 S = 1000e18;
        uint256 perFill = 800e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);

        bytes memory fd = _partialRolloverFD(filler2, od, intent);
        vm.prank(filler2);
        vm.expectRevert(CorkCellar.CorkCellar__OverfillCeiling.selector);
        partialSettler.fill(orderId, abi.encode(order), fd);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-9: Mixed settle and refund
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_partialFill_mixedSettleAndRefund() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        _settlePartialPremium(order, orderId, filler1, od, intent);

        uint256 b1 = IERC20(od.dstCstToken).balanceOf(filler1);
        address[] memory sf = new address[](1);
        sf[0] = filler1;
        partialSettler.finaliseAsSettled(orderDigest, sf);
        assertEq(IERC20(od.dstCstToken).balanceOf(filler1) - b1, perFill);

        vm.warp(order.fillDeadline + 1);

        uint256 cb = IERC20(od.dstCstToken).balanceOf(userCellarAddr);
        address[] memory rf = new address[](1);
        rf[0] = filler2;
        partialSettler.finaliseAsRefunded(orderDigest, order, rf);
        assertEq(IERC20(od.dstCstToken).balanceOf(userCellarAddr) - cb, perFill);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-9b: USDC-style blacklist mid-order — rescueable credit for the stuck filler,
    //          other fillers still paid, order terminates (#39 closes on the payout loop)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_usdcBlacklistMidOrder() public {
        uint256 S = 1500e18;
        uint256 perFill = 500e18;

        // Replace the default DummyERC20 dstCst with a USDC-style blacklistable mock. The
        // `TestMintModule` mints via `ERC20Mock(token).mint` — `BlacklistableERC20` extends
        // `ERC20Mock`, so the existing mint-hook path still populates the settler escrow.
        BlacklistableERC20 usdcLike = new BlacklistableERC20("BlacklistUSDC", "BUSDC", 18);
        dstCst = DummyERC20(payable(address(usdcLike)));

        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);
        _fillPartialRollover(order, orderId, filler3, od, intent);

        _settlePartialPremium(order, orderId, filler1, od, intent);
        _settlePartialPremium(order, orderId, filler2, od, intent);
        _settlePartialPremium(order, orderId, filler3, od, intent);

        // Blacklist filler3 (the destination chosen by the filler when `_partialRolloverFD`
        // defaults `destination := filler` itself). The finalise-loop payout to filler3 must
        // revert, credit rescueable, and emit FillerRescueCredited while filler1 and filler2
        // are still paid.
        usdcLike.setBlacklisted(filler3, true);

        uint256 b1 = IERC20(od.dstCstToken).balanceOf(filler1);
        uint256 b2 = IERC20(od.dstCstToken).balanceOf(filler2);
        uint256 b3 = IERC20(od.dstCstToken).balanceOf(filler3);

        address[] memory fillers = new address[](3);
        fillers[0] = filler1;
        fillers[1] = filler2;
        fillers[2] = filler3;

        partialSettler.finaliseAsSettled(orderDigest, fillers);

        // Happy fillers paid; blacklisted filler received nothing.
        assertEq(IERC20(od.dstCstToken).balanceOf(filler1) - b1, perFill, "filler1 paid");
        assertEq(IERC20(od.dstCstToken).balanceOf(filler2) - b2, perFill, "filler2 paid");
        assertEq(IERC20(od.dstCstToken).balanceOf(filler3), b3, "filler3 destination unpaid");

        // Rescueable carries the full perFill amount keyed on the blocked filler only.
        assertEq(partialSettler.rescueableOf(orderDigest, filler1), 0, "filler1 no rescueable");
        assertEq(partialSettler.rescueableOf(orderDigest, filler2), 0, "filler2 no rescueable");
        assertEq(partialSettler.rescueableOf(orderDigest, filler3), perFill, "filler3 rescueable credited");

        // Order terminates — the lifecycle is NOT stuck on the blacklist revert.
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order Settled");
        assertEq(partialSettler.totalDstCstEscrowed(orderDigest), 0, "escrow cleared on terminal transition");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-9c: Rescue-after-blacklist — filler pulls stranded credit (PR 6, closes #44)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_rescueAfterBlacklistStrands() public {
        // Continuation of INT-9b's blacklist scenario, but with filler3 materialised as a
        // Vm.Wallet so we can sign the EIP-712 rescue payload with its private key. After
        // `finaliseAsSettled`, `partialSettler.rescueableOf(orderDigest, filler3)` carries the
        // stranded `perFill`; the filler picks a fresh non-blacklisted fallback address and pulls
        // the credit via `rescueSettled`. The mapping must zero in the same call and a second
        // submission of the same signature must revert `NothingToRescue` (replay blocked by CEI).
        uint256 S = 1500e18;
        uint256 perFill = 500e18;

        BlacklistableERC20 usdcLike = new BlacklistableERC20("BlacklistUSDC", "BUSDC", 18);
        dstCst = DummyERC20(payable(address(usdcLike)));

        Vm.Wallet memory filler3Wallet = vm.createWallet("filler3Rescue");
        filler3 = filler3Wallet.addr;

        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(S, perFill, false);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);
        _fillPartialRollover(order, orderId, filler3, od, intent);

        _settlePartialPremium(order, orderId, filler1, od, intent);
        _settlePartialPremium(order, orderId, filler2, od, intent);
        _settlePartialPremium(order, orderId, filler3, od, intent);

        usdcLike.setBlacklisted(filler3, true);

        address[] memory fillers = new address[](3);
        fillers[0] = filler1;
        fillers[1] = filler2;
        fillers[2] = filler3;
        partialSettler.finaliseAsSettled(orderDigest, fillers);

        assertEq(partialSettler.rescueableOf(orderDigest, filler3), perFill, "filler3 rescueable credited");
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order Settled");

        // Filler picks a fresh non-blacklisted destination.
        address fallbackDestination = makeAddr("filler3FreshDestination");
        bytes32 structHash = keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDestination));
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(partialSettler).domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(filler3Wallet.privateKey, eip712Hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 fallbackBefore = IERC20(od.dstCstToken).balanceOf(fallbackDestination);
        partialSettler.rescueSettled(orderDigest, orderId, filler3, fallbackDestination, sig);

        assertEq(
            IERC20(od.dstCstToken).balanceOf(fallbackDestination) - fallbackBefore,
            perFill,
            "fallbackDestination received the rescued dstCst"
        );
        assertEq(partialSettler.rescueableOf(orderDigest, filler3), 0, "rescueable slot zeroed post-withdraw");

        // Replay with the same signature must revert — CEI zeroing makes the second call read 0.
        vm.expectRevert();
        partialSettler.rescueSettled(orderDigest, orderId, filler3, fallbackDestination, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-10: Griefing defense — direct factory call
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_griefingDefense_directFactoryCall() public {
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,,
            bytes32 orderDigest
        ) = _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        _openExact(order);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(CorkCellar.CorkCellar__SettlerMismatch.selector);
        factory.executeIntentHooks(
            userCellarAddr, orderDigest, 0, intent, od.cellarSignature, DEFAULT_ORDER_SIZE, attacker
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-11: Cross-settler sig replay blocked
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_crossSettlerSigReplayBlocked() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,,,) = _buildExactOrder(DEFAULT_ORDER_SIZE, false);

        bytes memory exactSig = _signOrder(order, user, address(exactSettler));
        bytes memory ofd = _buildOriginFillerData(DEFAULT_ORDER_SIZE, filler1);

        vm.expectRevert(WrongOriginSettler.selector);
        partialSettler.openFor(order, exactSig, ofd);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-12: Factory blocklist stops settler
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_factoryBlocklist_stopsSettler() public {
        uint256 S = 1000e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
        ) = _buildPartialOrder(S, S, false);

        _openPartial(order);

        vm.prank(bravo);
        factory.blockSettler(address(partialSettler));

        bytes memory fd = _partialRolloverFD(filler1, od, intent);
        vm.prank(filler1);
        vm.expectRevert(CorkCellarFactory.CorkCellarFactory__SettlerBlocked.selector);
        partialSettler.fill(orderId, abi.encode(order), fd);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-13: Premium hook revert is caught (AS-10 / #58 — try/catch isolates phase-1)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_premiumHooksRevert_caughtAndCommitted() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,, bytes32 orderId,) =
            _buildExactOrderRevertPremium(DEFAULT_ORDER_SIZE);

        _openExact(order);
        _fillExactRollover(order, orderId, filler1, filler1);

        _authorizePremiumFiller(filler1);

        uint256 tokenId = uint256(uint160(address(premToken)));
        uint256 balBefore = premium.balanceOf(filler1, tokenId);

        bytes memory fd = _premiumFD(filler1);
        vm.prank(filler1);
        // Pre-PR-7 this aborted; under the AS-10 try/catch the phase-1 revert is swallowed and
        // `paymentSettled` + ERC-6909 debit stay committed so `finaliseAsSettled` can still run.
        exactSettler.fill(orderId, abi.encode(order), fd);

        assertEq(balBefore - premium.balanceOf(filler1, tokenId), 0, "no premium required at default rate");
        assertTrue(exactSettler.paymentSettled(orderId), "paymentSettled latched despite phase-1 revert");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-13 Partial: Premium hook revert is caught (AS-10 / #58)
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_premiumHooksRevert_caughtAndCommitted_partial() public {
        uint256 S = 1000e18;
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrderRevertPremium(S, S);

        _openPartial(order);
        _fillPartialRollover(order, orderId, filler1, od, intent);

        _authorizePremiumFiller(filler1);

        uint256 tokenId = uint256(uint160(address(premToken)));
        uint256 balBefore = premium.balanceOf(filler1, tokenId);

        bytes memory fd = _partialPremiumFD(filler1, od, intent);
        vm.prank(filler1);
        // Pre-PR-7 this aborted; under the AS-10 try/catch the phase-1 revert is swallowed.
        partialSettler.fill(orderId, abi.encode(order), fd);

        assertEq(balBefore - premium.balanceOf(filler1, tokenId), 0, "no premium required at default rate");
        IPartialFillSettler.FillerRollover memory f = partialSettler.fillerRollovers(orderDigest, filler1);
        assertTrue(f.premiumSettled, "premiumSettled latched despite phase-1 revert");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-13c (PR 7): UW premium hooks conditionally revert — no windfall
    // ═══════════════════════════════════════════════════════════════

    /// @notice Closes AS-10 / #58. Pre-PR-7 a UW who signed `premiumHooks` that reverted on
    ///         some block-number parity turned N rollover-leg srcCST burns into a forced-refund
    ///         windfall at `finaliseAsRefunded` — the fillers forfeited srcCST AND dstCST.
    ///         Under the AS-10 try/catch around the phase-1 forward the fillers' `premiumSettled`
    ///         latches commit regardless of the hook outcome, so `finaliseAsSettled` still routes
    ///         dstCST to both fillers' destinations.
    function test_e2e_premiumHookConditionalRevert_noWindfall() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;
        ConditionalRevertModule condRevert = new ConditionalRevertModule(block.number & 1);
        _registerTestModule(address(condRevert));

        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrderConditionalRevert(S, perFill, address(condRevert));

        _openPartial(order);

        _fillPartialRollover(order, orderId, filler1, od, intent);
        _fillPartialRollover(order, orderId, filler2, od, intent);

        // Premium legs: ConditionalRevertModule is armed with `block.number & 1` at construction,
        // so it reverts on the current block and succeeds on the next. Rolling one block between
        // the two premium fills lands filler1 on the revert parity and filler2 on the success
        // parity — proving `finaliseAsSettled` below routes dstCST correctly for BOTH the caught
        // (phase-1 reverted) and the uncaught (phase-1 succeeded) legs in the same flow.
        _settlePartialPremium(order, orderId, filler1, od, intent);
        vm.roll(block.number + 1);
        _settlePartialPremium(order, orderId, filler2, od, intent);

        // Both filler latches are `true` — finaliseAsSettled can route dstCST to each.
        IPartialFillSettler.FillerRollover memory f1 = partialSettler.fillerRollovers(orderDigest, filler1);
        IPartialFillSettler.FillerRollover memory f2 = partialSettler.fillerRollovers(orderDigest, filler2);
        assertTrue(f1.premiumSettled, "filler1.premiumSettled");
        assertTrue(f2.premiumSettled, "filler2.premiumSettled");

        // Cross the fill deadline; pre-PR-7 the caller would have been forced into
        // `finaliseAsRefunded` and the dstCST would have gone to the cellar as a windfall.
        // Post-PR-7 `finaliseAsSettled` still works because the latches committed.
        vm.warp(order.fillDeadline + 1);

        address[] memory fillers = new address[](2);
        fillers[0] = filler1;
        fillers[1] = filler2;

        uint256 b1 = IERC20(od.dstCstToken).balanceOf(filler1);
        uint256 b2 = IERC20(od.dstCstToken).balanceOf(filler2);
        partialSettler.finaliseAsSettled(orderDigest, fillers);

        assertEq(IERC20(od.dstCstToken).balanceOf(filler1) - b1, perFill, "filler1 receives dstCST");
        assertEq(IERC20(od.dstCstToken).balanceOf(filler2) - b2, perFill, "filler2 receives dstCST");
        assertEq(uint8(partialSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order Settled");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-PR9 (#61 / #63): PREMIUM_FILLER_SLOT cross-checks cellar
    // ═══════════════════════════════════════════════════════════════

    /// @notice End-to-end that the settler writes `pfd.targetFiller` to the
    ///         `PREMIUM_FILLER_SLOT` transient slot before forwarding, and that the cellar's
    ///         `_runPremiumPhase` reads it to cross-check the filler identity — closing the
    ///         #63 / Integ M1 seam. Paired with the #61 / I4 `premiumFiredFor` parity check
    ///         asserted on the settler side.
    /// @dev Skipped until the cellar-side companion PR (cellar-private) lands the `tload`
    ///      read + revert in `_runPremiumPhase`. The settler-side write + parity assertion
    ///      covered by this PR are exercised by the BTT leaves in
    ///      `test/{partial,exact}/*_onPremiumLegFill.t.sol`; this integration leaf is the
    ///      whole-stack smoke that both repos agree on the slot value. Unskip + expand once
    ///      cellar-private has merged its companion.
    function test_e2e_premiumFillerSlotCrossChecksCellar() public {
        // TODO(cellar-private companion): unskip once the cellar-side `_runPremiumPhase` reads
        //      the settler's filler via `ICorkCellarFactory(msg.sender).originatingSettler()` +
        //      `IBaseSettler.premiumFillerSlot()` (the view-accessor seam) and reverts on
        //      mismatch with the factory-relayed `filler` arg. Track via the cross-repo issue
        //      linked from RFC 003 §Integ M1.
        //
        //      Scenario body (to implement on unskip):
        //        1. Run a full happy-path rollover end-to-end through the cellar + settler +
        //           factory: open + phase-0 fill + phase-1 fill + finalise.
        //        2. Assert the settler wrote `targetFiller` to `PREMIUM_FILLER_SLOT` during the
        //           phase-1 window — probe via `BaseSettler.premiumFillerSlot()` mid-forward
        //           (use a test hook or a staged re-entrant probe).
        //        3. Assert the live cellar resolved the settler via
        //           `ICorkCellarFactory.originatingSettler()` and called `premiumFillerSlot()`
        //           on it, comparing the returned filler against the factory-relayed `filler`
        //           arg.
        //        4. Drive a divergent-filler fixture (factory relays filler F1 while the
        //           settler advertised F2 in the slot); assert the cellar reverts with its
        //           filler-mismatch error (e.g. `CellarFillerMismatch` or whatever the
        //           cellar-side name lands as).
        vm.skip(true);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INT-14 (PR 2): RFC 003 issue #41 digest-collision scenario
    // ═══════════════════════════════════════════════════════════════

    /// @notice Pre-PR-2, two partial orders with same maker, pool, and token context but different
    ///         `rolloverHooks` produced the same `computeOrderDigest` and so aliased in
    ///         `orderIdOf[digest]` — a second `openFor` would either be rejected as a duplicate or
    ///         silently overwrite the first order's state. PR 2 binds `rolloverHooks` into the
    ///         digest directly, so the two orders open to distinct digests and distinct
    ///         `orderIdOf` slots.
    function test_e2e_digestCollisionScenario_nowBlocked() public {
        uint256 S = 1000e18;
        uint256 perFill = 500e18;

        (IOriginSettler.GaslessCrossChainOrder memory orderA,,,, bytes32 digestA) =
            _buildPartialOrder(S, perFill, false);

        // Second order: same maker, same nonce, same pool, same tokens, same orderSize — differs
        // only in `rolloverHooks`. `_buildPartialOrderDifferentHooks` replaces the mint-hook with
        // an extra no-op `Call` so the two orders' `rolloverHooks` bytes differ.
        (IOriginSettler.GaslessCrossChainOrder memory orderB,,,, bytes32 digestB) =
            _buildPartialOrderDifferentHooks(S, perFill);

        assertTrue(digestA != digestB, "PR 2: digests must differ when rolloverHooks differ");

        _openPartial(orderA);
        _openPartial(orderB);

        bytes32 orderIdA = LibSettlerHashing.computeOrderId(address(partialSettler), orderA);
        bytes32 orderIdB = LibSettlerHashing.computeOrderId(address(partialSettler), orderB);

        assertEq(partialSettler.orderIdOf(digestA), orderIdA, "digestA -> orderIdA");
        assertEq(partialSettler.orderIdOf(digestB), orderIdB, "digestB -> orderIdB");
        assertTrue(orderIdA != orderIdB, "orderIdOf slots must not alias across different digests");
    }

    /// @dev Sibling builder to `_buildPartialOrder` that swaps in a two-call `rolloverHooks` array
    ///      (mint hook + zero-address no-op). Every other field matches `_buildPartialOrder`
    ///      exactly so the digest difference is attributable solely to the hook list.
    function _buildPartialOrderDifferentHooks(uint256 orderSize, uint256 perFillAmt)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, true, false, address(partialSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = new Call[](2);
        Call[] memory mint = _mintHook(address(partialSettler), address(dstCst));
        rHooks[0] = mint[0];
        // open-only fixture: never filled, second hook contents irrelevant
        rHooks[1] = Call({
            target: address(testMintModule), value: 0, callData: hex"00", allowFailure: true, isDelegateCall: false
        });
        Call[] memory pHooks = new Call[](0);

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), perFillAmt, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(orderDigest, address(partialSettler), orderSize, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Module registration
    // ═══════════════════════════════════════════════════════════════

    function _registerTestModule(address module) internal {
        registry.registerModule(defaultResolverUID, module, "", "");
        ModuleType[] memory mt = new ModuleType[](1);
        mt[0] = ModuleType.wrap(2);
        registry.attest(
            defaultSchemaUID, AttestationRequest({moduleAddress: module, expirationTime: 0, data: "", moduleTypes: mt})
        );
        factory.registerModule(module);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Raw filler data encoders (bytes.concat prefix, NOT abi.encode)
    // ═══════════════════════════════════════════════════════════════

    function _rolloverFD(address dest) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: dest})));
    }

    function _premiumFD(address debitFrom) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
    }

    function _partialRolloverFD(address filler, OrderData memory od, CellarIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: filler,
                    debitFrom: address(0),
                    targetFiller: filler,
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
    }

    function _partialPremiumFD(address filler, OrderData memory od, CellarIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: filler,
                    targetFiller: filler,
                    intent: intent,
                    cellarSig: od.cellarSignature
                })
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Exact order builder
    // ═══════════════════════════════════════════════════════════════

    function _buildExactOrder(uint256 orderSize, bool underfill)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, false, underfill, address(exactSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), orderSize, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(orderDigest, address(exactSettler), orderSize, false, underfill, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
    }

    function _buildExactOrderRevertPremium(uint256 orderSize)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, false, false, address(exactSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](1);
        pHooks[0] = Call({
            target: address(revertModule),
            value: 0,
            callData: abi.encodeCall(RevertModule.execute, ()),
            allowFailure: false,
            isDelegateCall: true
        });

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), orderSize, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(orderDigest, address(exactSettler), orderSize, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Partial order builders
    // ═══════════════════════════════════════════════════════════════

    function _buildPartialOrder(uint256 orderSize, uint256 perFillAmt, bool underfill)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, true, underfill, address(partialSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), perFillAmt, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(orderDigest, address(partialSettler), orderSize, true, underfill, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
    }

    function _buildPartialOrderUnderfill(uint256 orderSize, uint256 perFillAmt, bool underfill)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        return _buildPartialOrder(orderSize, perFillAmt, underfill);
    }

    function _buildPartialOrderRevertPremium(uint256 orderSize, uint256 perFillAmt)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, true, false, address(partialSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](1);
        pHooks[0] = Call({
            target: address(revertModule),
            value: 0,
            callData: abi.encodeCall(RevertModule.execute, ()),
            allowFailure: false,
            isDelegateCall: true
        });

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), perFillAmt, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(orderDigest, address(partialSettler), orderSize, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
    }

    function _buildPartialOrderConditionalRevert(uint256 orderSize, uint256 perFillAmt, address conditional)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        )
    {
        (order, od, intent) = _createRolloverOrder(user, orderSize, true, false, address(partialSettler));

        od.dstCstToken = address(dstCst);
        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](1);
        pHooks[0] = Call({
            target: conditional,
            value: 0,
            callData: abi.encodeCall(ConditionalRevertModule.execute, ()),
            allowFailure: false,
            isDelegateCall: true
        });

        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), perFillAmt, user.addr);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(orderDigest, address(partialSettler), orderSize, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, user, userCellarAddr);
        order.orderData = abi.encode(od);
        orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Shared order-building helpers
    // ═══════════════════════════════════════════════════════════════

    function _mintHook(address settler_, address dstCstToken) internal view returns (Call[] memory hooks) {
        hooks = new Call[](1);
        hooks[0] = Call({
            target: address(testMintModule),
            value: 0,
            callData: abi.encodeCall(TestMintModule.execute, (dstCstToken, settler_)),
            allowFailure: false,
            isDelegateCall: true
        });
    }

    function _twoOutputs(address dstCstToken, address premTkn, uint256 amt, address recipient)
        internal
        view
        returns (IOriginSettler.Output[] memory outputs)
    {
        outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(dstCstToken))),
            amount: amt,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(premTkn))),
            amount: 0,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
    }

    function _buildIntent(
        bytes32 digest,
        address settler_,
        uint256 orderSize,
        bool partialFills,
        bool underfill,
        Call[] memory rHooks,
        Call[] memory pHooks
    ) internal view returns (CellarIntent memory) {
        return CellarIntent({
            orderDigest: digest,
            expectedCaller: address(factory),
            settler: settler_,
            deadline: uint256(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            orderSize: orderSize,
            allowPartialFills: partialFills,
            allowUnderfill: underfill,
            rolloverHooks: rHooks,
            premiumHooks: pHooks
        });
    }

    // ═══════════════════════════════════════════════════════════════
    //  Fill helpers
    // ═══════════════════════════════════════════════════════════════

    function _openExact(IOriginSettler.GaslessCrossChainOrder memory order) internal {
        bytes memory sig = _signOrder(order, user, address(exactSettler));
        exactSettler.openFor(order, sig, _buildOriginFillerData(DEFAULT_ORDER_SIZE, filler1));
    }

    function _openPartial(IOriginSettler.GaslessCrossChainOrder memory order) internal {
        bytes memory sig = _signOrder(order, user, address(partialSettler));
        partialSettler.openFor(order, sig, _buildOriginFillerData(DEFAULT_ORDER_SIZE, filler1));
    }

    function _fillExactRollover(
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes32 orderId,
        address filler,
        address dest
    ) internal {
        vm.prank(filler);
        exactSettler.fill(orderId, abi.encode(order), _rolloverFD(dest));
    }

    function _fillExactPremium(
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes32 orderId,
        address filler,
        address debitFrom
    ) internal {
        vm.prank(filler);
        exactSettler.fill(orderId, abi.encode(order), _premiumFD(debitFrom));
    }

    function _fillPartialRollover(
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes32 orderId,
        address filler,
        OrderData memory od,
        CellarIntent memory intent
    ) internal {
        vm.prank(filler);
        partialSettler.fill(orderId, abi.encode(order), _partialRolloverFD(filler, od, intent));
    }

    function _settlePartialPremium(
        IOriginSettler.GaslessCrossChainOrder memory order,
        bytes32 orderId,
        address filler,
        OrderData memory od,
        CellarIntent memory intent
    ) internal {
        _authorizePremiumFiller(filler);
        vm.prank(filler);
        partialSettler.fill(orderId, abi.encode(order), _partialPremiumFD(filler, od, intent));
    }

    function _authorizePremiumFiller(address filler) internal {
        _depositPremium(filler, address(premToken), 10e18);
        vm.startPrank(filler);
        premToken.approve(address(premium), type(uint256).max);
        premium.setOperator(address(exactSettler), true);
        premium.setOperator(address(partialSettler), true);
        vm.stopPrank();
    }
}
