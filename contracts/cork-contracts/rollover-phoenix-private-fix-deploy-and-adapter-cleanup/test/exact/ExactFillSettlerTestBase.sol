// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTestSettler} from "test/BaseTestSettler.sol";
import {MockSettlerFactory} from "test/exact/MockSettlerFactory.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {IExactFillSettler} from "contracts/interfaces/IExactFillSettler.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH, CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {MarketId} from "phoenix/interfaces/IPoolManager.sol";

abstract contract ExactFillSettlerTestBase is BaseTestSettler {
    MockSettlerFactory internal mockFactory;
    ExactFillSettler internal settler;

    uint256 internal constant DEFAULT_PRODUCE_AMOUNT = 1000e18;

    function setUp() public virtual override {
        super.setUp();

        mockFactory = new MockSettlerFactory();
        // MockSettlerFactory doubles as both factory and cellar so the settler's
        // `ICorkCellarPremiumView(cellar).premiumFiredFor(...)` parity assertion (#61 / I4)
        // resolves against the mock's own mirrored `premiumFiredForMap`. Previously the mock
        // forwarded to the real `CorkCellar`, whose `premiumFiredFor` never latched because
        // the mock's `executeIntentHooks` short-circuits before reaching the live cellar.
        mockFactory.setCellar(user.addr, address(mockFactory));
        mockFactory.setCellar(smartWalletAddr, address(mockFactory));

        settler = new ExactFillSettler(address(mockFactory), address(premium));

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
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), digest));
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
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), digest));
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
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), cancelDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);
        signature = abi.encodePacked(cancelDeadline, ecdsaSig);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Order helpers — exact-specific (2 outputs)
    // ═══════════════════════════════════════════════════════════════

    function _createExactOrder(Vm.Wallet memory uw, uint256 orderSize)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        return _createExactOrderWithPremium(uw, orderSize, DEFAULT_MIN_PREMIUM_PER_SHARE);
    }

    function _createExactOrderWithPremium(Vm.Wallet memory uw, uint256 orderSize, uint256 minPremiumPerShare)
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        (order, od, intent) = _createRolloverOrder(uw, orderSize, false, false, address(settler));

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

        // Use a distinct premium token to satisfy INV-S15 (srcCstToken != premiumToken)
        // We reuse vaultUnderlying for srcCstToken and dstCstToken, but need a different premiumToken.
        // For test simplicity, deploy on-the-fly or use a second token.
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
            allowPartialFills: false,
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

    function _openForExact(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory uw, address repayTo)
        internal
    {
        bytes memory sig = _signOrder(order, uw, address(settler));
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, repayTo);
        settler.openFor(order, sig, originFillerData);
    }

    function _fillRollover(IOriginSettler.GaslessCrossChainOrder memory order, address filler, address destination)
        internal
    {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = _buildExactRolloverFillerData(destination);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    function _fillPremium(IOriginSettler.GaslessCrossChainOrder memory order, address filler, address debitFrom)
        internal
    {
        bytes32 orderId = LibSettlerHashing.computeOrderId(address(settler), order);
        bytes memory fillerData = _buildExactPremiumFillerData(debitFrom);
        vm.prank(filler);
        settler.fill(orderId, abi.encode(order), fillerData);
    }

    function _computeOrderId(IOriginSettler.GaslessCrossChainOrder memory order) internal view returns (bytes32) {
        return LibSettlerHashing.computeOrderId(address(settler), order);
    }

    function _computeOutputHash(IOriginSettler.Output memory output) internal pure returns (bytes32) {
        return LibSettlerHashing.computeOutputHash(output);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Snapshot stubs (not exercised in exact-fill unit tests)
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
