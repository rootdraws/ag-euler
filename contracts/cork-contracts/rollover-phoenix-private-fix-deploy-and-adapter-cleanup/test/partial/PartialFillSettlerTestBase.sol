// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTestSettler} from "test/BaseTestSettler.sol";
import {MockPartialFactory} from "test/partial/MockPartialFactory.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";
import {OrderData, PartialFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH, CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {MarketId} from "phoenix/interfaces/IPoolManager.sol";

abstract contract PartialFillSettlerTestBase is BaseTestSettler {
    MockPartialFactory internal mockFactory;
    PartialFillSettler internal settler;

    uint256 internal constant DEFAULT_PRODUCE_AMOUNT = 1000e18;

    function setUp() public virtual override {
        super.setUp();

        mockFactory = new MockPartialFactory();
        mockFactory.setCellar(user.addr, address(mockFactory));
        mockFactory.setCellar(smartWalletAddr, address(mockFactory));
        mockFactory.setOriginatingSettler(address(0));

        settler = new PartialFillSettler(address(mockFactory), address(premium));

        mockFactory.setRolloverBehavior(address(vaultUnderlying), DEFAULT_PRODUCE_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Signing helpers
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory signature)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(settler_).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        signature = abi.encodePacked(r, s, v);
    }

    function _signOrderWithSmartWallet(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address, /* smartWallet_ */
        address settler_
    ) internal override returns (bytes memory signature) {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(settler_).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        signature = abi.encodePacked(r, s, v);

        vm.prank(user.addr);
        smartWallet.sign(eip712Hash, signature);
    }

    function _signCancel(bytes32 orderId, uint256 cancelDeadline, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory signature)
    {
        bytes32 cancelDigest = keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, cancelDeadline));
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(settler_).domainSeparator(), cancelDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);
        signature = abi.encodePacked(cancelDeadline, ecdsaSig);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Order helpers — partial-specific (2 outputs, allowPartialFills = true)
    // ═══════════════════════════════════════════════════════════════

    function _createPartialOrder(Vm.Wallet memory uw, uint256 orderSize)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        return _createPartialOrderWithPremium(uw, orderSize, DEFAULT_MIN_PREMIUM_PER_SHARE);
    }

    function _createPartialOrderWithPremium(Vm.Wallet memory uw, uint256 orderSize, uint256 minPremiumPerShare)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createRolloverOrder(uw, orderSize, true, false, address(settler));

        // Extend to 2 outputs (rollover + premium)
        IOriginSettler.Output[] memory outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(vaultUnderlying)))),
            amount: orderSize,
            recipient: bytes32(uint256(uint160(uw.addr))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(vaultUnderlying)))),
            amount: minPremiumPerShare,
            recipient: bytes32(uint256(uint160(uw.addr))),
            chainId: block.chainid
        });

        // Distinct premium token to satisfy INV-S15 (srcCstToken != premiumToken)
        od.premiumToken = address(0xA4EE);
        od.minPremiumPerShare = minPremiumPerShare;
        od.outputs = outputs;

        // Recompute cellarIntentHash and orderData
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(settler), order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(mockFactory),
            settler: address(settler),
            deadline: uint256(order.fillDeadline),
            orderSize: orderSize,
            allowPartialFills: true,
            allowUnderfill: false,
            rolloverHooks: od.rolloverHooks,
            premiumHooks: od.premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));
        order.orderData = abi.encode(od);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Fill helpers
    // ═══════════════════════════════════════════════════════════════

    function _openForPartial(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory uw, address repayTo)
        internal
    {
        bytes memory sig = _signOrder(order, uw, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, repayTo);
        settler.openFor(order, sig, originFillerData);
    }

    function _fillRollover(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address filler,
        address destination,
        CellarIntent memory intent,
        bytes memory cellarSig
    ) internal {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(0)),
            abi.encode(
                PartialFillerData({
                    destination: destination,
                    debitFrom: address(0),
                    targetFiller: filler,
                    intent: intent,
                    cellarSig: cellarSig
                })
            )
        );
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    function _fillPremium(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address targetFiller,
        address filler,
        address debitFrom,
        CellarIntent memory intent,
        bytes memory cellarSig
    ) internal {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = bytes.concat(
            bytes1(uint8(1)),
            abi.encode(
                PartialFillerData({
                    destination: address(0),
                    debitFrom: debitFrom,
                    targetFiller: targetFiller,
                    intent: intent,
                    cellarSig: cellarSig
                })
            )
        );
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Digest / hash helpers
    // ═══════════════════════════════════════════════════════════════

    function _computeOrderId(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes32) {
        return LibSettlerHashing.computeOrderId(address(settler), order);
    }

    function _computeOrderDigest(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes32) {
        OrderData memory od = abi.decode(order.orderData, (OrderData));
        return LibSettlerHashing.computeOrderDigest(address(settler), order, od);
    }

    function _computeOutputHash(IOriginSettler.Output memory output) internal pure returns (bytes32) {
        return LibSettlerHashing.computeOutputHash(output);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Snapshot stubs (not exercised in partial-fill unit tests yet)
    // ═══════════════════════════════════════════════════════════════

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory) {
        return SettlerSnapshot(0, 0, 0, 0, 0);
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}
}
