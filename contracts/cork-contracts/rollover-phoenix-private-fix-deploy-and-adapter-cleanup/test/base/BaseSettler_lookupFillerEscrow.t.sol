// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

/// @title BaseSettler_lookupFillerEscrow (PR 3 — Task 9)
/// @notice Coverage for the shared `_lookupFillerEscrow` primitive on BaseSettler. The primitive
///         is internal, so each leaf asserts via the concrete's public view (`fillerRollovers`
///         for Partial, `fillRecords` for Exact) that the primitive returns a correctly-mapped
///         `FillerEscrow` struct.
/// @dev Both concretes' public views read the same storage the primitive reads, so parity
///      between the primitive and the public view is asserted transitively.
contract BaseSettler_lookupFillerEscrow_Partial is PartialFillSettlerTestBase {
    address internal fillerAddr = makeAddr("fillerA");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");
    DummyERC20 internal dstToken;

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    function _openAndBind()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest)
    {
        OrderData memory od;
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
        od.dstCstToken = address(dstToken);
        digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent.orderDigest = digest;
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
        _openForPartial(order, user, repayTo);
    }

    // Leaf: Partial AND no entry → zero FillerEscrow
    function test_partial_noEntry_returnsZero() public {
        (,, bytes32 digest) = _openAndBind();
        IPartialFillSettler.FillerRollover memory r = settler.fillerRollovers(digest, fillerAddr);
        assertEq(r.srcCstProvided, 0);
        assertEq(r.dstCstProduced, 0);
        assertEq(r.destination, address(0));
    }

    // Leaf: Partial AND entry exists → maps from _fillerRollovers
    function test_partial_withEntry_mapsStorage() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent, bytes32 digest) =
            _openAndBind();
        _fillRollover(order, fillerAddr, destination, intent, "");
        IPartialFillSettler.FillerRollover memory r = settler.fillerRollovers(digest, fillerAddr);
        assertGt(r.srcCstProvided, 0, "srcCstProvided should be set");
        assertEq(r.dstCstProduced, DEFAULT_PRODUCE_AMOUNT, "dstCstProduced should equal produced");
        assertEq(r.destination, destination);
    }
}

contract BaseSettler_lookupFillerEscrow_Exact is ExactFillSettlerTestBase {
    address internal fillerAddr;
    address internal destination;

    function setUp() public override {
        super.setUp();
        fillerAddr = makeAddr("filler");
        destination = makeAddr("destination");
    }

    function _openExact() internal returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) {
        CellarIntent memory intent;
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        _openForExact(order, user, fillerAddr);
    }

    // Leaf: Exact AND no entry → zero FillerEscrow
    function test_exact_noEntry_returnsZero() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _openExact();
        bytes32 orderId = _computeOrderId(order);
        bytes32 oh = _computeOutputHash(od.outputs[0]);
        (address f,, uint256 produced, uint64 filledAt) = settler.fillRecords(orderId, oh);
        assertEq(f, address(0));
        assertEq(produced, 0);
        assertEq(filledAt, 0);
    }

    // Leaf: Exact AND entry exists → maps from fillRecords
    function test_exact_withEntry_mapsStorage() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _openExact();
        _fillRollover(order, fillerAddr, destination);
        bytes32 orderId = _computeOrderId(order);
        bytes32 oh = _computeOutputHash(od.outputs[0]);
        (address f, address d, uint256 produced, uint64 filledAt) = settler.fillRecords(orderId, oh);
        assertEq(f, fillerAddr);
        assertEq(d, destination);
        assertGt(produced, 0, "dstCstProduced should be set");
        assertEq(filledAt, uint64(block.timestamp));
    }
}
