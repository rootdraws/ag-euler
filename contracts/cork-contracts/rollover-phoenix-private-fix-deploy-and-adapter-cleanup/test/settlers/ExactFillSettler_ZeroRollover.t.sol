// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, RolloverFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {ZeroRollover} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {IPoolManager, Market, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {IPoolShare} from "phoenix/interfaces/IPoolShare.sol";
import {MockCorkCellarFactoryMalicious} from "test/mocks/MockCorkCellarFactoryMalicious.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @title ExactFillSettler_ZeroRollover
/// @notice Audit-cycle coverage for Pashov A6: `ExactFillSettler._onRolloverLegFill` now rejects
///         a cellar that signals `actualRolled == 0`, symmetric with the Partial settler. Without
///         the guard, a slot-squatting cellar could drive the Exact settler into a bookkeeping
///         state where `dstCstProduced == 0` yet the fill record is considered valid.
contract ExactFillSettler_ZeroRollover_Test is Test {
    MockCorkCellarFactoryMalicious internal maliciousFactory;
    ExactFillSettler internal settler;
    ERC6909Premium internal premium;
    DummyERC20 internal srcToken;
    DummyERC20 internal dstToken;

    Vm.Wallet internal user;
    address internal filler;
    address internal destination;

    uint256 internal constant ORDER_SIZE = 1000e18;

    function setUp() public {
        user = vm.createWallet("user");
        filler = makeAddr("filler");
        destination = makeAddr("destination");

        srcToken = new DummyERC20("SrcCST", "SRC", 18);
        dstToken = new DummyERC20("DstCST", "DST", 18);

        premium = new ERC6909Premium();
        maliciousFactory = new MockCorkCellarFactoryMalicious();
        maliciousFactory.setCellar(user.addr, address(maliciousFactory));
        maliciousFactory.setTokens(address(srcToken), address(dstToken));
        maliciousFactory.setOriginatingSettler(address(0));

        settler = new ExactFillSettler(address(maliciousFactory), address(premium));

        // Mock the AS-20 gate's pool-manager chain: `srcCstToken -> poolManager -> market.
        // collateralAsset`. An 18-decimal collateral makes the gate a no-op so this test's
        // ZeroRollover path (triggered further downstream) is exercised as designed.
        _mockAS20Chain(address(srcToken), address(srcToken), MarketId.wrap(bytes32(uint256(0x1111))));
    }

    /// @dev AS-20 gate mock — wires `IPoolShare.poolManager()` on `srcCstToken` to a sentinel
    ///      address, and `IPoolManager.market(srcPoolId).collateralAsset` on that sentinel to
    ///      `collateral`. The gate reads `collateral.decimals()`; with 18 decimals it short-circuits.
    function _mockAS20Chain(address srcCstToken_, address collateral, MarketId srcPoolId) internal {
        address sentinelPM = address(uint160(uint256(keccak256("ExactFillSettler_ZeroRollover:pm"))));
        vm.mockCall(srcCstToken_, abi.encodeWithSelector(IPoolShare.poolManager.selector), abi.encode(sentinelPM));
        Market memory m = Market({
            collateralAsset: collateral,
            referenceAsset: address(0),
            expiryTimestamp: 0,
            rateMin: 0,
            rateMax: 0,
            rateChangePerDayMax: 0,
            rateChangeCapacityMax: 0,
            rateOracle: address(0)
        });
        vm.mockCall(sentinelPM, abi.encodeWithSelector(IPoolManager.market.selector, srcPoolId), abi.encode(m));
    }

    /// @notice actualRolled == 0 on the Exact rollover leg must revert `ZeroRollover`, mirroring
    ///         Partial's defense-in-depth guard.
    function test_rolloverLeg_RevertsOnZeroRollover() public {
        // actualRolled = 0; dstDelta/srcLeftover are irrelevant — the guard fires first.
        maliciousFactory.setResponse(0, 0, 0);

        (IOriginSettler.GaslessCrossChainOrder memory order,) = _createAndOpenOrder();

        bytes memory fd = _rolloverFD(destination);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(ZeroRollover.selector);
        settler.fill(orderId, abi.encode(order), fd);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _createAndOpenOrder()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
    {
        Call[] memory rolloverHooks = new Call[](0);
        Call[] memory premiumHooks = new Call[](0);

        IOriginSettler.Output[] memory outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(dstToken)))),
            amount: ORDER_SIZE,
            recipient: bytes32(uint256(uint160(user.addr))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(0xA4EE)))),
            amount: 0,
            recipient: bytes32(uint256(uint160(user.addr))),
            chainId: block.chainid
        });

        od = OrderData({
            receiver: user.addr,
            srcPoolId: MarketId.wrap(bytes32(uint256(0x1111))),
            dstPoolId: MarketId.wrap(bytes32(uint256(0x2222))),
            srcCstToken: address(srcToken),
            dstCstToken: address(dstToken),
            premiumToken: address(0xA4EE),
            repaymentToken: address(srcToken),
            repaymentAmount: 0,
            orderSize: ORDER_SIZE,
            minFillSize: 0,
            allowPartialFills: false,
            allowUnderfill: false,
            exclusiveFiller: address(0),
            minPremiumPerShare: 0,
            cellarIntentHash: bytes32(0),
            outputs: outputs,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks,
            cellarSignature: ""
        });

        order = IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(settler),
            user: user.addr,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: ""
        });

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        CellarIntent memory intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(maliciousFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: ORDER_SIZE,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        bytes32 openForDigest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", settler.domainSeparator(), openForDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes memory originFillerData = abi.encode(ORDER_SIZE, filler);
        settler.openFor(order, sig, originFillerData);
    }

    function _rolloverFD(address dest) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: dest})));
    }
}
