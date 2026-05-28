// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

contract PartialFillSettler_fillerRollovers_test is PartialFillSettlerTestBase {
    DummyERC20 internal dstToken;
    address internal filler;
    address internal destination;

    function setUp() public override {
        super.setUp();
        filler = makeAddr("filler");
        destination = makeAddr("destination");
        dstToken = new DummyERC20("DstCST", "DST", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _createOrderWithDstToken()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);

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

    function _fillRolloverCorrectEncoding(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address filler_,
        address destination_,
        CellarIntent memory intent
    ) internal {
        bytes32 orderId = _computeOrderId(order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination_,
                    debitFrom: address(0),
                    targetFiller: filler_,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
        vm.prank(filler_);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    function _fillPremiumCorrectEncoding(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address targetFiller_,
        address premiumFiller,
        address debitFrom,
        CellarIntent memory intent
    ) internal {
        bytes32 orderId = _computeOrderId(order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom,
                    targetFiller: targetFiller_,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
        vm.prank(premiumFiller);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 1: never filled -> zero-value struct
    // ═══════════════════════════════════════════════════════════════

    function test_fillerRollovers_neverFilled_returnsZeroStruct() public view {
        bytes32 randomDigest = keccak256("random");
        address randomFiller = address(0xBEEF);

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(randomDigest, randomFiller);

        assertEq(fr.srcCstProvided, 0);
        assertEq(fr.dstCstProduced, 0);
        assertEq(fr.destination, address(0));
        assertFalse(fr.premiumSettled);
        assertFalse(fr.finalised);
        assertFalse(fr.refunded);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: filled -> populated struct
    // ═══════════════════════════════════════════════════════════════

    function test_fillerRollovers_filled_returnsPopulatedStruct() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) = _createOrderWithDstToken();

        _openForPartial(order, user, filler);
        _fillRolloverCorrectEncoding(order, filler, destination, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, filler);

        assertEq(fr.srcCstProvided, DEFAULT_PRODUCE_AMOUNT);
        assertEq(fr.dstCstProduced, DEFAULT_PRODUCE_AMOUNT);
        assertEq(fr.destination, destination);
        assertFalse(fr.premiumSettled);
        assertFalse(fr.finalised);
        assertFalse(fr.refunded);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: finalised -> terminal flag set
    // ═══════════════════════════════════════════════════════════════

    function test_fillerRollovers_finalised_returnsFinalisedTrue() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createOrderWithDstToken();

        _openForPartial(order, user, filler);
        _fillRolloverCorrectEncoding(order, filler, destination, intent);

        // Authorize settler as operator on ERC6909 so premium settle passes dual-auth
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        uint256 premiumAmount = (DEFAULT_PRODUCE_AMOUNT * od.minPremiumPerShare + 1e18 - 1) / 1e18;
        if (premiumAmount > 0) {
            _depositPremium(filler, od.premiumToken, premiumAmount);
        }

        _fillPremiumCorrectEncoding(order, filler, filler, filler, intent);

        // Set hookNonces bit 0 on mock cellar
        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Finalise
        address[] memory fillers = new address[](1);
        fillers[0] = filler;
        settler.finaliseAsSettled(orderDigest, fillers);

        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(orderDigest, filler);

        assertTrue(fr.finalised);
        assertFalse(fr.refunded);
        assertTrue(fr.premiumSettled);
        assertEq(fr.srcCstProvided, DEFAULT_PRODUCE_AMOUNT);
        assertEq(fr.dstCstProduced, DEFAULT_PRODUCE_AMOUNT);
        assertEq(fr.destination, destination);
    }
}
