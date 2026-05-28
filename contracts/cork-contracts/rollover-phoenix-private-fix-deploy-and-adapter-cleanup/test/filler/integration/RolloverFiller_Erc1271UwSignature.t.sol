// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExactRolloverFillerTestBase} from "test/filler/exact/ExactRolloverFillerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus, InvalidSignature} from "contracts/interfaces/RolloverTypes.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {CorkCellar} from "cellar/CorkCellar.sol";
import {MockERC1271Signer} from "test/mocks/MockERC1271Signer.sol";

/// @title RolloverFiller_Erc1271UwSignature
/// @notice Proves the `RolloverFiller.execute` path forwards a contract-wallet (ERC-1271) UW
///         signature through `ExactFillSettler.openFor` unchanged — the settler's
///         `SignatureChecker.isValidSignatureNow` consults the UW contract's `isValidSignature`
///         hook and accepts the bytes when the hook returns the ERC-1271 magic value.
/// @dev The UW is a `MockERC1271Signer` (used unchanged from `test/mocks/`). The UW's cellar is
///      etched at the factory-predicted address so every protocol integrator contract (cellar,
///      settler, premium) reads a coherent UW state.
contract RolloverFiller_Erc1271UwSignature is ExactRolloverFillerTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    MockERC1271Signer internal uwSigner;
    address internal uwCellarAddr;
    CorkCellar internal uwCellar;

    function setUp() public override {
        super.setUp();

        uwSigner = new MockERC1271Signer();

        // Etch the UW's cellar clone at the factory-predicted address so the settler's
        // `cellarOf[UW]` lookup succeeds during openFor and subsequent fills.
        uwCellarAddr = factory.cellarOf(address(uwSigner));
        _etchCloneWithImmutableArgs(uwCellarAddr, factory.cellarImplementation(), address(uwSigner));
        uwCellar = CorkCellar(payable(uwCellarAddr));
        address[] memory attesters = new address[](1);
        attesters[0] = address(this);
        uwCellar.initialize(1, attesters);
    }

    /// @notice Happy path: UW is a contract wallet; ERC-1271 verifies both openFor and intent sigs.
    function test_erc1271UwSignature_happyPath_settlesOrder() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _buildErc1271Order();
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        // Authorize signature bytes: both the openFor EIP-712 hash AND the cellar intent digest
        // must return magic from the mock. The mock stores ONE authorized digest — we authorize
        // each right before the consuming call.
        bytes memory anySig = hex"deadbeef";

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Authorize the cellar intent digest (checked by cellar on rollover + premium hooks).
        bytes32 intentDigest =
            _eip712Digest(_cellarDomainSeparator(uwCellarAddr), _cellarIntentStructHash(_rebuildIntent(order, od)));
        uwSigner.authorize(intentDigest);

        // Pre-open the order to consume the openFor digest (authorize it, then call openFor).
        bytes32 openForDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                ExactFillSettler(address(exactSettler)).domainSeparator(),
                LibSettlerHashing.computeOpenForDigest(order)
            )
        );
        uwSigner.authorize(openForDigest);
        exactSettler.openFor(order, anySig, ofd);

        // Re-authorize the intent digest for the fill-time cellar verification.
        uwSigner.authorize(intentDigest);

        _executeRollover(rolloverFillerExact, abi.encode(order), anySig, ofd, ORDER_SIZE, caller, destination, caller);

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "ERC-1271 UW settled");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST at destination");
    }

    /// @notice Negative: mock returns non-magic for the openFor digest; `execute` reverts on signature.
    function test_erc1271UwSignature_invalidSignature_reverts() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _buildErc1271Order();
        bytes memory ofd = _buildOriginFillerData(ORDER_SIZE, caller);

        _preconditions(caller, rolloverFillerExact, od.srcCstToken, ORDER_SIZE, od.premiumToken, PREMIUM_DEPOSIT);

        // Authorize an unrelated digest so `isValidSignature(openForHash, ...)` returns the
        // non-magic `0xffffffff` value — settler reverts with InvalidSignature.
        uwSigner.authorize(keccak256("not-the-digest"));

        bytes memory anySig = hex"deadbeef";
        vm.expectRevert(InvalidSignature.selector);
        _executeRollover(rolloverFillerExact, abi.encode(order), anySig, ofd, ORDER_SIZE, caller, destination, caller);
    }

    // ─── internal helpers ───────────────────────────────────────────────────────────────────

    function _buildErc1271Order() internal returns (IOriginSettler.GaslessCrossChainOrder memory, OrderData memory) {
        IOriginSettler.GaslessCrossChainOrder memory order = IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(exactSettler),
            user: address(uwSigner),
            nonce: uint256(keccak256(abi.encodePacked(address(uwSigner), block.timestamp))),
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + DEFAULT_OPEN_DEADLINE_OFFSET),
            fillDeadline: uint32(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            orderDataType: 0x00,
            orderData: ""
        });
        // Populate orderDataType to the expected constant via re-encode through base helper path.
        // We skip that wiring here — the settler validates it only inside openFor, and the mock
        // auth digest authorises whatever payload we pass. For a settler-aligned build, rebuild
        // via `_createRolloverOrder` against a scratch EOA then rewrite `order.user`.
        (IOriginSettler.GaslessCrossChainOrder memory scratch, OrderData memory od,) =
            _createRolloverOrder(user, ORDER_SIZE, false, false, address(exactSettler));
        order.orderDataType = scratch.orderDataType;

        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premToken);
        od.outputs = _twoOutputs(address(dstCst), address(premToken), ORDER_SIZE, address(uwSigner));
        Call[] memory rHooks = _mintHook(address(exactSettler), address(dstCst));
        Call[] memory pHooks = new Call[](0);
        od.rolloverHooks = rHooks;
        od.premiumHooks = pHooks;

        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        CellarIntent memory intent =
            _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, rHooks, pHooks);
        od.cellarIntentHash = keccak256(abi.encode(intent));
        od.cellarSignature = hex"beef"; // ERC-1271 sig bytes — content irrelevant, magic auth-gated.
        order.orderData = abi.encode(od);

        return (order, od);
    }

    function _rebuildIntent(IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
        internal
        view
        returns (CellarIntent memory)
    {
        bytes32 digest = LibSettlerHashing.computeOrderDigest(address(exactSettler), order, od);
        return _buildIntent(digest, address(exactSettler), ORDER_SIZE, false, false, od.rolloverHooks, od.premiumHooks);
    }
}
