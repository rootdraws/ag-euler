// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, RESCUE_TYPEHASH} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {NothingToRescue, InvalidRescueSignature, InvalidDestination} from "contracts/settlers/BaseSettlerErrors.sol";

/// @dev BTT for `ExactFillSettler.rescueSettled` (PR 6 — closes #44). The mapping is keyed by
///      `orderId`, so every leaf resolves the signed pre-image via `(orderDigest, orderId,
///      fallbackDestination)` and the rescue pull over `_rescueable[orderId][filler]`. A shared
///      `_setupRescueable()` drains the settler's dstToken during `finaliseAsSettled` so the
///      blacklist-catch branch credits `_rescueable` for the rollover filler — the same
///      pre-state PR 5's finalise-side tests exercise.
contract ExactFillSettler_rescueSettled_Test is ExactFillSettlerTestBase {
    Vm.Wallet internal fillerWallet;
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");
    address internal fallbackDestination = makeAddr("fallbackDestination");

    DummyERC20 internal dstToken;

    event FillerRescueWithdrawn(
        bytes32 indexed orderId, address indexed filler, address indexed fallbackDestination, uint256 amount
    );

    function setUp() public override {
        super.setUp();
        fillerWallet = vm.createWallet("filler");
        dstToken = new DummyERC20("DstCST", "DST", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ─── helpers ───────────────────────────────────────────────────

    function _fillRolloverPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address dest)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fd = abi.encodePacked(uint8(0), abi.encode(RolloverFillerData({destination: dest})));
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fd);
    }

    function _fillPremiumPacked(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address debitFrom)
        internal
    {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = abi.encodePacked(uint8(1), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
        vm.prank(filler_);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    function _createOrderWithDistinctDst()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
    }

    /// @dev Drive the order through Opened -> rollover fill -> premium fill -> finaliseAsSettled
    ///      with the settler's dstToken balance drained so the payout reverts and credits
    ///      `_rescueable[orderId][filler]` the full `DEFAULT_PRODUCE_AMOUNT`.
    function _setupRescueable() internal returns (bytes32 orderId, bytes32 orderDigest) {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) = _createOrderWithDistinctDst();
        _openForExact(order, user, repayTo);
        orderId = _computeOrderId(order);
        orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        _fillRolloverPacked(order, fillerWallet.addr, destination);

        vm.prank(fillerWallet.addr);
        premium.setOperator(address(settler), true);

        _fillPremiumPacked(order, fillerWallet.addr, fillerWallet.addr);

        // Drain settler's dstToken balance so the payout transfer reverts.
        uint256 settlerBal = dstToken.balanceOf(address(settler));
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), settlerBal);

        settler.finaliseAsSettled(orderId);

        // Re-mint the rescueable amount back into the settler so `rescueSettled` can transfer it.
        dstToken.mint(address(settler), DEFAULT_PRODUCE_AMOUNT);
    }

    function _signRescue(bytes32 orderDigest, bytes32 orderId, address fallbackDst, uint256 signerPrivateKey)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 structHash = keccak256(abi.encode(RESCUE_TYPEHASH, orderDigest, orderId, fallbackDst));
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", settler.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, eip712Hash);
        sig = abi.encodePacked(r, s, v);
    }

    // ─── when fallbackDestination is zero address ─────────────────

    function test_WhenFallbackDestinationIsZeroAddress() external {
        (bytes32 orderId, bytes32 orderDigest) = _setupRescueable();
        bytes memory sig = _signRescue(orderDigest, orderId, address(0), fillerWallet.privateKey);

        vm.expectRevert(InvalidDestination.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, address(0), sig);
    }

    // ─── when sig is invalid bytes ───────────────────────────────

    function test_WhenSigIsInvalidBytes() external {
        (bytes32 orderId, bytes32 orderDigest) = _setupRescueable();
        bytes memory badSig = hex"deadbeef";

        vm.expectRevert(InvalidRescueSignature.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, badSig);
    }

    // ─── when sig recovers to a non-filler address ───────────────

    function test_WhenSigRecoversToANon_fillerAddress() external {
        (bytes32 orderId, bytes32 orderDigest) = _setupRescueable();

        // Sign with a wallet other than `filler`.
        Vm.Wallet memory notFiller = vm.createWallet("notFiller");
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, notFiller.privateKey);

        vm.expectRevert(InvalidRescueSignature.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }

    // ─── when rescueable slot is zero ─────────────────────────────

    function test_WhenRescueableSlotIsZero() external {
        // Fresh order-ish identifiers with no rescueable credit. The sig-check runs first, so we
        // must sign correctly for the (orderDigest, orderId, fallbackDestination) triple — the
        // revert then comes from the `_consumeRescueable` zero read.
        bytes32 orderId = keccak256("fresh-orderId");
        bytes32 orderDigest = keccak256("fresh-orderDigest");
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        vm.expectRevert(NothingToRescue.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }

    // ─── when all checks pass ─────────────────────────────────────

    function test_WhenAllChecksPass() external {
        (bytes32 orderId, bytes32 orderDigest) = _setupRescueable();

        assertEq(settler.rescueableOf(orderId, fillerWallet.addr), DEFAULT_PRODUCE_AMOUNT, "pre: rescueable credited");

        uint256 settlerBefore = dstToken.balanceOf(address(settler));
        uint256 destBefore = dstToken.balanceOf(fallbackDestination);

        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        vm.expectEmit(true, true, true, true, address(settler));
        emit FillerRescueWithdrawn(orderId, fillerWallet.addr, fallbackDestination, DEFAULT_PRODUCE_AMOUNT);

        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);

        // it should transfer the rescueable amount to fallbackDestination
        assertEq(
            dstToken.balanceOf(fallbackDestination) - destBefore,
            DEFAULT_PRODUCE_AMOUNT,
            "fallbackDestination received dstCst"
        );
        assertEq(
            settlerBefore - dstToken.balanceOf(address(settler)), DEFAULT_PRODUCE_AMOUNT, "settler balance decreased"
        );

        // it should zero the rescueable slot
        assertEq(settler.rescueableOf(orderId, fillerWallet.addr), 0, "rescueable zeroed post-withdraw");
    }

    // ─── when called twice with the same signature ───────────────

    function test_WhenCalledTwiceWithTheSameSignature() external {
        (bytes32 orderId, bytes32 orderDigest) = _setupRescueable();
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);

        // Replay blocked by CEI zeroing inside `_consumeRescueable` — `rescueableOf` reads zero,
        // so the second call reverts `NothingToRescue` rather than double-paying.
        vm.expectRevert(NothingToRescue.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }
}
