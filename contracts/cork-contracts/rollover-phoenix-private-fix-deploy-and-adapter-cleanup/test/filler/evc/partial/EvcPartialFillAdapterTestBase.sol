// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {BaseTestEvcFillerAdapter} from "test/filler/BaseTestEvcFillerAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH} from "contracts/libs/LibSettlerHashing.sol";

import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {TestMintModule, RevertModule} from "test/harness/TestMintModule.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {AttestationRequest, ModuleType} from "registry/DataTypes.sol";

/// @title EvcPartialFillAdapterTestBase
/// @notice Shared test infrastructure for the Partial-binding `EvcPartialFillAdapter` BTT suite.
///         Mirrors `PartialRolloverFillerTestBase` one-for-one but binds to the Partial settler's
///         EIP-712 domain and sets `allowPartialFills = true` on the canonical order (Partial
///         path requirement — `_validateOpen` rejects `false`).
abstract contract EvcPartialFillAdapterTestBase is BaseTestEvcFillerAdapter {
    TestMintModule internal testMintModule;
    RevertModule internal revertModule;
    DummyERC20 internal premToken;
    DummyERC20 internal dstCst;

    address internal caller;
    address internal destination;
    address internal thirdParty;

    function setUp() public virtual override {
        super.setUp();

        testMintModule = new TestMintModule();
        revertModule = new RevertModule();
        premToken = new DummyERC20("PremiumToken", "PTK", 18);
        dstCst = new DummyERC20("DstCST", "dCST", 18);

        _registerTestModule(address(testMintModule));
        _registerTestModule(address(revertModule));

        caller = makeAddr("caller");
        destination = makeAddr("destination");
        thirdParty = makeAddr("thirdParty");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Abstract implementations — signing helpers (Partial domain)
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(settler_).domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        return abi.encodePacked(r, s, v);
    }

    function _signOrderWithSmartWallet(IOriginSettler.GaslessCrossChainOrder memory, address, address)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    function _signCancel(bytes32 orderId, uint256 cancelDeadline, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 cancelDigest = keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, cancelDeadline));
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", PartialFillSettler(settler_).domainSeparator(), cancelDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, eip712Hash);
        return abi.encodePacked(cancelDeadline, abi.encodePacked(r, s, v));
    }

    function _snapshot(bytes32, address) internal pure override returns (SettlerSnapshot memory s) {
        return s;
    }

    function _assertSnapshotDelta(SettlerSnapshot memory, SettlerSnapshot memory, SettlerSnapshot memory)
        internal
        pure
        override
    {}

    // ═══════════════════════════════════════════════════════════════
    //  Module registration (shared with integration tests)
    // ═══════════════════════════════════════════════════════════════

    function _registerTestModule(address module) internal {
        registry.registerModule(defaultResolverUID, module, "", "");
        ModuleType[] memory mt = new ModuleType[](1);
        mt[0] = ModuleType.wrap(2);
        registry.attest(
            defaultSchemaUID, AttestationRequest({moduleAddress: module, expirationTime: 0, data: "", moduleTypes: mt})
        );
        factory.registerModule(module);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Order builders (Partial binding)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Build a canonical Partial rollover order. `allowPartialFills = true` (required by
    ///         `PartialFillSettler._validateOpen`).
    function _buildValidOrderWithSignedCellarIntent(Vm.Wallet memory uw, uint256 orderSize, address destination_)
        internal
        view
        returns (
            IOriginSettler.GaslessCrossChainOrder memory order,
            OrderData memory od,
            bytes memory signature,
            bytes memory originFillerData
        )
    {
        destination_;

        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(uw, orderSize, true, false, address(partialSettler));

        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), orderSize, uw.addr);

        Call[] memory rHooks = _mintHook(address(partialSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(partialSettler), order, od);
        intent = _buildIntent(digest, address(partialSettler), orderSize, true, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, uw, factory.cellarOf(uw.addr));
        order.orderData = abi.encode(od);

        signature = _signOrder(order, uw, address(partialSettler));
        originFillerData = _buildOriginFillerData(orderSize, caller);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Shared hook + output + intent helpers
    // ═══════════════════════════════════════════════════════════════

    function _mintHook(address settler_, address dstCstToken) internal view returns (Call[] memory hooks) {
        hooks = new Call[](1);
        hooks[0] = Call({
            target: address(testMintModule),
            value: 0,
            callData: abi.encodeCall(TestMintModule.execute, (dstCstToken, settler_)),
            allowFailure: false,
            isDelegateCall: true
        });
    }

    function _revertPremiumHooks() internal view returns (Call[] memory hooks) {
        hooks = new Call[](1);
        hooks[0] = Call({
            target: address(revertModule),
            value: 0,
            callData: abi.encodeCall(RevertModule.execute, ()),
            allowFailure: false,
            isDelegateCall: true
        });
    }

    function _twoOutputs(address dstCstToken, address premTkn, uint256 amt, address recipient)
        internal
        view
        returns (IOriginSettler.Output[] memory outputs)
    {
        outputs = new IOriginSettler.Output[](2);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(dstCstToken))),
            amount: amt,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
        outputs[1] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(premTkn))),
            amount: 0,
            recipient: bytes32(uint256(uint160(recipient))),
            chainId: block.chainid
        });
    }

    function _buildIntent(
        bytes32 digest,
        address settler_,
        uint256 orderSize,
        bool partialFills,
        bool underfill,
        Call[] memory rHooks,
        Call[] memory pHooks
    ) internal view returns (CellarIntent memory) {
        return CellarIntent({
            orderDigest: digest,
            expectedCaller: address(factory),
            settler: settler_,
            deadline: uint256(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            orderSize: orderSize,
            allowPartialFills: partialFills,
            allowUnderfill: underfill,
            rolloverHooks: rHooks,
            premiumHooks: pHooks
        });
    }

    // ═══════════════════════════════════════════════════════════════
    //  Empty-affix batch helper + stack-friendly wrapper
    // ═══════════════════════════════════════════════════════════════

    function _noItems() internal pure returns (IEVC.BatchItem[] memory items) {
        items = new IEVC.BatchItem[](0);
    }

    /// @dev Stack-friendly wrapper over `_executeViaEvcBatch`. Manually assembles the single
    ///      `IEVC.BatchItem` the adapter path needs, then dispatches directly via
    ///      `evc.batch` to avoid inlining the 10-positional-param helper in every leaf. Needed
    ///      because `forge`'s via-ir pipeline blows the stack on the longer Partial leaves when
    ///      the 10-arg helper is inlined together with local locals.
    function _executeOneItem(
        EvcPartialFillAdapter adapter,
        address subaccount_,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination_
    ) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(adapter),
            onBehalfOfAccount: subaccount_,
            value: 0,
            data: abi.encodeWithSelector(
                EvcPartialFillAdapter.execute.selector,
                orderData,
                signature,
                originFillerData,
                srcCstAmount,
                debitFrom,
                destination_
            )
        });
        vm.prank(subaccount_);
        evc.batch(items);
    }
}
