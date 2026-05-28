// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @title PartialFillSettler_PremiumLegTargetFiller
/// @notice Audit-cycle coverage for the premium-leg `targetFiller` symmetry guard (pashov A3 /
///         Task 3). `_onRolloverLegFill` already rejects `pfd.targetFiller != msg.sender`; the
///         premium leg now enforces the same predicate so no caller can push another filler's
///         bookkeeping to `premiumSettled`.
/// @dev The canonical filler flow never hits this revert because the RolloverFiller sets
///      `targetFiller = address(this)` on both legs. This leaf drives the settler directly with
///      a mismatched `targetFiller` to pin the selector on the premium path.
contract PartialFillSettler_PremiumLegTargetFiller is PartialFillSettlerTestBase {
    address internal realFiller = makeAddr("realFiller");
    address internal attacker = makeAddr("attacker");
    address internal destination = makeAddr("destination");
    address internal repayTo = makeAddr("repayTo");

    DummyERC20 internal dstToken;
    DummyERC20 internal premToken;

    function setUp() public override {
        super.setUp();
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premToken = new DummyERC20("Premium", "PREM", 18);
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _createOrderWithDistinctDst()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent)
    {
        (order,, intent) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        OrderData memory od = abi.decode(order.orderData, (OrderData));
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

    function _premiumFD(address targetFiller, address debitFrom, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom,
                    targetFiller: targetFiller,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
    }

    function _rolloverFD(address targetFiller, address dest, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: dest, debitFrom: address(0), targetFiller: targetFiller, intent: intent, cellarSig: ""
                })
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Primary leaf — A3 premium-leg symmetry
    // ═══════════════════════════════════════════════════════════════

    /// @notice `realFiller` lands the rollover leg, then `attacker` calls `fill` on the premium
    ///         leg naming `targetFiller = realFiller`. Without the symmetry guard the settler
    ///         would accept and push `realFiller`'s bookkeeping into `premiumSettled`. The new
    ///         check rejects on `msg.sender != pfd.targetFiller`.
    function test_premiumLeg_mismatchedTargetFiller_reverts_TargetFillerMismatch() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, CellarIntent memory intent) = _createOrderWithDistinctDst();
        _openForPartial(order, user, repayTo);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        // Land the rollover leg as realFiller so `_fillerRollovers[digest][realFiller]` exists.
        vm.prank(realFiller);
        settler.fill(orderId, abi.encode(order), _rolloverFD(realFiller, destination, intent));

        // attacker authorises the settler to debit from itself so the premium dual-auth check
        // inside `_requireDebitFromAuthorized` cannot short-circuit ahead of the new guard.
        vm.prank(attacker);
        premium.setOperator(address(settler), true);
        _depositPremium(attacker, address(premToken), 10e18);

        // attacker posts the premium leg but names realFiller as targetFiller. The new guard
        // fires BEFORE any state mutation — realFiller's row stays unchanged.
        vm.prank(attacker);
        vm.expectRevert(IPartialFillSettler.TargetFillerMismatch.selector);
        settler.fill(orderId, abi.encode(order), _premiumFD(realFiller, attacker, intent));

        bytes32 digest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));
        IPartialFillSettler.FillerRollover memory fr = settler.fillerRollovers(digest, realFiller);
        assertFalse(fr.premiumSettled, "premium-settled state must not have advanced");
    }
}
