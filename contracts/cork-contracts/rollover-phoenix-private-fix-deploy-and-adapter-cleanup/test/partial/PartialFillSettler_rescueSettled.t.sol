// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, RESCUE_TYPEHASH} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {NothingToRescue, InvalidRescueSignature, InvalidDestination} from "contracts/settlers/BaseSettlerErrors.sol";

/// @dev BTT for `PartialFillSettler.rescueSettled` (PR 6 — closes #44). Mirror of the Exact
///      rescue tree but keyed on `orderDigest`; `_rescueable[orderDigest][filler]` is credited by
///      `finaliseAsSettled`'s blacklist-catch branch after the dstToken balance is drained.
contract PartialFillSettler_rescueSettled_Test is PartialFillSettlerTestBase {
    Vm.Wallet internal fillerWallet;
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");
    address internal fallbackDestination = makeAddr("fallbackDestination");

    DummyERC20 internal dstToken;
    DummyERC20 internal premToken;

    event FillerRescueWithdrawn(
        bytes32 indexed orderDigest, address indexed filler, address indexed fallbackDestination, uint256 amount
    );

    function setUp() public override {
        super.setUp();
        fillerWallet = vm.createWallet("filler");
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premToken = new DummyERC20("Premium", "PREM", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ─── helpers ───────────────────────────────────────────────────

    function _fillRolloverPacked(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address filler_,
        address dest,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: dest, debitFrom: address(0), targetFiller: filler_, intent: intent, cellarSig: ""
                })
            )
        );
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), fillerData);
    }

    function _fillPremiumPacked(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address targetFiller,
        address premiumPayer,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: premiumPayer,
                    targetFiller: targetFiller,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
        vm.prank(premiumPayer);
        settler.fill(oid, abi.encode(order), fillerData);
    }

    function _createOrderWithDistinctDst()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premToken);

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
    }

    /// @dev Drive the order through Opened -> rollover fill -> premium fill -> finaliseAsSettled
    ///      with the settler's dstToken balance drained so the payout reverts and credits
    ///      `_rescueable[orderDigest][filler]` the full `DEFAULT_PRODUCE_AMOUNT`.
    function _setupRescueable() internal returns (bytes32 orderDigest, bytes32 orderId) {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        _fillRolloverPacked(order, fillerWallet.addr, destination, intent);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
        vm.prank(fillerWallet.addr);
        premium.setOperator(address(settler), true);
        _depositPremium(fillerWallet.addr, od.premiumToken, 10e18);

        _fillPremiumPacked(order, fillerWallet.addr, fillerWallet.addr, intent);

        orderDigest = _computeOrderDigest(order);
        orderId = _computeOrderId(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Drain the settler's dstToken balance so the payout reverts and books a rescueable
        // credit via `FillerRescueCredited`.
        uint256 settlerBal = dstToken.balanceOf(address(settler));
        vm.prank(address(settler));
        dstToken.transfer(address(0xdead), settlerBal);

        address[] memory fillers = new address[](1);
        fillers[0] = fillerWallet.addr;
        settler.finaliseAsSettled(orderDigest, fillers);

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
        (bytes32 orderDigest, bytes32 orderId) = _setupRescueable();
        bytes memory sig = _signRescue(orderDigest, orderId, address(0), fillerWallet.privateKey);

        vm.expectRevert(InvalidDestination.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, address(0), sig);
    }

    // ─── when sig is invalid bytes ───────────────────────────────

    function test_WhenSigIsInvalidBytes() external {
        (bytes32 orderDigest, bytes32 orderId) = _setupRescueable();
        bytes memory badSig = hex"deadbeef";

        vm.expectRevert(InvalidRescueSignature.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, badSig);
    }

    // ─── when sig recovers to a non-filler address ───────────────

    function test_WhenSigRecoversToANon_fillerAddress() external {
        (bytes32 orderDigest, bytes32 orderId) = _setupRescueable();

        Vm.Wallet memory notFiller = vm.createWallet("notFiller");
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, notFiller.privateKey);

        vm.expectRevert(InvalidRescueSignature.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }

    // ─── when rescueable slot is zero ─────────────────────────────

    function test_WhenRescueableSlotIsZero() external {
        bytes32 orderId = keccak256("fresh-orderId");
        bytes32 orderDigest = keccak256("fresh-orderDigest");
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        vm.expectRevert(NothingToRescue.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }

    // ─── when all checks pass ─────────────────────────────────────

    function test_WhenAllChecksPass() external {
        (bytes32 orderDigest, bytes32 orderId) = _setupRescueable();

        assertEq(
            settler.rescueableOf(orderDigest, fillerWallet.addr), DEFAULT_PRODUCE_AMOUNT, "pre: rescueable credited"
        );

        uint256 settlerBefore = dstToken.balanceOf(address(settler));
        uint256 destBefore = dstToken.balanceOf(fallbackDestination);

        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        vm.expectEmit(true, true, true, true, address(settler));
        emit FillerRescueWithdrawn(orderDigest, fillerWallet.addr, fallbackDestination, DEFAULT_PRODUCE_AMOUNT);

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
        assertEq(settler.rescueableOf(orderDigest, fillerWallet.addr), 0, "rescueable zeroed post-withdraw");
    }

    // ─── when called twice with the same signature ───────────────

    function test_WhenCalledTwiceWithTheSameSignature() external {
        (bytes32 orderDigest, bytes32 orderId) = _setupRescueable();
        bytes memory sig = _signRescue(orderDigest, orderId, fallbackDestination, fillerWallet.privateKey);

        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);

        vm.expectRevert(NothingToRescue.selector);
        settler.rescueSettled(orderDigest, orderId, fillerWallet.addr, fallbackDestination, sig);
    }
}
