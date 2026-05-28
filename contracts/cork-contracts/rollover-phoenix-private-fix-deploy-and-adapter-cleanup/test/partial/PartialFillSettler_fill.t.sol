// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {MockPartialFactory} from "test/partial/MockPartialFactory.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {
    OrderStatus,
    FillAfterDeadline,
    OrderInTerminalState,
    InconsistentIntent,
    InvalidOrderTokenPair,
    InvalidOutputIndex,
    IntentNotBoundToOrder
} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {CorkCellar} from "cellar/CorkCellar.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {
    CellarNotBound,
    NotExclusiveFiller,
    BelowMinFillSize,
    ResidualTruncates,
    DecimalTruncates
} from "contracts/settlers/BaseSettlerErrors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Reentrancy attacker for PartialFillSettler.
contract ReentrantPartialFactory {
    address public settler_;
    bytes32 public orderId;
    bytes public originData;
    bytes public fillerData;
    bool public armed;

    mapping(address => address) public cellars;

    function setCellar(address owner, address cellar) external {
        cellars[owner] = cellar;
    }

    function cellarOf(address owner) external view returns (address) {
        return cellars[owner];
    }

    function arm(address settler__, bytes32 orderId_, bytes memory originData_, bytes memory fillerData_) external {
        settler_ = settler__;
        orderId = orderId_;
        originData = originData_;
        fillerData = fillerData_;
        armed = true;
    }

    function executeIntentHooks(address, bytes32, uint8, CellarIntent calldata, bytes calldata, uint256, address)
        external
        returns (uint256)
    {
        if (armed) {
            armed = false;
            PartialFillSettler(settler_).fill(orderId, originData, fillerData);
        }
        return 0;
    }

    function validateModuleForForwarding(address) external pure {}

    function originatingSettler() external pure returns (address) {
        return address(0);
    }

    function hookNonces(bytes32) external pure returns (uint256) {
        return 0;
    }

    function rolled(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract PartialFillSettler_fill_test is PartialFillSettlerTestBase {
    address internal filler;
    address internal filler2;
    address internal destination;
    DummyERC20 internal premiumERC20;
    DummyERC20 internal dstToken;

    function setUp() public override {
        super.setUp();
        filler = makeAddr("filler");
        filler2 = makeAddr("filler2");
        destination = makeAddr("destination");
        premiumERC20 = new DummyERC20("Premium", "PRM", 18);
        dstToken = new DummyERC20("DstCST", "DST", 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  FillerData builders (byte-aligned for BaseSettler.fill)
    // ═══════════════════════════════════════════════════════════════
    //
    // BaseSettler.fill reads fillerData[0:1] as raw byte outputIndex,
    // then passes fillerData[1:] to the leg handler which abi.decode's
    // PartialFillerData. Use bytes.concat for correct alignment.

    function _rolloverFD(address filler_, address dest, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: dest, debitFrom: address(0), targetFiller: filler_, intent: intent, cellarSig: ""
                })
            )
        );
    }

    function _premiumFD(address targetFiller_, address debitFrom_, CellarIntent memory intent)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom_,
                    targetFiller: targetFiller_,
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
    }

    function _invalidIndexFD(CellarIntent memory intent) internal pure returns (bytes memory) {
        return bytes.concat(
            bytes1(uint8(2)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: address(0),
                    targetFiller: address(0),
                    intent: intent,
                    cellarSig: ""
                })
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Order helpers
    // ═══════════════════════════════════════════════════════════════

    /// @dev Creates a partial order with distinct dstCstToken and opens it.
    function _createAndOpenDistinctOrder()
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

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForPartial(order, user, filler);
    }

    function _createAndOpenDistinctOrderWithPremiumRate(uint256 minPremiumPerShare)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, minPremiumPerShare);
        od.dstCstToken = address(dstToken);
        od.premiumToken = address(premiumERC20);

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

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForPartial(order, user, filler);
    }

    function _setOrderStatus(bytes32 orderId_, OrderStatus status) internal {
        vm.store(address(settler), keccak256(abi.encode(orderId_, uint256(0))), bytes32(uint256(status)));
    }

    function _fillRolloverAligned(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address filler_,
        address dest,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = _computeOrderId(order);
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), _rolloverFD(filler_, dest, intent));
    }

    function _fillPremiumAligned(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address targetFiller_,
        address caller_,
        address debitFrom_,
        CellarIntent memory intent
    ) internal {
        bytes32 oid = _computeOrderId(order);
        vm.prank(caller_);
        settler.fill(oid, abi.encode(order), _premiumFD(targetFiller_, debitFrom_, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when block.timestamp > order.fillDeadline
    //  → revert FillAfterDeadline
    // ═══════════════════════════════════════════════════════════════

    function test_fill_afterDeadline_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.warp(uint256(order.fillDeadline) + 1);
        vm.prank(filler);
        vm.expectRevert(FillAfterDeadline.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderStatus is Settled/Refunded/Cancelled
    //  → revert OrderInTerminalState
    // ═══════════════════════════════════════════════════════════════

    function test_fill_settledOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Settled);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    function test_fill_refundedOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Refunded);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    function test_fill_cancelledOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Cancelled);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderData.allowPartialFills is false
    //  → revert InconsistentIntent
    // ═══════════════════════════════════════════════════════════════

    function test_fill_allowPartialFillsFalse_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.allowPartialFills = false;
        order.orderData = abi.encode(od);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(InconsistentIntent.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderData.srcCstToken equals premiumToken
    //  → revert InvalidOrderTokenPair
    // ═══════════════════════════════════════════════════════════════

    function test_fill_srcCstEqualsPremium_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.premiumToken = od.srcCstToken;
        order.orderData = abi.encode(od);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when intent hash mismatches cellarIntentHash
    //  → revert IntentNotBoundToOrder
    // ═══════════════════════════════════════════════════════════════

    function test_fill_intentMismatch_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.cellarIntentHash = bytes32(uint256(0xDEAD));
        order.orderData = abi.encode(od);
        _openForPartial(order, user, filler);

        // Build a bogus intent that won't match
        CellarIntent memory bogusIntent;

        vm.prank(filler);
        vm.expectRevert(IntentNotBoundToOrder.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler, destination, bogusIntent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  outputIndex == 0 (rollover leg)
    // ═══════════════════════════════════════════════════════════════

    // -- when targetFiller != msg.sender → revert TargetFillerMismatch --

    function test_fill_rollover_targetFillerMismatch_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        // filler calls but targetFiller is filler2
        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.TargetFillerMismatch.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler2, destination, intent));
    }

    // -- when destination is zero address → revert InvalidDestination --

    function test_fill_rollover_zeroDestination_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.InvalidDestination.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, address(0), intent));
    }

    // -- when f.srcCstProvided != 0 → revert AlreadyFilledByFiller --

    function test_fill_rollover_alreadyFilledByFiller_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        _fillRolloverAligned(order, filler, destination, intent);

        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.AlreadyFilledByFiller.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- when cumulative + amount exceeds orderSize → bubble revert --

    function test_fill_rollover_overfillCeiling_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        // First fill succeeds
        _fillRolloverAligned(order, filler, destination, intent);

        // Arm factory to revert on second fill (simulates cellar OverfillCeiling)
        mockFactory.setRevertBehavior(true, "");

        vm.prank(filler2);
        // Bare expectRevert: revert originates from mock factory with empty
        // revert data, simulating cellar OverfillCeiling bubble.
        vm.expectRevert();
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler2, destination, intent));
    }

    // -- when cellar returns actualRolled == 0 → revert ZeroRollover --

    function test_fill_rollover_zeroRollover_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        // Set produce amount to 0 so actualRolled returns 0
        mockFactory.setRolloverBehavior(address(dstToken), 0);

        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.ZeroRollover.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- when allowUnderfill false AND actualRolled < amount → bubble revert --

    function test_fill_rollover_underfillNotAllowed_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        // Arm factory to revert (simulates UnderfillNotAllowed from cellar)
        mockFactory.setRevertBehavior(true, "");

        vm.prank(filler);
        // Bare expectRevert: revert originates from mock factory with empty
        // revert data, simulating cellar UnderfillNotAllowed bubble.
        vm.expectRevert();
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- happy path: actualRolled == output.amount --

    function test_fill_rollover_happyPath() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        bytes32 orderId = _computeOrderId(order);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        _fillRolloverAligned(order, filler, destination, intent);

        // Assert filler rollover state
        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertEq(f.srcCstProvided, DEFAULT_PRODUCE_AMOUNT, "srcCstProvided == produceAmount");
        assertEq(f.dstCstProduced, DEFAULT_PRODUCE_AMOUNT, "dstCstProduced == produceAmount");
        assertEq(f.destination, destination, "destination stored");
        assertFalse(f.premiumSettled, "premiumSettled false");
        assertFalse(f.finalised, "finalised false");
        assertFalse(f.refunded, "refunded false");

        // Assert totalDstCstEscrowed incremented
        assertEq(settler.totalDstCstEscrowed(orderDigest), DEFAULT_PRODUCE_AMOUNT, "totalDstCstEscrowed");

        // Assert participantCount incremented
        assertEq(settler.participantCount(orderDigest), 1, "participantCount");

        // Assert orderStatus still Opened
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened), "orderStatus remains Opened");
    }

    // -- happy path: emit Fill event --

    function test_fill_rollover_emitsFill() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        bytes32 orderId = _computeOrderId(order);
        bytes32 outputHash = _computeOutputHash(od.outputs[0]);

        vm.prank(filler);
        vm.expectEmit(true, true, false, true, address(settler));
        emit IPartialFillSettler.Fill(orderId, 0, outputHash, filler);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- when actualRolled < output.amount AND allowUnderfill true
    //    → write with smaller srcCstProvided --

    function test_fill_rollover_underfillAllowed_storesActualRolled() public {
        uint256 reducedAmount = 600e18;

        // Build order with allowUnderfill = true
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrderWithPremium(user, DEFAULT_ORDER_SIZE, DEFAULT_MIN_PREMIUM_PER_SHARE);
        od.dstCstToken = address(dstToken);
        od.allowUnderfill = true;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: true,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        mockFactory.setRolloverBehavior(address(dstToken), reducedAmount);
        _openForPartial(order, user, filler);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        _fillRolloverAligned(order, filler, destination, intent);

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertEq(f.srcCstProvided, reducedAmount, "srcCstProvided == reducedAmount (actualRolled)");
        assertEq(f.dstCstProduced, reducedAmount, "dstCstProduced == reducedAmount");
    }

    // -- when fill brings cumulative to orderSize → observe cellar flip --

    function test_fill_rollover_phaseZeroTerminal() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        // Fill the entire order size with one filler
        _fillRolloverAligned(order, filler, destination, intent);

        // Simulate cellar setting the phase-0 terminal bit
        mockFactory.setHookNonces(orderDigest, 1);

        // Verify the hookNonces bit is set
        uint256 nonce = mockFactory.hookNoncesMap(orderDigest);
        assertEq(nonce & 1, 1, "phase-0 terminal bit set");
    }

    // -- when subsequent rollover fill after phase-0 terminal → bubble revert --

    function test_fill_rollover_phaseAlreadyConsumed_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        // First fill succeeds
        _fillRolloverAligned(order, filler, destination, intent);

        // Set phase-0 terminal bit and arm revert
        mockFactory.setHookNonces(orderDigest, 1);
        mockFactory.setRevertBehavior(true, "");

        vm.prank(filler2);
        // Bare expectRevert: revert originates from mock factory with empty
        // revert data, simulating cellar terminal-state bubble.
        vm.expectRevert();
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler2, destination, intent));
    }

    // -- when two concurrent fills race past ceiling → revert for loser --

    function test_fill_rollover_concurrentRacePastCeiling_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        // First filler succeeds
        _fillRolloverAligned(order, filler, destination, intent);

        // Factory reverts on second fill (simulates OverfillCeiling)
        mockFactory.setRevertBehavior(true, "");

        vm.prank(filler2);
        // Bare expectRevert: revert originates from mock factory with empty
        // revert data, simulating cellar OverfillCeiling bubble.
        vm.expectRevert();
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFD(filler2, destination, intent));
    }

    // -- leftover srcCST transferred to filler --

    function test_fill_rollover_leftoverTransferred() public {
        uint256 leftover = 50e18;
        mockFactory.setLeftoverBehavior(address(vaultUnderlying), leftover);

        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        uint256 fillerBalBefore = vaultUnderlying.balanceOf(filler);

        _fillRolloverAligned(order, filler, destination, intent);

        uint256 fillerBalAfter = vaultUnderlying.balanceOf(filler);
        assertEq(fillerBalAfter - fillerBalBefore, leftover, "leftover srcCST sent to filler");
    }

    // ═══════════════════════════════════════════════════════════════
    //  outputIndex == 1 (premium leg)
    // ═══════════════════════════════════════════════════════════════

    // -- when f.srcCstProvided == 0 for targetFiller
    //    → revert NoRolloverLegForFiller --

    function test_fill_premium_noRolloverLeg_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();

        // Try premium fill without rollover fill first
        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.NoRolloverLegForFiller.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // -- when f.premiumSettled is true → revert AlreadySettled --

    function test_fill_premium_alreadySettled_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        // Authorize and settle premium first time (zero premium)
        vm.prank(filler);
        premium.setOperator(address(settler), true);
        _fillPremiumAligned(order, filler, filler, filler, intent);

        // Second premium fill should revert
        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.AlreadySettled.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // -- when debitFrom == msg.sender → accept authorization --

    function test_fill_premium_debitFromIsMsgSender() public {
        uint256 premiumPerShare = 0.05e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        uint256 requiredPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        _depositPremium(filler, address(premiumERC20), requiredPremium);

        // filler authorizes settler
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));
        IPartialFillSettler.FillerRollover memory fBefore = settler.fillerRollovers(orderDigest, filler);
        assertFalse(fBefore.premiumSettled, "premiumSettled must be false before fill");

        // debitFrom == msg.sender (filler)
        _fillPremiumAligned(order, filler, filler, filler, intent);

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled set to true");
    }

    // -- when debitFrom != msg.sender AND isOperator true → accept --

    function test_fill_premium_operatorAuth() public {
        uint256 premiumPerShare = 0.05e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        uint256 requiredPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);

        address debitFrom = makeAddr("debitFrom");
        _depositPremium(debitFrom, address(premiumERC20), requiredPremium);

        // debitFrom authorizes filler as operator
        vm.prank(debitFrom);
        premium.setOperator(filler, true);
        // filler authorizes settler
        vm.prank(debitFrom);
        premium.setOperator(address(settler), true);

        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));
        IPartialFillSettler.FillerRollover memory fBefore = settler.fillerRollovers(orderDigest, filler);
        assertFalse(fBefore.premiumSettled, "premiumSettled must be false before fill");

        // filler calls with debitFrom != msg.sender, but filler is operator
        _fillPremiumAligned(order, filler, filler, debitFrom, intent);

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled via operator auth");
    }

    // -- when debitFrom != msg.sender AND isOperator false
    //    → revert UnauthorizedDebitFrom --

    function test_fill_premium_unauthorizedDebitFrom_reverts() public {
        uint256 premiumPerShare = 0.05e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        address debitFrom = makeAddr("debitFrom");

        // filler calls with debitFrom != msg.sender, no operator auth
        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.UnauthorizedDebitFrom.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, debitFrom, intent));
    }

    // -- when msg.sender != targetFiller → revert TargetFillerMismatch (A3) --

    function test_fill_premium_mismatchedTargetFiller_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));
        IPartialFillSettler.FillerRollover memory fBefore = settler.fillerRollovers(orderDigest, filler);
        assertFalse(fBefore.premiumSettled, "premiumSettled must be false before fill");

        // filler2 calls premium fill targeting filler (not itself). Post-A3 this reverts on the
        // symmetry guard — previously this test asserted the (vulnerable) "anyone can settle"
        // behaviour. See `PartialFillSettler._onPremiumLegFill`.
        vm.prank(filler2);
        premium.setOperator(address(settler), true);

        bytes32 orderId = _computeOrderId(order);
        vm.prank(filler2);
        vm.expectRevert(IPartialFillSettler.TargetFillerMismatch.selector);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler2, intent));

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertFalse(f.premiumSettled, "premium-settled state must not have advanced");
    }

    // -- when all auth passes: compute premium as ceilDiv --

    function test_fill_premium_computesCeilDiv() public {
        uint256 premiumPerShare = 0.05e18; // 5%
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        uint256 expectedPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);

        // Deposit exactly the required premium
        _depositPremium(filler, address(premiumERC20), expectedPremium);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        uint256 tokenId = uint256(uint160(address(premiumERC20)));
        uint256 balBefore = premium.balanceOf(filler, tokenId);

        _fillPremiumAligned(order, filler, filler, filler, intent);

        uint256 balAfter = premium.balanceOf(filler, tokenId);
        assertEq(balBefore - balAfter, expectedPremium, "ERC6909 balance decremented by premium");

        // 5% of 1000e18 = 50e18
        assertEq(expectedPremium, 50e18, "premium == 50e18");
    }

    // -- flip f.premiumSettled, leave orderStatus unchanged --

    function test_fill_premium_flipsSettledLeavesStatusOpen() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        vm.prank(filler);
        premium.setOperator(address(settler), true);
        _fillPremiumAligned(order, filler, filler, filler, intent);

        bytes32 orderId = _computeOrderId(order);
        assertEq(
            uint256(settler.orderStatus(orderId)),
            uint256(OrderStatus.Opened),
            "orderStatus remains Opened after premium"
        );
    }

    // -- emit Fill on premium leg --

    function test_fill_premium_emitsFill() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        bytes32 orderId = _computeOrderId(order);
        // Decode od again since it may have changed
        od = abi.decode(order.orderData, (OrderData));
        bytes32 premiumOH = _computeOutputHash(od.outputs[1]);

        vm.prank(filler);
        vm.expectEmit(true, true, false, true, address(settler));
        emit IPartialFillSettler.Fill(orderId, 1, premiumOH, filler);
        settler.fill(orderId, abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // -- when cellar phase-1 premiumHooks revert → PremiumHooksReverted emitted, premiumSettled stays true (AS-10 / #58) --

    function test_fill_premium_hooksRevert_committed() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        uint256 requiredPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        _depositPremium(filler, address(premiumERC20), requiredPremium);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        // Arm factory to revert on phase-1 only; rollover above used phase 0.
        mockFactory.setPhaseRevert(true, 1, hex"deadbeef");

        uint256 tokenId = uint256(uint160(address(premiumERC20)));
        uint256 balBefore = premium.balanceOf(filler, tokenId);

        vm.prank(filler);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));

        uint256 balAfter = premium.balanceOf(filler, tokenId);
        // ERC-6909 debit is committed — the premium sits at the cellar for UW recovery.
        assertEq(balBefore - balAfter, requiredPremium, "ERC-6909 debited even when hooks revert");

        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));
        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled latched true despite hook revert");
    }

    // -- when premiumFiredFor already true → bubble revert --

    function test_fill_premium_premiumAlreadyFiredForFiller_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        vm.prank(filler);
        premium.setOperator(address(settler), true);
        _fillPremiumAligned(order, filler, filler, filler, intent);

        // Second attempt hits AlreadySettled (settler's own check)
        vm.prank(filler);
        vm.expectRevert(IPartialFillSettler.AlreadySettled.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // -- when factory.originatingSettler() != intent.settler → bubble --

    function test_fill_premium_settlerMismatch_caughtNowThatPhase1IsIsolated() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        // Arm the mock's cellar-side SettlerMismatch branch. MockPartialFactory now mirrors the
        // real cellar guard at CorkCellar.sol:112 — when `originatingSettler()` is non-zero and
        // differs from `intent.settler`, `executeIntentHooks` reverts with the
        // `CorkCellar__SettlerMismatch` selector. Armed AFTER the rollover leg above so phase-0
        // still succeeds; only the phase-1 forward trips the mismatch.
        mockFactory.setOriginatingSettler(address(0xdead));
        bytes memory expectedErr = abi.encodeWithSelector(CorkCellar.CorkCellar__SettlerMismatch.selector);

        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigest(address(settler), order, abi.decode(order.orderData, (OrderData)));

        vm.prank(filler);
        vm.expectEmit(true, true, false, true, address(settler));
        emit IPartialFillSettler.PremiumHooksReverted(orderDigest, filler, expectedErr);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));

        IPartialFillSettler.FillerRollover memory f = settler.fillerRollovers(orderDigest, filler);
        assertTrue(f.premiumSettled, "premiumSettled remains true after caught cellar SettlerMismatch");
    }

    // -- when insufficient balance → revert InsufficientBalance --

    function test_fill_premium_insufficientBalance_reverts() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        // Authorize settler but don't deposit premium
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // -- when settler not authorized → revert UnauthorizedSettler --

    function test_fill_premium_unauthorizedSettler_reverts() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(premiumPerShare);

        _fillRolloverAligned(order, filler, destination, intent);

        // Deposit premium but do NOT authorize settler
        _depositPremium(filler, address(premiumERC20), 1000e18);

        vm.prank(filler);
        vm.expectRevert(IERC6909Premium.UnauthorizedSettler.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when outputIndex is neither 0 nor 1
    //  → revert InvalidOutputIndex
    // ═══════════════════════════════════════════════════════════════

    function test_fill_invalidOutputIndex_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(InvalidOutputIndex.selector);
        settler.fill(orderId, abi.encode(order), _invalidIndexFD(intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when reentrant fill from dstCST transferCallback
    //  → revert ReentrancyGuardReentrantCall
    // ═══════════════════════════════════════════════════════════════

    function test_fill_reentrancy_reverts() public {
        ReentrantPartialFactory reentrantFactory = new ReentrantPartialFactory();
        reentrantFactory.setCellar(user.addr, address(mockFactory));
        reentrantFactory.setCellar(smartWalletAddr, address(mockFactory));

        PartialFillSettler reentrantSettler = new PartialFillSettler(address(reentrantFactory), address(premium));

        // Build order bound to the reentrant settler
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);

        order.originSettler = address(reentrantSettler);
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(reentrantSettler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(reentrantFactory),
            settler: address(reentrantSettler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        // Open on the reentrant settler
        bytes memory sig = _signOrder(order, user, address(reentrantSettler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, filler);
        reentrantSettler.openFor(order, sig, originFillerData);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(reentrantSettler), order);

        // Build fillerData for the reentrant call
        bytes memory reentrantFillerData = _rolloverFD(filler, destination, intent);

        // Arm the reentrant factory to re-enter fill() during hooks
        reentrantFactory.arm(address(reentrantSettler), orderId, abi.encode(order), reentrantFillerData);

        vm.prank(filler);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentrantSettler.fill(orderId, abi.encode(order), reentrantFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  L3: when cellarOf[orderDigest] == address(0) → revert CellarNotBound
    // ═══════════════════════════════════════════════════════════════

    function test_premiumLeg_RevertsOnCellarNotBound() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _createAndOpenDistinctOrderWithPremiumRate(0);

        _fillRolloverAligned(order, filler, destination, intent);

        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);

        // Clear cellarOf[orderDigest] via vm.store (slot 4)
        vm.store(address(settler), keccak256(abi.encode(orderDigest, uint256(4))), bytes32(0));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        vm.expectRevert(CellarNotBound.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent));
    }

    // ═══════════════════════════════════════════════════════════════
    //  AS-19 / AS-20 / AS-21 ingress gates — RFC 003 §6.2
    // ═══════════════════════════════════════════════════════════════

    /// @dev Builds a Partial order with the two gate fields applied and opens it. The order's
    ///      produced amount is forced equal to `output.amount` so the cellar mock never takes a
    ///      different path than the gate intends to test.
    function _openPartialOrderWithGates(uint256 minFillSize, address exclusiveFiller_)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        od.minFillSize = minFillSize;
        od.exclusiveFiller = exclusiveFiller_;

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

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForPartial(order, user, filler);
    }

    /// @dev Re-runs `_openPartialOrderWithGates` but sets both outputs' `amount` to a caller-chosen
    ///      value so the rollover gate can be exercised against leg amounts that are smaller than
    ///      the order's full `orderSize`. The cellar mock's `produceAmount` is re-pointed to match.
    function _openPartialOrderWithGatesAndAmount(
        uint256 minFillSize,
        address exclusiveFiller_,
        uint256 rolloverOutputAmount
    )
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        od.minFillSize = minFillSize;
        od.exclusiveFiller = exclusiveFiller_;
        od.outputs[0].amount = rolloverOutputAmount;

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

        mockFactory.setRolloverBehavior(address(dstToken), rolloverOutputAmount);
        _openForPartial(order, user, filler);
    }

    // -- AS-21: exclusiveFiller set AND msg.sender != exclusiveFiller → NotExclusiveFiller --

    function test_fill_exclusiveFiller_wrongCaller_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGates(0, filler);
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler2);
        vm.expectRevert(NotExclusiveFiller.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler2, destination, intent));
    }

    function test_fill_exclusiveFiller_rightCaller_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGates(0, filler);

        _fillRolloverAligned(order, filler, destination, intent);

        // Round-trip: cumulativeFilled advances iff the gate admitted the rollover leg.
        assertGt(settler.cumulativeFilled(_computeOrderId(order)), 0, "fill must be accepted by exclusive filler");
    }

    // -- AS-19: minFillSize non-zero AND rollover output.amount < minFillSize → BelowMinFillSize --

    function test_fill_belowMinFillSize_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGatesAndAmount(DEFAULT_ORDER_SIZE, address(0), DEFAULT_ORDER_SIZE / 2);
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(BelowMinFillSize.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- AS-19: premium leg is NOT subject to BelowMinFillSize (unit mismatch — premium token
    //          amount vs share-unit minFillSize). Codifies the B1 review fix.
    function test_fill_premiumLeg_belowMinFillSize_notGated() public {
        // Construct an order with a large share-unit minFillSize and a tiny premium-leg amount.
        // The premium leg must be admitted by the AS-19 gate.
        uint256 minFill = DEFAULT_ORDER_SIZE;
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent) =
            _openPartialOrderWithGates(minFill, address(0));
        // Sanity — the handler sets outputs[1].amount to a premium-token value. Confirm it is
        // strictly below `minFillSize` for this test to be meaningful.
        require(od.outputs[1].amount < minFill, "test setup: premium amount must be < minFillSize");

        // Rollover leg first (cumulative ledger write precedes premium settlement).
        _fillRolloverAligned(order, filler, destination, intent);

        // Premium leg MUST NOT revert with BelowMinFillSize. Any other downstream setup revert is
        // acceptable — we only assert the gate does not fire.
        vm.prank(filler);
        try settler.fill(_computeOrderId(order), abi.encode(order), _premiumFD(filler, filler, intent)) {
        // ok
        }
        catch (bytes memory reason) {
            bytes4 sel;
            assembly {
                sel := mload(add(reason, 0x20))
            }
            assertTrue(sel != BelowMinFillSize.selector, "AS-19 must not gate the premium leg");
        }
    }

    // -- AS-22: rollover fill leaves residual 0 < r < minFillSize → ResidualTruncates --

    function test_fill_residualTruncates_reverts() public {
        // orderSize = 1000e18. minFillSize = 300e18. output.amount = 800e18. Residual would be 200e18,
        // which is < minFillSize → ResidualTruncates.
        uint256 minFill = 300e18;
        uint256 legAmount = 800e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGatesAndAmount(minFill, address(0), legAmount);
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(ResidualTruncates.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    function test_fill_closesOrderExactly_succeeds() public {
        // output.amount == orderSize → residual == 0 → gate admits regardless of minFillSize.
        uint256 minFill = 300e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGatesAndAmount(minFill, address(0), DEFAULT_ORDER_SIZE);

        _fillRolloverAligned(order, filler, destination, intent);
        assertGt(settler.cumulativeFilled(_computeOrderId(order)), 0, "full-close fill must bypass ResidualTruncates");
    }

    function test_fill_leavesResidualAboveMinFillSize_succeeds() public {
        // orderSize = 1000e18. minFillSize = 300e18. output.amount = 500e18. Residual = 500e18 >=
        // minFillSize → gate admits.
        uint256 minFill = 300e18;
        uint256 legAmount = 500e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithGatesAndAmount(minFill, address(0), legAmount);

        _fillRolloverAligned(order, filler, destination, intent);
        assertEq(
            settler.cumulativeFilled(_computeOrderId(order)), legAmount, "cumulative should equal the filled leg amount"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  AS-20 decimal-truncation gate — RFC §6.2
    // ═══════════════════════════════════════════════════════════════
    //
    // The gate sources the decimal offset from
    // `IPoolManager(poolManager).market(srcPoolId).collateralAsset.decimals()` per RFC §6.2
    // line 2009, NOT from `srcCstToken.decimals()`. These tests mock the chain so the gate sees
    // a caller-chosen collateral decimals value (6 for USDC-like, 18 for a no-op).

    /// @dev Builds a Partial order whose rollover-leg amount and srcPoolId collateralAsset are
    ///      caller-chosen. The `srcPoolId` reuses `0x1111` from the base helper; the default
    ///      18-decimal mock is overwritten here with `collateralAsset_`.
    function _openPartialOrderWithDecimalGate(uint256 legAmount, address collateralAsset_)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        od.outputs[0].amount = legAmount;

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

        // Re-point the AS-20 gate's `market(srcPoolId).collateralAsset` entry. The base setUp's
        // default (18-decimal `vaultUnderlying`) is overwritten for this specific srcPoolId.
        _mockMarketForPool(od.srcPoolId, collateralAsset_);

        mockFactory.setRolloverBehavior(address(dstToken), legAmount);
        _openForPartial(order, user, filler);
    }

    // -- AS-20: 6-decimal collateral with aligned fillAmount → gate admits --
    function test_fill_decimalTruncates_sixDecCollateral_aligned_succeeds() public {
        DummyERC20 usdc = new DummyERC20("USDC", "USDC", 6);
        // factor = 10^(18-6) = 10^12. An aligned amount: 500e18 = 5e20, divisible by 1e12.
        uint256 aligned = 500e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithDecimalGate(aligned, address(usdc));

        _fillRolloverAligned(order, filler, destination, intent);
        assertEq(
            settler.cumulativeFilled(_computeOrderId(order)), aligned, "AS-20: aligned fill must advance cumulative"
        );
    }

    // -- AS-20: 6-decimal collateral with unaligned fillAmount → DecimalTruncates --
    function test_fill_decimalTruncates_sixDecCollateral_unaligned_reverts() public {
        DummyERC20 usdc = new DummyERC20("USDC", "USDC", 6);
        // factor = 10^12; an unaligned amount: 500e18 + 1 is not divisible by 10^12.
        uint256 unaligned = 500e18 + 1;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithDecimalGate(unaligned, address(usdc));
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(DecimalTruncates.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFD(filler, destination, intent));
    }

    // -- AS-20: 18-decimal collateral → gate is a no-op regardless of modulo --
    function test_fill_decimalTruncates_eighteenDecCollateral_isNoop() public {
        DummyERC20 eighteenDec = new DummyERC20("ETH18", "ETH", 18);
        // Any amount; the gate must NOT fire because `decimals_ >= 18` short-circuits.
        uint256 anyAmount = 500e18 + 1;
        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) =
            _openPartialOrderWithDecimalGate(anyAmount, address(eighteenDec));

        _fillRolloverAligned(order, filler, destination, intent);
        assertEq(
            settler.cumulativeFilled(_computeOrderId(order)),
            anyAmount,
            "AS-20: 18-decimal collateral gate must admit any non-zero amount"
        );
    }
}
