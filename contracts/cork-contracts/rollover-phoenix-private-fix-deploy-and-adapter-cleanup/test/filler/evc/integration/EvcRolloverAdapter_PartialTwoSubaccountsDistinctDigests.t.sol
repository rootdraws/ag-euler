// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EvcPartialFillAdapterTestBase} from "test/filler/evc/partial/EvcPartialFillAdapterTestBase.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests
/// @notice Exercises the DP-EVC-A per-subaccount Partial deployment pattern: two separate
///         `EvcPartialFillAdapter(partialSettler, true, ...)` instances drive two DISTINCT
///         Partial-order digests concurrently from two distinct curator subaccounts. Both
///         succeed independently; INV-P1 keeps fillerRollover slots isolated.
/// @dev `PartialFillSettler` keys per-filler state on `msg.sender` (the adapter address). Per
///      DP-EVC-A curators deploy one adapter per subaccount. Same-digest collision is tested
///      separately in `EvcRolloverAdapter_PartialSameDigestTerminal.t.sol`.
contract EvcRolloverAdapter_PartialTwoSubaccountsDistinctDigests is EvcPartialFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    struct OrderBundle {
        IOriginSettler.GaslessCrossChainOrder order;
        OrderData od;
        bytes sig;
        bytes ofd;
    }

    function _buildBundle() internal returns (OrderBundle memory b) {
        (b.order, b.od, b.sig, b.ofd) = _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);
    }

    /// @notice Two distinct adapters, two distinct subaccounts, two distinct digests — both settle.
    function test_partialTwoSubaccountsDistinctDigests_bothSettleIndependently() external {
        address subA = makeAddr("subA");
        address subB = makeAddr("subB");
        address destA = makeAddr("destA");
        address destB = makeAddr("destB");
        EvcPartialFillAdapter adapterA =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subA);
        EvcPartialFillAdapter adapterB =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subB);

        OrderBundle memory bA = _buildBundle();
        vm.warp(block.timestamp + 1);
        OrderBundle memory bB = _buildBundle();

        _authoriseAdapterOperator(subA, adapterA);
        _prepareAdapterErc6909(subA, adapterA, bA.od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterA, bA.od.srcCstToken, ORDER_SIZE);

        _authoriseAdapterOperator(subB, adapterB);
        _prepareAdapterErc6909(subB, adapterB, bB.od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterB, bB.od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            adapterA, subA, _noItems(), _noItems(), abi.encode(bA.order), bA.sig, bA.ofd, ORDER_SIZE, subA, destA
        );
        _executeViaEvcBatch(
            adapterB, subB, _noItems(), _noItems(), abi.encode(bB.order), bB.sig, bB.ofd, ORDER_SIZE, subB, destB
        );

        bytes32 orderIdA = LibSettlerHashing.computeOrderId(address(partialSettler), bA.order);
        bytes32 orderIdB = LibSettlerHashing.computeOrderId(address(partialSettler), bB.order);
        assertEq(uint8(partialSettler.orderStatus(orderIdA)), uint8(OrderStatus.Settled), "digest A settled");
        assertEq(uint8(partialSettler.orderStatus(orderIdB)), uint8(OrderStatus.Settled), "digest B settled");

        assertEq(IERC20(bA.od.dstCstToken).balanceOf(destA), ORDER_SIZE, "dstCST to destA");
        assertEq(IERC20(bB.od.dstCstToken).balanceOf(destB), ORDER_SIZE, "dstCST to destB");
    }

    /// @notice INV-P1 slot isolation: each adapter owns its own per-digest slot; cross-slot reads
    ///         on the other adapter's digest are empty.
    function test_partialTwoSubaccountsDistinctDigests_fillerRolloverSlotsAreIsolated() external {
        address subA = makeAddr("subA2");
        address subB = makeAddr("subB2");
        address destA = makeAddr("destA2");
        address destB = makeAddr("destB2");
        EvcPartialFillAdapter adapterA =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subA);
        EvcPartialFillAdapter adapterB =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), subB);

        OrderBundle memory bA = _buildBundle();
        vm.warp(block.timestamp + 2);
        OrderBundle memory bB = _buildBundle();

        _authoriseAdapterOperator(subA, adapterA);
        _prepareAdapterErc6909(subA, adapterA, bA.od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterA, bA.od.srcCstToken, ORDER_SIZE);

        _authoriseAdapterOperator(subB, adapterB);
        _prepareAdapterErc6909(subB, adapterB, bB.od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(adapterB, bB.od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            adapterA, subA, _noItems(), _noItems(), abi.encode(bA.order), bA.sig, bA.ofd, ORDER_SIZE, subA, destA
        );
        _executeViaEvcBatch(
            adapterB, subB, _noItems(), _noItems(), abi.encode(bB.order), bB.sig, bB.ofd, ORDER_SIZE, subB, destB
        );

        bytes32 digestA = LibSettlerHashing.computeOrderDigest(address(partialSettler), bA.order, bA.od);
        bytes32 digestB = LibSettlerHashing.computeOrderDigest(address(partialSettler), bB.order, bB.od);

        IPartialFillSettler.FillerRollover memory frAA = partialSettler.fillerRollovers(digestA, address(adapterA));
        IPartialFillSettler.FillerRollover memory frAB = partialSettler.fillerRollovers(digestA, address(adapterB));
        IPartialFillSettler.FillerRollover memory frBA = partialSettler.fillerRollovers(digestB, address(adapterA));
        IPartialFillSettler.FillerRollover memory frBB = partialSettler.fillerRollovers(digestB, address(adapterB));

        assertTrue(frAA.finalised, "adapterA finalised on digestA");
        assertTrue(frBB.finalised, "adapterB finalised on digestB");
        assertEq(frAB.srcCstProvided, 0, "adapterB has no slot on digestA");
        assertEq(frBA.srcCstProvided, 0, "adapterA has no slot on digestB");
    }
}
