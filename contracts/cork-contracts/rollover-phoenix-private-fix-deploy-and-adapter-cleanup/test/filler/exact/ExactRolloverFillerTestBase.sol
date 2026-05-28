// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {BaseTestFiller} from "test/filler/BaseTestFiller.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CANCEL_TYPE_HASH} from "contracts/libs/LibSettlerHashing.sol";

import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {TestMintModule, RevertModule} from "test/harness/TestMintModule.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";
import {AttestationRequest, ModuleType} from "registry/DataTypes.sol";

/// @title ExactRolloverFillerTestBase
/// @notice Shared test infrastructure for the Exact-binding `ExactRolloverFiller` BTT suite. Extends
///         `BaseTestFiller` and layers in:
///           - `_signOrder` / `_signOrderWithSmartWallet` / `_signCancel` bound to the Exact
///             settler's EIP-712 domain,
///           - a `TestMintModule` + `RevertModule` so rollover-leg hooks can mint dstCST without a
///             live Phoenix PoolManager,
///           - `_buildValidOrderWithSignedCellarIntent` which produces an Exact order with two
///             outputs (rollover + premium) that is fully wired for real cellar execution,
///           - `_preconditions` — one-shot wrapper around `_prepareFillerState` that additionally
///             authorises the filler contract for ERC-6909 debit (required on the premium leg).
/// @dev The abstract `_snapshot` / `_assertSnapshotDelta` hooks from `BaseTestSettler` are stubbed
///      as no-ops since the filler suite asserts post-state via `_fillerSnapshot`, event logs,
///      and direct balance checks rather than the settler snapshot struct.
abstract contract ExactRolloverFillerTestBase is BaseTestFiller {
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
    //  Abstract implementations — signing helpers (Exact domain)
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler_)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 digest = LibSettlerHashing.computeOpenForDigest(order);
        bytes32 eip712Hash =
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), digest));
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
            keccak256(abi.encodePacked("\x19\x01", ExactFillSettler(settler_).domainSeparator(), cancelDigest));
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
    //  Order builders
    // ═══════════════════════════════════════════════════════════════

    /// @notice Build a canonical Exact rollover order with two outputs (rollover + premium), a
    ///         dstCST-minting `rolloverHooks` entry pointing at `TestMintModule`, the UW's cellar
    ///         signature over the reconstructed intent, and a maker signature over the gasless
    ///         envelope. All intent and digest fields are consistent — the settler will accept
    ///         the order on `openFor` and both legs will pass on `fill`.
    /// @param uw The underwriter wallet (signer for both `openFor` and `cellarSignature`).
    /// @param orderSize Rollover order size.
    /// @param destination_ dstCST recipient for the rollover leg filler data.
    /// @return order The ERC-7683 envelope, with `orderData` already ABI-encoded.
    /// @return od The final `OrderData`.
    /// @return signature EOA-signed `openFor` maker signature.
    /// @return originFillerData `abi.encode(OriginFillerData)` with `outputAmount = orderSize` and
    ///         `repaymentTo = caller`.
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
        // Suppress unused-parameter warning — retained for signature parity with the Partial base.
        destination_;

        CellarIntent memory intent;
        (order, od, intent) = _createRolloverOrder(uw, orderSize, false, false, address(exactSettler));

        // Extend to two outputs (rollover + premium) using distinct tokens.
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), orderSize, uw.addr);

        // Rollover-leg hooks: mint dstCST to the settler on fill.
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        // Rebuild intent with the finalised fields, sign it as the UW's cellar, and re-encode.
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        intent = _buildIntent(digest, address(exactSettler), orderSize, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = _signCellarIntent(intent, uw, factory.cellarOf(uw.addr));
        order.orderData = abi.encode(od);

        signature = _signOrder(order, uw, address(exactSettler));
        originFillerData = _buildOriginFillerData(orderSize, caller);
    }

    /// @notice Prepare a caller's preconditions for a filler `execute` call against the Exact
    ///         binding. Mirrors the runtime checklist: premium deposited for `actor`, settler
    ///         authorised as ERC-6909 operator, filler authorised as ERC-6909 premiumFiller
    ///         (required by `ERC6909Premium.settle`'s dual-auth), and srcCST approved to the
    ///         filler.
    /// @param actor Who owns the srcCST + premium deposit (also the premium `debitFrom`).
    /// @param filler The filler contract being exercised.
    /// @param srcCstToken srcCST token address (from the order's OrderData).
    /// @param srcCstAmount srcCST approval + balance to set up.
    /// @param premiumToken Premium token address (from the order's OrderData).
    /// @param premiumAmount Premium balance to pre-deposit at `actor`.
    function _preconditions(
        address actor,
        ExactRolloverFiller filler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareFillerState(actor, filler, srcCstToken, srcCstAmount, premiumToken, premiumAmount);
        // The settler calls `ERC6909Premium.settle` which requires BOTH the settler AND
        // `premiumFiller == msg.sender-to-settler == filler contract` to be authorised by
        // `debitFrom`. Authorise the filler contract here.
        vm.prank(actor);
        premium.setOperator(address(filler), true);
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
}
