// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

contract PartialFillSettler_totalDstCstEscrowed_test is PartialFillSettlerTestBase {
    DummyERC20 internal dstToken;
    address internal filler1;
    address internal filler2;
    address internal destination1;
    address internal destination2;

    function setUp() public override {
        super.setUp();
        filler1 = makeAddr("filler1");
        filler2 = makeAddr("filler2");
        destination1 = makeAddr("destination1");
        destination2 = makeAddr("destination2");
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
    //  Leaf 1: no fills -> zero
    // ═══════════════════════════════════════════════════════════════

    function test_totalDstCstEscrowed_noFills_returnsZero() public view {
        bytes32 randomDigest = keccak256("random");
        assertEq(settler.totalDstCstEscrowed(randomDigest), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 2: two fillers filled, no finalisations -> sum
    // ═══════════════════════════════════════════════════════════════

    function test_totalDstCstEscrowed_twoFills_returnsSumOfProduced() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) = _createOrderWithDstToken();

        _openForPartial(order, user, filler1);

        _fillRolloverCorrectEncoding(order, filler1, destination1, intent);
        _fillRolloverCorrectEncoding(order, filler2, destination2, intent);

        bytes32 orderDigest = _computeOrderDigest(order);
        assertEq(settler.totalDstCstEscrowed(orderDigest), 2 * DEFAULT_PRODUCE_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Leaf 3: one filler finalised -> decremented sum
    // ═══════════════════════════════════════════════════════════════

    function test_totalDstCstEscrowed_oneFinalised_returnsDecrementedSum() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createOrderWithDstToken();

        _openForPartial(order, user, filler1);

        _fillRolloverCorrectEncoding(order, filler1, destination1, intent);
        _fillRolloverCorrectEncoding(order, filler2, destination2, intent);

        // Authorize settler as operator on ERC6909 so premium settle passes dual-auth
        vm.prank(filler1);
        premium.setOperator(address(settler), true);

        uint256 premiumAmount = (DEFAULT_PRODUCE_AMOUNT * od.minPremiumPerShare + 1e18 - 1) / 1e18;
        if (premiumAmount > 0) {
            _depositPremium(filler1, od.premiumToken, premiumAmount);
        }

        _fillPremiumCorrectEncoding(order, filler1, filler1, filler1, intent);

        // Set hookNonces bit 0 on mock cellar
        bytes32 orderDigest = _computeOrderDigest(order);
        mockFactory.setHookNonces(orderDigest, 1);

        // Finalise filler1 only
        address[] memory fillers = new address[](1);
        fillers[0] = filler1;
        settler.finaliseAsSettled(orderDigest, fillers);

        assertEq(settler.totalDstCstEscrowed(orderDigest), DEFAULT_PRODUCE_AMOUNT);
    }
}
