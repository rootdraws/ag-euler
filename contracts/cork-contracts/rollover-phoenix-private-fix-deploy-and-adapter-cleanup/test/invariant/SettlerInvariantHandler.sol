// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockSettlerFactory} from "test/exact/MockSettlerFactory.sol";
import {MockPartialFactory} from "test/partial/MockPartialFactory.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {
    OrderData,
    OriginFillerData,
    PartialFillerData,
    RolloverFillerData,
    PremiumFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {IPoolManager, Market, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {IPoolShare} from "phoenix/interfaces/IPoolShare.sol";
import {CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @notice Tracks metadata for each order created by the handler.
struct OrderRecord {
    bytes32 orderId;
    bytes32 orderDigest;
    IOriginSettler.GaslessCrossChainOrder order;
    OrderData od;
    CellarIntent intent;
    bool isPartial;
}

/// @notice Shared invariant handler for ExactFillSettler and PartialFillSettler fuzz campaigns.
contract SettlerInvariantHandler is Test {
    uint256 public constant MAX_ORDERS = 8;
    uint256 public constant FILLER_COUNT = 4;
    uint256 public constant DEFAULT_ORDER_SIZE = 1000e18;
    uint256 public constant DEFAULT_PRODUCE_AMOUNT = 1000e18;
    uint256 public constant DEFAULT_MIN_PREMIUM = 1e16;

    MockSettlerFactory public mockExactFactory;
    MockPartialFactory public mockPartialFactory;
    ERC6909Premium public premium;
    ExactFillSettler public exactSettler;
    PartialFillSettler public partialSettler;

    DummyERC20 public srcToken;
    DummyERC20 public dstToken;
    DummyERC20 public premiumToken;

    Vm.Wallet[] internal _fillers;
    Vm.Wallet internal _maker;

    OrderRecord[] public orders;
    uint256 public orderCount;

    // Ghost variables
    mapping(bytes32 => uint256) public ghost_exactDstEscrow;
    mapping(bytes32 => uint256) public ghost_partialTotalEscrow;
    mapping(bytes32 => OrderStatus) public ghost_orderStatus;
    mapping(bytes32 => OrderStatus) public ghost_prevStatus;
    mapping(bytes32 => uint256) public ghost_filledAt;
    mapping(bytes32 => bool) public ghost_rolloverFilled;
    mapping(bytes32 => bool) public ghost_premiumFilled;
    mapping(bytes32 => mapping(address => bool)) public ghost_fillerFinalised;
    mapping(bytes32 => mapping(address => bool)) public ghost_fillerRefunded;
    mapping(bytes32 => uint256) public ghost_participantCount;
    mapping(bytes32 => uint256) public ghost_fillDeadline;
    mapping(bytes32 => uint256) public ghost_cancelledTimestamp;
    mapping(bytes32 => uint256) public ghost_refundedTimestamp;
    bytes32[] public ghost_terminalOrders;
    mapping(bytes32 => bool) public ghost_isTerminal;
    mapping(bytes32 => mapping(address => uint256)) public ghost_fillerSrcProvided;
    mapping(bytes32 => mapping(address => bool)) public ghost_fillerPremiumSettled;
    mapping(bytes32 => mapping(address => uint256)) public ghost_fillerDstProduced;
    mapping(bytes32 => bool) public ghost_postTerminalWriteAttempted;
    mapping(bytes32 => uint256) public ghost_totalPremiumCollected;

    /// @notice Count of `OrderAttribution` events observed per `(orderId, filler)` pair across the
    ///         campaign (Task 38 / #47). Populated by scanning recorded logs after each finalise
    ///         handler action — `vm.recordLogs` is cleared on read, so the counter is monotonic.
    ///         `invariant_*_attributionEventParity` asserts every finalised filler slot saw
    ///         exactly one emission.
    mapping(bytes32 => mapping(address => uint256)) public ghost_attributionEmitted;

    /// @notice Topic-0 of `OrderAttribution(bytes32,address,address,address,uint256,uint256)` —
    ///         precomputed so handler actions can match emissions without recomputing the hash.
    bytes32 internal constant _ATTRIBUTION_TOPIC0 =
        keccak256("OrderAttribution(bytes32,address,address,address,uint256,uint256)");

    constructor() {
        srcToken = new DummyERC20("SrcCST", "SRC", 18);
        dstToken = new DummyERC20("DstCST", "DST", 18);
        premiumToken = new DummyERC20("Premium", "PREM", 18);

        premium = new ERC6909Premium();

        mockExactFactory = new MockSettlerFactory();
        mockPartialFactory = new MockPartialFactory();

        exactSettler = new ExactFillSettler(address(mockExactFactory), address(premium));
        partialSettler = new PartialFillSettler(address(mockPartialFactory), address(premium));

        mockExactFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        mockPartialFactory.setRolloverBehavior(address(dstToken), DEFAULT_PRODUCE_AMOUNT);
        mockPartialFactory.setOriginatingSettler(address(0));

        _maker = vm.createWallet("maker");

        mockExactFactory.setCellar(_maker.addr, address(mockExactFactory));
        mockPartialFactory.setCellar(_maker.addr, address(mockPartialFactory));

        for (uint256 i; i < FILLER_COUNT; ++i) {
            _fillers.push(vm.createWallet(string(abi.encodePacked("filler", i))));
        }

        // AS-20 decimal-truncation gate needs `IPoolShare(srcCstToken).poolManager().market
        // (srcPoolId).collateralAsset` to resolve. Mock the chain so the gate sees the 18-decimal
        // `srcToken` as the collateral — this makes the gate a no-op, preserving the invariant
        // handler's pre-gate behaviour. Tests in `_fill.t.sol` exercise the gate's revert path
        // explicitly with a 6-decimal collateral.
        address sentinelPM = address(uint160(uint256(keccak256("SettlerInvariantHandler:pm"))));
        vm.mockCall(address(srcToken), abi.encodeWithSelector(IPoolShare.poolManager.selector), abi.encode(sentinelPM));
        Market memory m = Market({
            collateralAsset: address(srcToken),
            referenceAsset: address(0),
            expiryTimestamp: 0,
            rateMin: 0,
            rateMax: 0,
            rateChangePerDayMax: 0,
            rateChangeCapacityMax: 0,
            rateOracle: address(0)
        });
        vm.mockCall(
            sentinelPM,
            abi.encodeWithSelector(IPoolManager.market.selector, MarketId.wrap(bytes32(uint256(0x1111)))),
            abi.encode(m)
        );
    }

    function orderAt(uint256 i) external view returns (OrderRecord memory) {
        return orders[i];
    }

    function fillerAddr(uint256 i) external view returns (address) {
        return _fillers[i].addr;
    }

    function ghostTerminalOrdersLength() external view returns (uint256) {
        return ghost_terminalOrders.length;
    }

    /// @notice Returns all order digests tracked by the handler.
    function orderDigests() external view returns (bytes32[] memory digests) {
        digests = new bytes32[](orderCount);
        for (uint256 i; i < orderCount; ++i) {
            digests[i] = orders[i].orderDigest;
        }
    }

    /// @notice Returns true iff participantCount > 0 for the given digest.
    function hasAnyFills(bytes32 digest) external view returns (bool) {
        return partialSettler.participantCount(digest) > 0;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Handler actions
    // ═══════════════════════════════════════════════════════════════

    function open_exact(uint256 orderSeed) external {
        if (orderCount >= MAX_ORDERS) return;
        _createAndOpenExact(orderSeed, false);
    }

    function openFor_exact(uint256 orderSeed) external {
        if (orderCount >= MAX_ORDERS) return;
        _createAndOpenExact(orderSeed, true);
    }

    function fill_rolloverLeg_exact(uint256 orderSeed, uint256 fillerSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (rec.isPartial) return;

        address filler = _selectFiller(fillerSeed);
        bytes32 oid = rec.orderId;

        if (ghost_rolloverFilled[oid]) return;

        bytes memory fillerData = abi.encode(uint8(0), RolloverFillerData({destination: filler}));
        vm.prank(filler);
        try exactSettler.fill(oid, abi.encode(rec.order), fillerData) {
            ghost_rolloverFilled[oid] = true;
            ghost_exactDstEscrow[oid] = DEFAULT_PRODUCE_AMOUNT;
            ghost_filledAt[oid] = block.timestamp;
        } catch {}
    }

    function fill_premiumLeg_exact(uint256 orderSeed, uint256 fillerSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (rec.isPartial) return;

        address filler = _selectFiller(fillerSeed);
        bytes32 oid = rec.orderId;

        if (!ghost_rolloverFilled[oid] || ghost_premiumFilled[oid]) return;

        _ensurePremiumBalance(filler, rec.od.minPremiumPerShare);

        bytes memory fillerData = abi.encode(uint8(1), PremiumFillerData({debitFrom: filler}));
        vm.prank(filler);
        try exactSettler.fill(oid, abi.encode(rec.order), fillerData) {
            ghost_premiumFilled[oid] = true;
            uint256 premAmt = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, rec.od.minPremiumPerShare, 1e18, Math.Rounding.Ceil);
            ghost_totalPremiumCollected[oid] += premAmt;
        } catch {}
    }

    function finaliseAsSettled_exact(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (rec.isPartial) return;

        bytes32 oid = rec.orderId;
        // Cycle-1 C4 — flush any stale log buffer from a prior handler action so the scanning
        // window below is always exactly one `finaliseAsSettled` call. Survives future emission
        // sites (e.g. `rescueSettled` growing attribution support) that would otherwise silently
        // over-count into the next finalise's drain.
        vm.getRecordedLogs();
        vm.recordLogs();
        try exactSettler.finaliseAsSettled(oid) {
            _transitionStatus(oid, OrderStatus.Settled, rec.order.fillDeadline);
            ghost_exactDstEscrow[oid] = 0;
            _recordAttributionEmissions();
        } catch {}
    }

    function finaliseAsRefunded_exact(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (rec.isPartial) return;

        bytes32 oid = rec.orderId;
        try exactSettler.finaliseAsRefunded(oid, rec.order) {
            _transitionStatus(oid, OrderStatus.Refunded, rec.order.fillDeadline);
            ghost_refundedTimestamp[oid] = block.timestamp;
            ghost_exactDstEscrow[oid] = 0;
        } catch {}
    }

    function finaliseAsCancelled_exact(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (rec.isPartial) return;

        bytes32 oid = rec.orderId;
        vm.prank(_maker.addr);
        try exactSettler.finaliseAsCancelled(oid, rec.order, "") {
            _transitionStatus(oid, OrderStatus.Cancelled, rec.order.fillDeadline);
            ghost_cancelledTimestamp[oid] = block.timestamp;
        } catch {}
    }

    function open_partial(uint256 orderSeed) external {
        if (orderCount >= MAX_ORDERS) return;
        _createAndOpenPartial(orderSeed, false);
    }

    function openFor_partial(uint256 orderSeed) external {
        if (orderCount >= MAX_ORDERS) return;
        _createAndOpenPartial(orderSeed, true);
    }

    function fill_rolloverLeg_partial(uint256 orderSeed, uint256 fillerSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        address filler = _selectFiller(fillerSeed);
        bytes32 digest = rec.orderDigest;
        bytes32 oid = rec.orderId;

        if (ghost_fillerSrcProvided[digest][filler] != 0) return;

        bytes memory fillerData = abi.encode(
            uint8(0),
            PartialFillerData({
                destination: filler, debitFrom: address(0), targetFiller: filler, intent: rec.intent, cellarSig: ""
            })
        );
        vm.prank(filler);
        try partialSettler.fill(oid, abi.encode(rec.order), fillerData) {
            ghost_fillerSrcProvided[digest][filler] = DEFAULT_PRODUCE_AMOUNT;
            ghost_fillerDstProduced[digest][filler] = DEFAULT_PRODUCE_AMOUNT;
            ghost_partialTotalEscrow[digest] += DEFAULT_PRODUCE_AMOUNT;
            ghost_participantCount[digest] += 1;
            ghost_filledAt[oid] = block.timestamp;
        } catch {}
    }

    function fill_premiumLeg_partial(uint256 orderSeed, uint256 fillerSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        address filler = _selectFiller(fillerSeed);
        bytes32 digest = rec.orderDigest;
        bytes32 oid = rec.orderId;

        if (ghost_fillerSrcProvided[digest][filler] == 0) return;
        if (ghost_fillerPremiumSettled[digest][filler]) return;

        _ensurePremiumBalance(filler, rec.od.minPremiumPerShare);

        bytes memory fillerData = abi.encode(
            uint8(1),
            PartialFillerData({
                destination: address(0), debitFrom: filler, targetFiller: filler, intent: rec.intent, cellarSig: ""
            })
        );
        vm.prank(filler);
        try partialSettler.fill(oid, abi.encode(rec.order), fillerData) {
            ghost_fillerPremiumSettled[digest][filler] = true;
            uint256 premAmt = Math.mulDiv(
                ghost_fillerDstProduced[digest][filler], rec.od.minPremiumPerShare, 1e18, Math.Rounding.Ceil
            );
            ghost_totalPremiumCollected[digest] += premAmt;
        } catch {}
    }

    function finaliseAsSettled_partial(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        bytes32 digest = rec.orderDigest;
        address[] memory fillers = _allFillerAddrs();

        // Cycle-1 C4 — flush any stale log buffer so the scanning window below is always exactly
        // one `finaliseAsSettled` call.
        vm.getRecordedLogs();
        vm.recordLogs();
        try partialSettler.finaliseAsSettled(digest, fillers) {
            for (uint256 i; i < fillers.length; ++i) {
                IPartialFillSettler.FillerRollover memory f = partialSettler.fillerRollovers(digest, fillers[i]);
                if (f.finalised && !ghost_fillerFinalised[digest][fillers[i]]) {
                    ghost_fillerFinalised[digest][fillers[i]] = true;
                    ghost_partialTotalEscrow[digest] -= f.dstCstProduced;
                }
            }
            OrderStatus newStatus = partialSettler.orderStatus(rec.orderId);
            if (newStatus == OrderStatus.Settled) {
                _transitionStatus(rec.orderId, OrderStatus.Settled, rec.order.fillDeadline);
            }
            _recordAttributionEmissions();
        } catch {}
    }

    function finaliseAsRefunded_partial(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        bytes32 digest = rec.orderDigest;
        address[] memory fillers = _allFillerAddrs();

        try partialSettler.finaliseAsRefunded(digest, rec.order, fillers) {
            for (uint256 i; i < fillers.length; ++i) {
                IPartialFillSettler.FillerRollover memory f = partialSettler.fillerRollovers(digest, fillers[i]);
                if (f.refunded && !ghost_fillerRefunded[digest][fillers[i]]) {
                    ghost_fillerRefunded[digest][fillers[i]] = true;
                    ghost_partialTotalEscrow[digest] -= ghost_fillerDstProduced[digest][fillers[i]];
                }
            }
            OrderStatus newStatus = partialSettler.orderStatus(rec.orderId);
            if (newStatus == OrderStatus.Refunded) {
                _transitionStatus(rec.orderId, OrderStatus.Refunded, rec.order.fillDeadline);
                ghost_refundedTimestamp[rec.orderId] = block.timestamp;
            }
        } catch {}
    }

    function finaliseAsCancelled_partial(uint256 orderSeed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(orderSeed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        bytes32 oid = rec.orderId;
        vm.prank(_maker.addr);
        try partialSettler.finaliseAsCancelled(rec.orderDigest, rec.order, "") {
            _transitionStatus(oid, OrderStatus.Cancelled, rec.order.fillDeadline);
            ghost_cancelledTimestamp[oid] = block.timestamp;
        } catch {}
    }

    function advanceTime(uint256 delta) external {
        delta = bound(delta, 1, 4 hours);
        vm.warp(block.timestamp + delta);
    }

    /// @notice Selects a random filler from the tracked list and settles premium if eligible.
    function actionSettlePremiumForRandomFiller(uint256 seed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(seed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        bytes32 digest = rec.orderDigest;
        bytes32 oid = rec.orderId;
        address filler = _selectFiller(seed >> 8);

        if (ghost_fillerSrcProvided[digest][filler] == 0) return;
        if (ghost_fillerPremiumSettled[digest][filler]) return;

        _ensurePremiumBalance(filler, rec.od.minPremiumPerShare);

        bytes memory fillerData = abi.encode(
            uint8(1),
            PartialFillerData({
                destination: address(0), debitFrom: filler, targetFiller: filler, intent: rec.intent, cellarSig: ""
            })
        );
        vm.prank(filler);
        try partialSettler.fill(oid, abi.encode(rec.order), fillerData) {
            ghost_fillerPremiumSettled[digest][filler] = true;
            uint256 premAmt = Math.mulDiv(
                ghost_fillerDstProduced[digest][filler], rec.od.minPremiumPerShare, 1e18, Math.Rounding.Ceil
            );
            ghost_totalPremiumCollected[digest] += premAmt;
        } catch {}
    }

    /// @notice Advances time past fillDeadline without settling premium for some fillers.
    function actionSkipPremiumAdvanceTime(uint256 seed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(seed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        uint256 deadline = rec.order.fillDeadline;
        if (block.timestamp > deadline) return;

        uint256 jump = deadline - block.timestamp + bound(seed >> 8, 1, 1 hours);
        vm.warp(block.timestamp + jump);
    }

    /// @notice Calls finaliseAsSettled on settled fillers + finaliseAsRefunded on unsettled fillers.
    function actionMixedFinalise(uint256 seed) external {
        if (orderCount == 0) return;
        uint256 idx = bound(seed, 0, orderCount - 1);
        OrderRecord memory rec = orders[idx];
        if (!rec.isPartial) return;

        bytes32 digest = rec.orderDigest;
        address[] memory fillers = _allFillerAddrs();

        // First try settling eligible fillers
        // Cycle-1 C4 — flush any stale log buffer so the scanning window below is always exactly
        // one `finaliseAsSettled` call.
        vm.getRecordedLogs();
        vm.recordLogs();
        try partialSettler.finaliseAsSettled(digest, fillers) {
            for (uint256 i; i < fillers.length; ++i) {
                IPartialFillSettler.FillerRollover memory f = partialSettler.fillerRollovers(digest, fillers[i]);
                if (f.finalised && !ghost_fillerFinalised[digest][fillers[i]]) {
                    ghost_fillerFinalised[digest][fillers[i]] = true;
                    ghost_partialTotalEscrow[digest] -= f.dstCstProduced;
                }
            }
            OrderStatus newStatus = partialSettler.orderStatus(rec.orderId);
            if (newStatus == OrderStatus.Settled) {
                _transitionStatus(rec.orderId, OrderStatus.Settled, rec.order.fillDeadline);
            }
            _recordAttributionEmissions();
        } catch {}

        // Then try refunding unsettled fillers
        try partialSettler.finaliseAsRefunded(digest, rec.order, fillers) {
            for (uint256 i; i < fillers.length; ++i) {
                IPartialFillSettler.FillerRollover memory f = partialSettler.fillerRollovers(digest, fillers[i]);
                if (f.refunded && !ghost_fillerRefunded[digest][fillers[i]]) {
                    ghost_fillerRefunded[digest][fillers[i]] = true;
                    ghost_partialTotalEscrow[digest] -= ghost_fillerDstProduced[digest][fillers[i]];
                }
            }
            OrderStatus newStatus = partialSettler.orderStatus(rec.orderId);
            if (newStatus == OrderStatus.Refunded) {
                _transitionStatus(rec.orderId, OrderStatus.Refunded, rec.order.fillDeadline);
                ghost_refundedTimestamp[rec.orderId] = block.timestamp;
            }
        } catch {}
    }

    function depositPremium(uint256 fillerSeed, uint256 amount) external {
        amount = bound(amount, 1, 10_000e18);
        address filler = _selectFiller(fillerSeed);
        premiumToken.mint(filler, amount);
        vm.startPrank(filler);
        premiumToken.approve(address(premium), amount);
        premium.deposit(address(premiumToken), filler, amount);
        vm.stopPrank();
    }

    function setOperator_erc6909(uint256 ownerSeed, uint256 operatorSeed) external {
        address owner = _selectFiller(ownerSeed);
        address operator = _selectFiller(operatorSeed);
        if (owner == operator) return;
        vm.prank(owner);
        premium.setOperator(operator, true);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: order creation
    // ═══════════════════════════════════════════════════════════════

    function _createAndOpenExact(uint256 seed, bool useOpenFor) internal {
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildExactOrder(seed);

        if (useOpenFor) {
            bytes memory sig = _signExact(order);
            bytes memory ofd =
                abi.encode(OriginFillerData({outputAmount: DEFAULT_ORDER_SIZE, repaymentTo: _maker.addr}));
            try exactSettler.openFor(order, sig, ofd) {}
            catch {
                return;
            }
        } else {
            vm.prank(_maker.addr);
            try exactSettler.open(
                IOriginSettler.OnchainCrossChainOrder({
                    fillDeadline: order.fillDeadline, orderDataType: order.orderDataType, orderData: order.orderData
                })
            ) {}
            catch {
                return;
            }
        }

        orders.push(
            OrderRecord({
                orderId: orderId, orderDigest: orderDigest, order: order, od: od, intent: intent, isPartial: false
            })
        );
        orderCount += 1;
        ghost_orderStatus[orderId] = OrderStatus.Opened;
        ghost_prevStatus[orderId] = OrderStatus.None;
        ghost_fillDeadline[orderId] = order.fillDeadline;
    }

    function _createAndOpenPartial(uint256 seed, bool useOpenFor) internal {
        (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            CellarIntent memory intent,
            bytes32 orderId,
            bytes32 orderDigest
        ) = _buildPartialOrder(seed);

        if (useOpenFor) {
            bytes memory sig = _signPartial(order);
            bytes memory ofd =
                abi.encode(OriginFillerData({outputAmount: DEFAULT_ORDER_SIZE, repaymentTo: _maker.addr}));
            try partialSettler.openFor(order, sig, ofd) {}
            catch {
                return;
            }
        } else {
            vm.prank(_maker.addr);
            try partialSettler.open(
                IOriginSettler.OnchainCrossChainOrder({
                    fillDeadline: order.fillDeadline, orderDataType: order.orderDataType, orderData: order.orderData
                })
            ) {}
            catch {
                return;
            }
        }

        orders.push(
            OrderRecord({
                orderId: orderId, orderDigest: orderDigest, order: order, od: od, intent: intent, isPartial: true
            })
        );
        orderCount += 1;
        ghost_orderStatus[orderId] = OrderStatus.Opened;
        ghost_prevStatus[orderId] = OrderStatus.None;
        ghost_fillDeadline[orderId] = order.fillDeadline;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: order building
    // ═══════════════════════════════════════════════════════════════

    function _buildExactOrder(uint256 seed)
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
        (order, od) = _baseOrder(seed, false);

        orderDigest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = CellarIntent({
            orderDigest: orderDigest,
            expectedCaller: address(mockExactFactory),
            settler: address(exactSettler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
    }

    function _buildPartialOrder(uint256 seed)
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
        (order, od) = _baseOrder(seed, true);

        orderDigest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = CellarIntent({
            orderDigest: orderDigest,
            expectedCaller: address(mockPartialFactory),
            settler: address(partialSettler),
            deadline: uint256(order.fillDeadline),
            orderSize: DEFAULT_ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        orderId = LibSettlerHashing.computeOrderId(address(partialSettler), order);
    }

    function _baseOrder(uint256 seed, bool isPartial)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
    {
        // AS-19 / AS-21 / AS-22 fuzzing. Three-bucket regime (25% / 50% / 25%) derived from a
        // 3-bit slice of `seed`. Bucket 0: unconstrained (`minFillSize == 0`). Bucket 1:
        // intermediate (`DEFAULT_ORDER_SIZE / 2`) — exercises the AS-22 residual-truncation path
        // whenever the handler submits sub-orderSize fills. Bucket 2: strict
        // (`minFillSize == DEFAULT_ORDER_SIZE`). `exclusiveFiller` rotates across the tracked
        // filler set so at most one filler is ever authorized per exclusive order.
        uint256 bucket = seed & 7;
        uint256 minFillSize_;
        if (bucket < 2) {
            // 25% chance (0, 1) — unconstrained
            minFillSize_ = 0;
        } else if (bucket < 6) {
            // 50% chance (2, 3, 4, 5) — intermediate
            minFillSize_ = DEFAULT_ORDER_SIZE / 2;
        } else {
            // 25% chance (6, 7) — strict
            minFillSize_ = DEFAULT_ORDER_SIZE;
        }
        address exclusiveFiller_;
        if (seed & 2 == 2 && _fillers.length > 0) {
            exclusiveFiller_ = _fillers[(seed >> 2) % _fillers.length].addr;
        }
        // Partial orders may use a sub-orderSize rollover-leg `output.amount` so the AS-22
        // residual path can be reached. Exact orders keep `amount == orderSize` (the Exact
        // settler reverts `PartialFillNotAllowed` otherwise). Amount is still a clean multiple
        // of 1e18 so AS-20 (decimal-truncation) never fires for the default 18-decimal pool.
        uint256 rolloverAmount_ = DEFAULT_ORDER_SIZE;
        if (isPartial && minFillSize_ == DEFAULT_ORDER_SIZE / 2 && (seed & 32) == 32) {
            // ~half the intermediate-minFillSize orders submit a sub-orderSize fill that would
            // leave a residual of 300e18 — below the 500e18 minFillSize → AS-22 must fire.
            rolloverAmount_ = 700e18;
        }
        IOriginSettler.Output[] memory outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(dstToken)))),
            amount: rolloverAmount_,
            recipient: bytes32(uint256(uint160(_maker.addr))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(premiumToken)))),
            amount: DEFAULT_MIN_PREMIUM,
            recipient: bytes32(uint256(uint160(_maker.addr))),
            chainId: block.chainid
        });

        Call[] memory rolloverHooks = new Call[](1);
        rolloverHooks[0] =
            Call({target: address(1), value: 0, callData: "", allowFailure: false, isDelegateCall: false});
        Call[] memory premiumHooks = new Call[](0);

        od = OrderData({
            receiver: _maker.addr,
            srcPoolId: MarketId.wrap(bytes32(uint256(0x1111))),
            dstPoolId: MarketId.wrap(bytes32(uint256(0x2222))),
            srcCstToken: address(srcToken),
            dstCstToken: address(dstToken),
            premiumToken: address(premiumToken),
            repaymentToken: address(srcToken),
            repaymentAmount: 100e18,
            orderSize: DEFAULT_ORDER_SIZE,
            minFillSize: minFillSize_,
            allowPartialFills: isPartial,
            allowUnderfill: false,
            exclusiveFiller: exclusiveFiller_,
            minPremiumPerShare: DEFAULT_MIN_PREMIUM,
            cellarIntentHash: bytes32(0),
            outputs: outputs,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks,
            cellarSignature: ""
        });

        order = IOriginSettler.GaslessCrossChainOrder({
            originSettler: isPartial ? address(partialSettler) : address(exactSettler),
            user: _maker.addr,
            nonce: uint256(keccak256(abi.encodePacked(_maker.addr, block.timestamp, seed))),
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: signing
    // ═══════════════════════════════════════════════════════════════

    function _signExact(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes memory) {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", exactSettler.domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_maker.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    function _signPartial(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes memory) {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", partialSettler.domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_maker.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal: helpers
    // ═══════════════════════════════════════════════════════════════

    function _selectFiller(uint256 seed) internal view returns (address) {
        return _fillers[bound(seed, 0, FILLER_COUNT - 1)].addr;
    }

    function _allFillerAddrs() internal view returns (address[] memory addrs) {
        addrs = new address[](FILLER_COUNT);
        for (uint256 i; i < FILLER_COUNT; ++i) {
            addrs[i] = _fillers[i].addr;
        }
    }

    function _ensurePremiumBalance(address filler, uint256 minPremiumPerShare) internal {
        uint256 needed = Math.mulDiv(DEFAULT_PRODUCE_AMOUNT, minPremiumPerShare, 1e18, Math.Rounding.Ceil);
        if (needed == 0) return;
        uint256 tokenId = uint256(uint160(address(premiumToken)));
        uint256 bal = premium.balanceOf(filler, tokenId);
        if (bal >= needed) return;
        uint256 deficit = needed - bal;
        premiumToken.mint(filler, deficit);
        vm.startPrank(filler);
        premiumToken.approve(address(premium), deficit);
        premium.deposit(address(premiumToken), filler, deficit);
        vm.stopPrank();
    }

    /// @notice Scans `vm.getRecordedLogs()` and increments `ghost_attributionEmitted[orderId][filler]`
    ///         for every `OrderAttribution` log. Called after each finalise handler action that
    ///         ran a successful `finaliseAsSettled` — `vm.recordLogs` MUST have been armed before
    ///         the call so the snapshot window is known.
    /// @dev Reads the indexed `orderId` (topic[1]) and `fillerSlot` (topic[2]) — the same key
    ///         shape the parity invariants assert against.
    function _recordAttributionEmissions() internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length < 3) continue;
            if (entries[i].topics[0] != _ATTRIBUTION_TOPIC0) continue;
            bytes32 oid = entries[i].topics[1];
            address fillerSlot = address(uint160(uint256(entries[i].topics[2])));
            ghost_attributionEmitted[oid][fillerSlot] += 1;
        }
    }

    function _transitionStatus(bytes32 oid, OrderStatus newStatus, uint256) internal {
        ghost_prevStatus[oid] = ghost_orderStatus[oid];
        ghost_orderStatus[oid] = newStatus;
        if (!ghost_isTerminal[oid]) {
            ghost_isTerminal[oid] = true;
            ghost_terminalOrders.push(oid);
        }
    }
}
