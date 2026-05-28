// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {DisproportionateOutput} from "contracts/settlers/BaseSettlerErrors.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {IPoolManager, Market, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {IPoolShare} from "phoenix/interfaces/IPoolShare.sol";
import {MockCorkCellarFactoryMalicious} from "test/mocks/MockCorkCellarFactoryMalicious.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

contract PartialFillSettler_maliciousCellar_test is Test {
    MockCorkCellarFactoryMalicious internal maliciousFactory;
    PartialFillSettler internal settler;
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

        settler = new PartialFillSettler(address(maliciousFactory), address(premium));

        // Mock the AS-20 gate's pool-manager chain: `srcCstToken -> poolManager -> market.
        // collateralAsset`. An 18-decimal collateral makes the gate a no-op so the downstream
        // DisproportionateOutput / ZeroDstDelta paths this suite targets are reachable.
        _mockAS20Chain(address(srcToken), address(srcToken), MarketId.wrap(bytes32(uint256(0x1111))));
    }

    /// @dev AS-20 gate mock — wires `IPoolShare.poolManager()` on `srcCstToken` to a sentinel
    ///      address, and `IPoolManager.market(srcPoolId).collateralAsset` on that sentinel to
    ///      `collateral`. The gate reads `collateral.decimals()`; with 18 decimals it short-circuits.
    function _mockAS20Chain(address srcCstToken_, address collateral, MarketId srcPoolId) internal {
        address sentinelPM = address(uint160(uint256(keccak256("PartialFillSettler_maliciousCellar:pm"))));
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

    // ═══════════════════════════════════════════════════════════════
    //  H2 — DisproportionateOutput guard
    // ═══════════════════════════════════════════════════════════════

    function test_rolloverLeg_RevertsOnZeroDstDelta() public {
        // actualRolled=100, dstDelta=0 => 0+1 < 100-0 => revert
        maliciousFactory.setResponse(100, 0, 0);

        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) = _createAndOpenOrder();

        bytes memory fd = _rolloverFD(filler, destination, intent);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(DisproportionateOutput.selector);
        settler.fill(orderId, abi.encode(order), fd);
    }

    function test_rolloverLeg_RevertsOnDisproportionateOutput() public {
        // actualRolled=100, srcLeftover=10 (net=90), dstDelta=50 => 50+1 < 100-10=90 => revert
        maliciousFactory.setResponse(100, 50, 10);

        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) = _createAndOpenOrder();

        bytes memory fd = _rolloverFD(filler, destination, intent);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        vm.expectRevert(DisproportionateOutput.selector);
        settler.fill(orderId, abi.encode(order), fd);
    }

    function test_rolloverLeg_AcceptsOneWeiUnderflow() public {
        // actualRolled=100, srcLeftover=0, dstDelta=99 => 99+1=100, NOT < 100 => pass
        maliciousFactory.setResponse(100, 99, 0);

        (IOriginSettler.GaslessCrossChainOrder memory order,, CellarIntent memory intent) = _createAndOpenOrder();

        bytes memory fd = _rolloverFD(filler, destination, intent);
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);

        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), fd);

        // Verify the fill was recorded
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        assertEq(settler.participantCount(orderDigest), 1);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _createAndOpenOrder()
        internal
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        Call[] memory rolloverHooks = new Call[](0);
        Call[] memory premiumHooks = new Call[](0);

        IOriginSettler.Output[] memory outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(srcToken)))),
            amount: ORDER_SIZE,
            recipient: bytes32(uint256(uint160(user.addr))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(srcToken)))),
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
            allowPartialFills: true,
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
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(maliciousFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: ORDER_SIZE,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);

        // Sign and open
        bytes32 openForDigest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash = keccak256(abi.encodePacked("\x19\x01", settler.domainSeparator(), openForDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        _openOrder(order, sig);
    }

    function _openOrder(IOriginSettler.GaslessCrossChainOrder memory order, bytes memory sig) internal {
        // OriginFillerData: { outputAmount, repaymentTo }
        bytes memory originFillerData = abi.encode(ORDER_SIZE, filler);
        settler.openFor(order, sig, originFillerData);
    }

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
}
