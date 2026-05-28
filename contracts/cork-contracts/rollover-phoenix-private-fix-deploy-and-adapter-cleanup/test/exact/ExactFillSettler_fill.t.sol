// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {OrderData, RolloverFillerData, PremiumFillerData} from "contracts/libs/LibRolloverOrder.sol";
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
import {
    InvalidDestination,
    UnauthorizedDebitFrom,
    DisproportionateOutput,
    CellarNotBound,
    NotExclusiveFiller,
    BelowMinFillSize,
    DecimalTruncates
} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Reentrancy attacker that re-enters fill() during executeIntentHooks.
contract ReentrantFactory {
    address public settler;
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

    function arm(address settler_, bytes32 orderId_, bytes memory originData_, bytes memory fillerData_) external {
        settler = settler_;
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
            ExactFillSettler(settler).fill(orderId, originData, fillerData);
        }
        return 0;
    }

    function validateModuleForForwarding(address) external pure {}

    function originatingSettler() external pure returns (address) {
        return address(0);
    }
}

contract ExactFillSettler_fill_test is ExactFillSettlerTestBase {
    address internal filler;
    address internal destination;
    DummyERC20 internal premiumERC20;
    DummyERC20 internal dstToken;

    function setUp() public override {
        super.setUp();
        filler = makeAddr("filler");
        destination = makeAddr("destination");
        premiumERC20 = new DummyERC20("Premium", "PRM", 18);
        // Separate dstCstToken to avoid srcCst==dstCst confusion in balance deltas
        dstToken = new DummyERC20("DstCST", "DST", 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  FillerData builders (byte-aligned for BaseSettler.fill)
    // ═══════════════════════════════════════════════════════════════
    //
    // BaseSettler.fill reads fillerData[0:1] as outputIndex (raw byte),
    // then passes fillerData[1:] to the leg handler which abi.decode's it.
    // abi.encode(uint8, struct) pads uint8 to 32 bytes, making byte 0
    // always 0x00. We use bytes.concat for correct alignment.

    function _rolloverFillerData(address dest) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: dest})));
    }

    function _premiumFillerData(address debitFrom) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
    }

    function _invalidIndexFillerData() internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(2)), abi.encode(address(0)));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Order helpers
    // ═══════════════════════════════════════════════════════════════

    /// @dev Creates an order with distinct srcCst / dstCst tokens so balance deltas are clean.
    function _createAndOpenDistinctOrder()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
    {
        CellarIntent memory intent;
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        od.dstCstToken = address(dstToken);
        // Recompute hashes after changing dstCstToken
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

        // Configure mock factory to mint dstToken (not vaultUnderlying)
        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);

        _openForExact(order, user, filler);
    }

    /// @dev Simple open using the default _createExactOrder (srcCst == dstCst).
    function _createAndOpenOrder()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
    {
        CellarIntent memory intent;
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
        _openForExact(order, user, filler);
    }

    function _createAndOpenOrderWithRealPremium()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrderWithPremium(user, DEFAULT_ORDER_SIZE, 0);
        od.premiumToken = address(premiumERC20);
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

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForExact(order, user, filler);
    }

    function _createAndOpenOrderWithPremiumRate(uint256 minPremiumPerShare)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrderWithPremium(user, DEFAULT_ORDER_SIZE, minPremiumPerShare);
        od.premiumToken = address(premiumERC20);
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

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForExact(order, user, filler);
    }

    function _setOrderStatus(bytes32 orderId_, OrderStatus status) internal {
        // orderStatus mapping is at storage slot 0 (OZ v5 ReentrancyGuard uses transient storage)
        vm.store(address(settler), keccak256(abi.encode(orderId_, uint256(0))), bytes32(uint256(status)));
    }

    function _fillRolloverAligned(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address dest)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), _rolloverFillerData(dest));
    }

    function _fillPremiumAligned(IOriginSettler.GaslessCrossChainOrder memory order, address filler_, address debitFrom)
        internal
    {
        bytes32 oid = LibSettlerHashing.computeOrderId(address(settler), order);
        vm.prank(filler_);
        settler.fill(oid, abi.encode(order), _premiumFillerData(debitFrom));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when block.timestamp > order.fillDeadline → revert FillAfterDeadline
    // ═══════════════════════════════════════════════════════════════

    function test_fill_afterDeadline_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.warp(uint256(order.fillDeadline) + 1);
        vm.prank(filler);
        vm.expectRevert(FillAfterDeadline.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderStatus is Settled/Refunded/Cancelled → revert OrderInTerminalState
    // ═══════════════════════════════════════════════════════════════

    function test_fill_settledOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Settled);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    function test_fill_refundedOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Refunded);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    function test_fill_cancelledOrder_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();
        bytes32 orderId = _computeOrderId(order);
        _setOrderStatus(orderId, OrderStatus.Cancelled);

        vm.prank(filler);
        vm.expectRevert(OrderInTerminalState.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderData.allowPartialFills is true → revert InconsistentIntent
    // ═══════════════════════════════════════════════════════════════

    function test_fill_allowPartialFills_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);
        od.allowPartialFills = true;
        order.orderData = abi.encode(od);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(InconsistentIntent.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when orderData.srcCstToken == orderData.premiumToken → revert InvalidOrderTokenPair
    // ═══════════════════════════════════════════════════════════════

    function test_fill_srcCstEqualsPremium_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);
        od.premiumToken = od.srcCstToken;
        order.orderData = abi.encode(od);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Rollover leg (outputIndex == 0)
    // ═══════════════════════════════════════════════════════════════

    // -- when output.amount != orderSize → revert PartialFillNotAllowed --

    function test_fill_rollover_amountMismatch_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);

        od.outputs[0].amount = DEFAULT_ORDER_SIZE + 1;
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        CellarIntent memory intent = CellarIntent({
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
        _openForExact(order, user, filler);

        vm.prank(filler);
        vm.expectRevert(IExactFillSettler.PartialFillNotAllowed.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
    }

    // -- when fillRecords already set → revert AlreadyFilled --

    function test_fill_rollover_alreadyFilled_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();
        _fillRolloverAligned(order, filler, destination);

        vm.prank(filler);
        vm.expectRevert(IExactFillSettler.AlreadyFilled.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
    }

    // -- when intent hash mismatches → revert IntentNotBoundToOrder --

    function test_fill_rollover_intentMismatch_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrder(user, DEFAULT_ORDER_SIZE);

        od.cellarIntentHash = bytes32(uint256(0xDEAD));
        order.orderData = abi.encode(od);
        _openForExact(order, user, filler);

        vm.prank(filler);
        vm.expectRevert(IntentNotBoundToOrder.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
    }

    // -- when CellarIntent valid: forward factory.executeIntentHooks with phase=0 --

    function test_fill_rollover_forwardsToFactory() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();
        uint256 settlerBefore = dstToken.balanceOf(address(settler));

        _fillRolloverAligned(order, filler, destination);

        uint256 settlerAfter = dstToken.balanceOf(address(settler));
        assertEq(settlerAfter - settlerBefore, DEFAULT_PRODUCE_AMOUNT, "settler holds dstCstProduced");
    }

    // -- observe dstCstProduced via balance delta (1-wei tolerance) --

    function test_fill_rollover_recordsDstCstProduced() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _createAndOpenDistinctOrder();
        _fillRolloverAligned(order, filler, destination);

        bytes32 orderId = _computeOrderId(order);
        bytes32 outputHash = _computeOutputHash(od.outputs[0]);
        (address recFiller,, uint256 dstCstProduced,) = settler.fillRecords(orderId, outputHash);
        assertEq(recFiller, filler);
        assertEq(uint256(dstCstProduced), DEFAULT_PRODUCE_AMOUNT);
    }

    // -- record FillRecord { filler, dstCstProduced, filledAt } --

    function test_fill_rollover_recordsFillRecord() public {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _createAndOpenDistinctOrder();
        _fillRolloverAligned(order, filler, destination);

        bytes32 orderId = _computeOrderId(order);
        bytes32 outputHash = _computeOutputHash(od.outputs[0]);
        (address recFiller, address recDest, uint256 dstCstProduced, uint64 filledAt) =
            settler.fillRecords(orderId, outputHash);

        assertEq(recFiller, filler);
        assertEq(recDest, destination);
        assertEq(uint256(dstCstProduced), DEFAULT_PRODUCE_AMOUNT);
        assertEq(uint256(filledAt), block.timestamp);
    }

    // -- pull leftover srcCST to msg.sender --

    function test_fill_rollover_pullsLeftoverToFiller() public {
        uint256 leftover = 50e18;
        mockFactory.setLeftoverBehavior(address(vaultUnderlying), leftover);

        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();
        uint256 fillerBalBefore = vaultUnderlying.balanceOf(filler);

        _fillRolloverAligned(order, filler, destination);

        uint256 fillerBalAfter = vaultUnderlying.balanceOf(filler);
        assertEq(fillerBalAfter - fillerBalBefore, leftover, "leftover srcCST sent to filler");
    }

    // -- NOT transition orderStatus --

    function test_fill_rollover_doesNotChangeOrderStatus() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
        _fillRolloverAligned(order, filler, destination);
        assertEq(uint256(settler.orderStatus(orderId)), uint256(OrderStatus.Opened));
    }

    // -- when dstCstProduced+1 < fillSize-leftover → revert DisproportionateOutput --

    function test_fill_rollover_disproportionateOutput_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();

        // Override AFTER order creation so the helper's default doesn't win
        mockFactory.setRolloverBehavior(address(dstToken), 1);
        mockFactory.setLeftoverBehavior(address(vaultUnderlying), 0);

        vm.prank(filler);
        vm.expectRevert(DisproportionateOutput.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Premium leg (outputIndex == 1)
    // ═══════════════════════════════════════════════════════════════

    // -- when no rollover fill record → revert PremiumBeforeRollover --

    function test_fill_premium_beforeRollover_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithRealPremium();
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(IExactFillSettler.PremiumBeforeRollover.selector);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(filler));
    }

    // -- when premiumOutputHash already set → revert AlreadyFilled --

    function test_fill_premium_alreadyFilled_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithRealPremium();

        _fillRolloverAligned(order, filler, destination);

        // Zero premium: authorize and fill first time
        vm.prank(filler);
        premium.setOperator(address(settler), true);
        _fillPremiumAligned(order, filler, filler);

        // Second premium fill should revert
        vm.prank(filler);
        vm.expectRevert(IExactFillSettler.AlreadyFilled.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFillerData(filler));
    }

    // -- when debitFrom has insufficient balance → revert InsufficientBalance --

    function test_fill_premium_insufficientBalance_reverts() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithPremiumRate(premiumPerShare);
        _fillRolloverAligned(order, filler, destination);

        // Authorize settler but don't deposit any premium tokens
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFillerData(filler));
    }

    // -- when debitFrom does not authorize msg.sender → revert UnauthorizedSettler --

    function test_fill_premium_unauthorizedSettler_reverts() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithPremiumRate(premiumPerShare);
        _fillRolloverAligned(order, filler, destination);

        // Deposit premium but do NOT authorize settler as operator
        _depositPremium(filler, address(premiumERC20), 1000e18);

        vm.prank(filler);
        vm.expectRevert(IERC6909Premium.UnauthorizedSettler.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _premiumFillerData(filler));
    }

    // -- when debitFrom authorizes msg.sender → debit premium, forward phase=1, flip paymentSettled, emit Fill --

    function test_fill_premium_happyPath() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createAndOpenOrderWithPremiumRate(premiumPerShare);
        _fillRolloverAligned(order, filler, destination);

        uint256 requiredPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        _depositPremium(filler, address(premiumERC20), requiredPremium);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        bytes32 orderId = _computeOrderId(order);
        bytes32 premiumOH = _computeOutputHash(od.outputs[1]);

        assertFalse(settler.paymentSettled(orderId), "paymentSettled must be false before fill");

        uint256 tokenId = uint256(uint160(address(premiumERC20)));
        uint256 erc6909Before = premium.balanceOf(filler, tokenId);
        address cellar = mockFactory.cellarOf(user.addr);
        uint256 cellarBefore = premiumERC20.balanceOf(cellar);

        vm.prank(filler);
        vm.expectEmit(true, true, false, true, address(settler));
        emit IExactFillSettler.Fill(orderId, 1, premiumOH, filler);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(filler));

        assertTrue(settler.paymentSettled(orderId), "paymentSettled should be true");
        assertEq(erc6909Before - premium.balanceOf(filler, tokenId), requiredPremium, "ERC-6909 debited exact premium");
        assertEq(premiumERC20.balanceOf(cellar) - cellarBefore, requiredPremium, "cellar received exact premium");
    }

    // -- when requiredPremium == 0 → short-circuit debit, still fire hooks + flip paymentSettled --

    function test_fill_premium_zeroPremium_shortCircuits() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithRealPremium();
        _fillRolloverAligned(order, filler, destination);

        bytes32 orderId = _computeOrderId(order);

        assertFalse(settler.paymentSettled(orderId), "paymentSettled must be false before fill");

        // ERC6909Premium.settle with amount=0 still requires dual-auth
        vm.prank(filler);
        premium.setOperator(address(settler), true);

        uint256 tokenId = uint256(uint160(address(premiumERC20)));
        uint256 erc6909Before = premium.balanceOf(filler, tokenId);
        address cellar = mockFactory.cellarOf(user.addr);
        uint256 cellarBefore = premiumERC20.balanceOf(cellar);

        _fillPremiumAligned(order, filler, filler);

        assertTrue(settler.paymentSettled(orderId), "paymentSettled should flip for zero premium");
        assertEq(premium.balanceOf(filler, tokenId), erc6909Before, "6909 balance unchanged on zero premium");
        assertEq(premiumERC20.balanceOf(cellar), cellarBefore, "cellar balance unchanged on zero premium");
    }

    // -- when premiumHooks revert → PremiumHooksReverted emitted, paymentSettled stays true (AS-10 / #58) --

    function test_fill_premium_hooksRevert_committed() public {
        uint256 premiumPerShare = 0.1e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithPremiumRate(premiumPerShare);
        _fillRolloverAligned(order, filler, destination);

        uint256 requiredPremium = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, premiumPerShare, 1e18, Math.Rounding.Ceil);
        _depositPremium(filler, address(premiumERC20), requiredPremium);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        // Arm the factory to revert only on phase 1 — rollover leg above used phase 0.
        mockFactory.setPhaseRevert(true, 1, hex"deadbeef");

        uint256 tokenId = uint256(uint160(address(premiumERC20)));
        uint256 balBefore = premium.balanceOf(filler, tokenId);
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(filler));

        uint256 balAfter = premium.balanceOf(filler, tokenId);
        // ERC-6909 debit is now committed — the premium sits at the cellar for UW recovery.
        assertEq(balBefore - balAfter, requiredPremium, "ERC-6909 debited even when hooks revert");
        assertTrue(settler.paymentSettled(orderId), "paymentSettled stays true");
    }

    // -- when reentrant fill from premiumHooks → revert ReentrancyGuardReentrantCall --

    function test_fill_premium_reentrancy_reverts() public {
        ReentrantFactory reentrantFactory = new ReentrantFactory();
        reentrantFactory.setCellar(user.addr, mockFactory.cellarOf(user.addr));
        reentrantFactory.setCellar(smartWalletAddr, mockFactory.cellarOf(smartWalletAddr));

        ExactFillSettler reentrantSettler = new ExactFillSettler(address(reentrantFactory), address(premium));

        // Build order bound to the reentrant settler
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrderWithPremium(user, DEFAULT_ORDER_SIZE, 0);
        od.premiumToken = address(premiumERC20);

        // Rebind to reentrant settler
        order.originSettler = address(reentrantSettler);
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(reentrantSettler), order, od);
        CellarIntent memory intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(reentrantFactory),
            settler: address(reentrantSettler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: false,
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

        // Arm the reentrant factory to re-enter fill() during executeIntentHooks
        bytes memory reentrantFillerData = _rolloverFillerData(destination);
        reentrantFactory.arm(address(reentrantSettler), orderId, abi.encode(order), reentrantFillerData);

        vm.prank(filler);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentrantSettler.fill(orderId, abi.encode(order), reentrantFillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  H5: when destination == address(0) → revert InvalidDestination
    // ═══════════════════════════════════════════════════════════════

    function test_rolloverLeg_RevertsOnZeroDestination() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenDistinctOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(InvalidDestination.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(address(0)));
    }

    // ═══════════════════════════════════════════════════════════════
    //  M1: when debitFrom is not msg.sender or operator → revert UnauthorizedDebitFrom
    // ═══════════════════════════════════════════════════════════════

    function test_premiumLeg_RevertsOnUnauthorizedDebitFrom() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithRealPremium();
        _fillRolloverAligned(order, filler, destination);

        address unauthorizedAccount = makeAddr("unauthorizedAccount");
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(UnauthorizedDebitFrom.selector);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(unauthorizedAccount));
    }

    // ═══════════════════════════════════════════════════════════════
    //  when outputIndex neither 0 nor 1 → revert InvalidOutputIndex
    // ═══════════════════════════════════════════════════════════════

    function test_fill_invalidOutputIndex_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(InvalidOutputIndex.selector);
        settler.fill(orderId, abi.encode(order), _invalidIndexFillerData());
    }

    // ═══════════════════════════════════════════════════════════════
    //  L3: when cellarOf[orderId] == address(0) → revert CellarNotBound
    // ═══════════════════════════════════════════════════════════════

    function test_premiumLeg_RevertsOnCellarNotBound() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _createAndOpenOrderWithRealPremium();
        _fillRolloverAligned(order, filler, destination);

        bytes32 orderId = _computeOrderId(order);

        // Clear cellarOf[orderId] via vm.store (slot 5)
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(5))), bytes32(0));

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        vm.expectRevert(CellarNotBound.selector);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(filler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  L2: intent hash recheck on premium leg
    // ═══════════════════════════════════════════════════════════════

    function test_premiumLeg_RevertsOnIntentHashMismatch() public {
        // Create an order with a deliberately wrong cellarIntentHash so
        // extractCellarIntentFromOrderData produces an intent whose hash
        // does not match od.cellarIntentHash.
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _createExactOrderWithPremium(user, DEFAULT_ORDER_SIZE, 0);
        od.premiumToken = address(premiumERC20);
        od.dstCstToken = address(dstToken);
        // Set a bogus hash that won't match what extraction produces
        od.cellarIntentHash = bytes32(uint256(0xDEAD));
        order.orderData = abi.encode(od);

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForExact(order, user, filler);

        bytes32 orderId = _computeOrderId(order);

        // Write a fake rollover fill record so PremiumBeforeRollover doesn't trigger.
        // fillRecords is slot 1; fillRecords[orderId][outputHash] uses nested mapping.
        bytes32 rolloverOH = LibSettlerHashing.computeOutputHash(od.outputs[0]);
        bytes32 fillSlot = keccak256(abi.encode(rolloverOH, keccak256(abi.encode(orderId, uint256(1)))));
        // FillRecord layout (PR 3 / #53 — `dstCstProduced` widened to uint256):
        //   slot 0: filler (address, 20 bytes, right-aligned)
        //   slot 1: destination (address)
        //   slot 2: dstCstProduced (uint256)
        //   slot 3: filledAt (uint64)
        vm.store(address(settler), fillSlot, bytes32(uint256(uint160(filler))));
        vm.store(address(settler), bytes32(uint256(fillSlot) + 1), bytes32(uint256(uint160(destination))));
        vm.store(address(settler), bytes32(uint256(fillSlot) + 2), bytes32(uint256(DEFAULT_PRODUCE_AMOUNT)));
        vm.store(address(settler), bytes32(uint256(fillSlot) + 3), bytes32(uint256(block.timestamp)));

        // Also write _rolloverOutputHash[orderId] (slot 6)
        vm.store(address(settler), keccak256(abi.encode(orderId, uint256(6))), rolloverOH);

        vm.prank(filler);
        premium.setOperator(address(settler), true);

        vm.prank(filler);
        vm.expectRevert(IntentNotBoundToOrder.selector);
        settler.fill(orderId, abi.encode(order), _premiumFillerData(filler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  AS-19 / AS-21 ingress gates — RFC 003 §6.2
    // ═══════════════════════════════════════════════════════════════

    /// @dev Builds an Exact order with the two gate fields applied, re-signs the intent, and
    ///      opens the order for `filler`. Centralised so every gate test shares the same
    ///      construction and any drift is caught in a single place.
    function _openExactOrderWithGates(uint256 minFillSize, address exclusiveFiller_)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrder(user, DEFAULT_ORDER_SIZE);
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
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        mockFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        _openForExact(order, user, filler);
    }

    // -- AS-21: exclusiveFiller set AND msg.sender != exclusiveFiller → NotExclusiveFiller --

    function test_fill_exclusiveFiller_wrongCaller_reverts() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _openExactOrderWithGates(0, filler);
        bytes32 orderId = _computeOrderId(order);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotExclusiveFiller.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    function test_fill_exclusiveFiller_rightCaller_succeeds() public {
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _openExactOrderWithGates(0, filler);
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
        // Rollover record written iff the gate admitted the fill.
        bytes32 roh = LibSettlerHashing.computeOutputHash(_rolloverOutput(order));
        (,,, uint64 filledAt) = settler.fillRecords(orderId, roh);
        assertGt(filledAt, 0, "fill must be accepted by the authorized exclusive filler");
    }

    // -- AS-19: minFillSize non-zero AND output.amount < minFillSize → BelowMinFillSize --

    function test_fill_belowMinFillSize_reverts() public {
        // Set minFillSize above the rollover leg's `output.amount` (== orderSize == 1000e18).
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _openExactOrderWithGates(DEFAULT_ORDER_SIZE + 1, address(0));
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        vm.expectRevert(BelowMinFillSize.selector);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
    }

    function test_fill_atMinFillSize_succeeds() public {
        // Set minFillSize exactly at output.amount — the gate's strict `<` admits this fill.
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _openExactOrderWithGates(DEFAULT_ORDER_SIZE, address(0));
        bytes32 orderId = _computeOrderId(order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), _rolloverFillerData(destination));
        bytes32 roh = LibSettlerHashing.computeOutputHash(_rolloverOutput(order));
        (,,, uint64 filledAt) = settler.fillRecords(orderId, roh);
        assertGt(filledAt, 0, "fill must be accepted when output.amount == minFillSize");
    }

    // -- AS-19: premium leg is NOT subject to BelowMinFillSize (unit mismatch). Exact path. --
    function test_fill_premiumLeg_belowMinFillSize_notGated() public {
        // minFillSize is set in share units; premium leg amount is in premium-token units. A
        // minFillSize greater than the premium amount must NOT gate the premium leg.
        uint256 minFill = DEFAULT_ORDER_SIZE;
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od,) =
            _openExactOrderWithGates(minFill, address(0));
        require(od.outputs[1].amount < minFill, "test setup: premium amount must be < minFillSize");

        // Rollover leg must precede the premium leg on the Exact path.
        _fillRolloverAligned(order, filler, destination);

        // Premium leg must NOT revert with BelowMinFillSize (any other downstream revert is fine
        // to the extent it would apply — here we ensure the gate does not fire).
        vm.prank(filler);
        try settler.fill(_computeOrderId(order), abi.encode(order), _premiumFillerData(filler)) {
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

    /// @dev Helper — returns the rollover output from an order's decoded `OrderData`.
    function _rolloverOutput(IOriginSettler.GaslessCrossChainOrder memory order)
        internal
        pure
        returns (IOriginSettler.Output memory)
    {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        return od.outputs[0];
    }

    // ═══════════════════════════════════════════════════════════════
    //  AS-20 decimal-truncation gate — RFC §6.2
    // ═══════════════════════════════════════════════════════════════
    //
    // The gate sources the decimal offset from
    // `IPoolManager(poolManager).market(srcPoolId).collateralAsset.decimals()` per RFC §6.2
    // line 2009, NOT from `srcCstToken.decimals()`. These tests mock the chain so the gate sees
    // a caller-chosen collateral decimals value (6 for USDC-like, 18 for a no-op).

    /// @dev Builds an Exact order with a caller-chosen rollover-leg amount and re-points the
    ///      AS-20 gate's `market(srcPoolId).collateralAsset` to the caller-supplied collateral.
    ///      The srcPoolId is reused from the base helper (`0x1111`), which the default mock
    ///      already registers.
    function _openExactOrderWithDecimalGate(uint256 orderSize_, address collateralAsset_)
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createExactOrder(user, orderSize_);
        od.dstCstToken = address(dstToken);

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: orderSize_,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        // Re-point the AS-20 gate's market(srcPoolId) to the caller-supplied collateral. The
        // default srcPoolId (`0x1111`) was already mocked at base setUp with an 18-decimal
        // collateral; `_mockMarketForPool` here overwrites that entry for this test.
        _mockMarketForPool(od.srcPoolId, collateralAsset_);

        mockFactory.setRolloverBehavior(address(dstToken), orderSize_);
        _openForExact(order, user, filler);
    }

    // -- AS-20: 6-decimal collateral with aligned fillAmount → gate admits --
    function test_fill_decimalTruncates_sixDecCollateral_aligned_succeeds() public {
        DummyERC20 usdc = new DummyERC20("USDC", "USDC", 6);
        // factor = 10^(18-6) = 10^12. An aligned amount: 1000e18 = 1e21, divisible by 1e12.
        uint256 aligned = 1000e18;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) = _openExactOrderWithDecimalGate(aligned, address(usdc));

        vm.prank(filler);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
        bytes32 roh = LibSettlerHashing.computeOutputHash(_rolloverOutput(order));
        (,,, uint64 filledAt) = settler.fillRecords(_computeOrderId(order), roh);
        assertGt(filledAt, 0, "AS-20: aligned fill must be accepted");
    }

    // -- AS-20: 6-decimal collateral with unaligned fillAmount → DecimalTruncates --
    function test_fill_decimalTruncates_sixDecCollateral_unaligned_reverts() public {
        DummyERC20 usdc = new DummyERC20("USDC", "USDC", 6);
        // factor = 10^12; an unaligned amount: 1000e18 + 1 is not divisible by 10^12.
        uint256 unaligned = 1000e18 + 1;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _openExactOrderWithDecimalGate(unaligned, address(usdc));

        vm.prank(filler);
        vm.expectRevert(DecimalTruncates.selector);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
    }

    // -- AS-20: 18-decimal collateral → gate is a no-op regardless of modulo --
    function test_fill_decimalTruncates_eighteenDecCollateral_isNoop() public {
        DummyERC20 eighteenDec = new DummyERC20("ETH18", "ETH", 18);
        // Any amount: 1000e18 + 1 — the gate must NOT fire because the early-return path hits
        // before the modulo check (factor would be 10^0 = 1, trivially aligned — but the
        // early return avoids even computing it).
        uint256 anyAmount = 1000e18 + 1;
        (IOriginSettler.GaslessCrossChainOrder memory order,,) =
            _openExactOrderWithDecimalGate(anyAmount, address(eighteenDec));

        vm.prank(filler);
        settler.fill(_computeOrderId(order), abi.encode(order), _rolloverFillerData(destination));
        bytes32 roh = LibSettlerHashing.computeOutputHash(_rolloverOutput(order));
        (,,, uint64 filledAt) = settler.fillRecords(_computeOrderId(order), roh);
        assertGt(filledAt, 0, "AS-20: 18-decimal collateral gate must admit any non-zero amount");
    }
}
