// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseTestCorkCellar} from "test/harness/BaseTestCorkCellar.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {
    OrderData,
    OriginFillerData,
    PartialFillerData,
    PremiumFillerData,
    RolloverFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {CORK_ROLLOVER_ORDER_TYPE, LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";

import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {IPoolManager, Market, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {IPoolShare} from "phoenix/interfaces/IPoolShare.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @title BaseTestSettler
/// @notice Test harness for Cork rollover settler tests. Extends cellar's `BaseTestCorkCellar`
///         (via our `test/harness/` fork) to bring in a real registry, real `CorkCellarFactory`,
///         real `CorkCellar` user / smart-wallet clones, and all six cellar modules — then adds
///         `ERC6909Premium`, `ExactFillSettler`, and `PartialFillSettler` deployments plus
///         settler-domain signing helpers, order builders, filler-data builders, and snapshot
///         helpers.
/// @dev Abstract so forge won't try to run `BaseTestSettler` directly — each settler suite
///      subclasses and implements `_signOrder`, `_signOrderWithSmartWallet`, `_signCancel`,
///      `_depositPremium`, `_snapshot`, `_assertSnapshotDelta` per the concrete settler's
///      semantics. `_createRolloverOrder` and the three `_build*FillerData` helpers are
///      concrete here because their shape is settler-agnostic.
abstract contract BaseTestSettler is BaseTestCorkCellar {
    // ─── Settler stack ─────────────────────────────────────────────────────────────────────
    ERC6909Premium internal premium;
    ExactFillSettler internal exactSettler;
    PartialFillSettler internal partialSettler;

    // ─── Defaults — concrete suites override to tweak (via `virtual` getters if needed) ──
    uint256 internal constant DEFAULT_ORDER_SIZE = 1000e18;
    uint256 internal constant DEFAULT_REPAYMENT_AMOUNT = 100e18;
    uint256 internal constant DEFAULT_MIN_PREMIUM_PER_SHARE = 0;
    uint32 internal constant DEFAULT_OPEN_DEADLINE_OFFSET = 1 hours;
    uint32 internal constant DEFAULT_FILL_DEADLINE_OFFSET = 2 hours;

    /// @notice Sentinel address used as the mocked pool-manager target for the AS-20 gate's
    ///         `IPoolShare(srcCstToken).poolManager().market(srcPoolId).collateralAsset` chain.
    ///         Deliberately distinct from any deployed contract so `vm.mockCall` on this address
    ///         is the only source of responses.
    address internal constant MOCK_POOL_MANAGER = address(uint160(uint256(keccak256("BaseTestSettler:poolManager"))));

    /// @notice Default collateral asset for the AS-20 gate mock chain. 18-decimal so the gate's
    ///         early-return makes it a no-op for tests that don't exercise AS-20 directly.
    DummyERC20 internal defaultCollateralAsset18;

    function setUp() public virtual override {
        super.setUp();
        premium = new ERC6909Premium();
        exactSettler = new ExactFillSettler(address(factory), address(premium));
        partialSettler = new PartialFillSettler(address(factory), address(premium));

        // Set up a default 18-decimal collateral so the AS-20 decimal-truncation gate is a no-op
        // on every test that uses `vaultUnderlying` as `srcCstToken`. Tests that need a
        // non-default collateral (e.g. 6-decimal USDC) call `_mockCollateralDecimals` directly.
        defaultCollateralAsset18 = new DummyERC20("CollateralAsset18", "COL18", 18);
        _mockCollateralAssetFor(address(vaultUnderlying), address(defaultCollateralAsset18));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  AS-20 decimal-truncation gate — pool-manager mock chain
    // ═══════════════════════════════════════════════════════════════════════════════════════
    //
    // The gate's decimal source is `IPoolManager.market(srcPoolId).collateralAsset` accessed via
    // `IPoolShare(srcCstToken).poolManager()`. Tests mock both hops here via `vm.mockCall`:
    //   1. `srcCstToken.poolManager() -> MOCK_POOL_MANAGER`
    //   2. `MOCK_POOL_MANAGER.market(srcPoolId) -> Market{collateralAsset: <caller-supplied>}`
    // The mocked `Market` struct is zeroed except for `collateralAsset` — the gate only reads
    // that field, so the other fields are irrelevant.

    /// @notice Mock the AS-20 gate's pool-manager chain so `srcCstToken`'s pool manager resolves
    ///         `market(srcPoolId).collateralAsset == collateralAsset_`. The collateral's
    ///         `decimals()` is then the value the gate compares against 18.
    /// @dev Uses the shared `MOCK_POOL_MANAGER` sentinel so multiple cST tokens in a single test
    ///      share the same mocked pool manager. Test helpers that build orders with non-default
    ///      `srcPoolId` values call `_mockMarketForPool` to register the pool-specific answer.
    /// @param srcCstToken_ Address used as `od.srcCstToken`.
    /// @param collateralAsset_ Address returned for `market(srcPoolId).collateralAsset` — typically
    ///        a `DummyERC20` whose `decimals()` drives the gate's modulo check.
    function _mockCollateralAssetFor(address srcCstToken_, address collateralAsset_) internal {
        vm.mockCall(
            srcCstToken_, abi.encodeWithSelector(IPoolShare.poolManager.selector), abi.encode(MOCK_POOL_MANAGER)
        );
        // Default srcPoolId used by `_createRolloverOrderWithGates` is `bytes32(uint256(0x1111))`.
        // Register that pool's market entry here; tests that use a different pool id register
        // their own via `_mockMarketForPool`.
        _mockMarketForPool(MarketId.wrap(bytes32(uint256(0x1111))), collateralAsset_);
    }

    /// @notice Register a `Market` entry on the sentinel pool manager for a given `poolId`.
    /// @param poolId The pool identifier looked up via `market(poolId)` in the gate.
    /// @param collateralAsset_ The address returned as `market(poolId).collateralAsset`.
    function _mockMarketForPool(MarketId poolId, address collateralAsset_) internal {
        Market memory m = Market({
            collateralAsset: collateralAsset_,
            referenceAsset: address(0),
            expiryTimestamp: 0,
            rateMin: 0,
            rateMax: 0,
            rateChangePerDayMax: 0,
            rateChangeCapacityMax: 0,
            rateOracle: address(0)
        });
        vm.mockCall(MOCK_POOL_MANAGER, abi.encodeWithSelector(IPoolManager.market.selector, poolId), abi.encode(m));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Signing helpers — per test-spec §2.4
    // ═══════════════════════════════════════════════════════════════════════════════════════
    //
    // Each signature is over the SETTLER's EIP-712 domain per RFC 003 §A.1:
    //   EIP712Domain(string name="CorkRolloverSettler",string version="1",uint256 chainId,address verifyingContract=settler)
    // The `GaslessCrossChainOrder` type hash and `CorkRolloverOrder_v1` discriminator are verified
    // in `LibSettlerHashing`. Concrete settler suites in PR 4b/4c/4d implement these bodies
    // against the finalized `BaseSettler._hashOrder` shape.

    /// @notice EOA signs `order` over the settler's EIP-712 domain.
    /// @param order The gasless cross-chain order to sign.
    /// @param wallet Foundry-created wallet (provides private key).
    /// @param settler Settler contract whose `domainSeparator()` defines the EIP-712 domain.
    /// @return signature ABI-encoded ECDSA signature suitable for `openFor` / `fill`.
    function _signOrder(IOriginSettler.GaslessCrossChainOrder memory order, Vm.Wallet memory wallet, address settler)
        internal
        view
        virtual
        returns (bytes memory signature);

    /// @notice Smart-wallet (ERC-1271) signs `order` over the settler's EIP-712 domain.
    /// @param order The gasless cross-chain order to sign.
    /// @param smartWallet_ Smart-wallet account whose owner is the signer.
    /// @param settler Settler contract whose `domainSeparator()` defines the EIP-712 domain.
    /// @return signature The bytes stored on `smartWallet_` so `isValidSignature` returns MAGIC.
    function _signOrderWithSmartWallet(
        IOriginSettler.GaslessCrossChainOrder memory order,
        address smartWallet_,
        address settler
    ) internal virtual returns (bytes memory signature);

    /// @notice Maker-side cancel signature over `Cancel(bytes32 orderId,uint256 cancelDeadline)`
    ///         against the settler's EIP-712 domain. See test-spec §5.7 note: `cancelDeadline` is
    ///         distinct from `fillDeadline`.
    /// @param orderId Canonical order identifier.
    /// @param cancelDeadline Unix timestamp after which the cancel authorization is invalid.
    /// @param wallet Foundry-created wallet (provides private key).
    /// @param settler Settler contract whose `domainSeparator()` defines the EIP-712 domain.
    /// @return signature ABI-encoded ECDSA signature.
    function _signCancel(bytes32 orderId, uint256 cancelDeadline, Vm.Wallet memory wallet, address settler)
        internal
        view
        virtual
        returns (bytes memory signature);

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Order-building helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Assemble a canonical Cork rollover order bundle: `GaslessCrossChainOrder` (the
    ///         ERC-7683 envelope) + `OrderData` (the Cork body) + `CellarIntent` (the cellar
    ///         authorization). All three share a consistent `cellarIntentHash` /
    ///         `orderDigest` linkage per extension §5.4 / INV-P18.
    /// @dev Token fields default to the harness's `vaultUnderlying` (src/dst CST, premium,
    ///      repayment all collapse to one token for harness simplicity); concrete tests that
    ///      need distinct tokens override individual fields on the returned `OrderData` AFTER
    ///      calling this helper and re-compute the hashes. Hooks are minimal: one no-op
    ///      `rolloverHooks` call targeting `rolloverModule` (matches cellar's expected shape)
    ///      and zero `premiumHooks`.
    /// @param uw The underwriter / maker wallet whose address goes in `order.user`.
    /// @param orderSize Rollover order size (source cST to roll).
    /// @param allowPartialFills Whether the order permits partial fills.
    /// @param allowUnderfill Whether the order permits completion below `orderSize` (per the
    ///        partial-fill extension semantics).
    /// @param settler The settler contract the order is bound to (`order.originSettler`).
    /// @return order The ERC-7683 envelope.
    /// @return od The decoded Cork body.
    /// @return intent The cellar intent whose hash matches `od.cellarIntentHash`.
    function _createRolloverOrder(
        Vm.Wallet memory uw,
        uint256 orderSize,
        bool allowPartialFills,
        bool allowUnderfill,
        address settler
    )
        internal
        view
        virtual
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        return _createRolloverOrderWithGates(uw, orderSize, allowPartialFills, allowUnderfill, settler, 0, address(0));
    }

    /// @notice Variant of `_createRolloverOrder` that exposes the AS-19 / AS-21 ingress-gate
    ///         fields to callers. Legacy tests continue to call the 5-arg overload which
    ///         delegates here with the gate fields zeroed (unconstrained), preserving prior
    ///         behaviour exactly.
    /// @param minFillSize Per-fill dust floor — `0` means unconstrained.
    /// @param exclusiveFiller Single authorized filler — `address(0)` means open fill.
    function _createRolloverOrderWithGates(
        Vm.Wallet memory uw,
        uint256 orderSize,
        bool allowPartialFills,
        bool allowUnderfill,
        address settler,
        uint256 minFillSize,
        address exclusiveFiller
    )
        internal
        view
        virtual
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, CellarIntent memory intent)
    {
        // Outputs: single rollover-leg output for simplicity. Concrete suites that exercise the
        // two-leg shape (rollover + premium) override by extending `od.outputs` post-return.
        IOriginSettler.Output[] memory outputs = new IOriginSettler.Output[](1);
        outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(vaultUnderlying)))),
            amount: orderSize,
            recipient: bytes32(uint256(uint160(uw.addr))),
            chainId: block.chainid
        });

        // Minimal 1-call rolloverHooks — the call target is `rolloverModule` which is what
        // cellar's `CorkCellar.fill` expects. Payload is empty here; concrete tests that drive
        // RolloverModule.execute() through cellar supply the real ABI-encoded arguments.
        Call[] memory rolloverHooks = new Call[](1);
        rolloverHooks[0] =
            Call({target: address(rolloverModule), value: 0, callData: "", allowFailure: false, isDelegateCall: false});
        Call[] memory premiumHooks = new Call[](0);

        od = OrderData({
            receiver: uw.addr,
            srcPoolId: MarketId.wrap(bytes32(uint256(0x1111))),
            dstPoolId: MarketId.wrap(bytes32(uint256(0x2222))),
            srcCstToken: address(vaultUnderlying),
            dstCstToken: address(vaultUnderlying),
            premiumToken: address(vaultUnderlying),
            repaymentToken: address(vaultUnderlying),
            repaymentAmount: DEFAULT_REPAYMENT_AMOUNT,
            orderSize: orderSize,
            minFillSize: minFillSize,
            allowPartialFills: allowPartialFills,
            allowUnderfill: allowUnderfill,
            exclusiveFiller: exclusiveFiller,
            minPremiumPerShare: DEFAULT_MIN_PREMIUM_PER_SHARE,
            cellarIntentHash: bytes32(0),
            outputs: outputs,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks,
            cellarSignature: ""
        });

        order = IOriginSettler.GaslessCrossChainOrder({
            originSettler: settler,
            user: uw.addr,
            nonce: uint256(keccak256(abi.encodePacked(uw.addr, block.timestamp))),
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + DEFAULT_OPEN_DEADLINE_OFFSET),
            fillDeadline: uint32(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: ""
        });

        // Build the intent shape first, using a provisional `orderDigest == 0`. Computing the
        // real `orderDigest` requires `od` to be final except for `cellarIntentHash` (digest
        // depends on outputs / pool ids / etc. — all set) and `cellarSignature` (not part of
        // the digest). Extension §5.4 binds `cellarIntentHash = keccak256(abi.encode(intent))`
        // AFTER `intent.orderDigest` is set — so we:
        //   1. compute digest over `od` (which still carries `cellarIntentHash = 0`),
        //   2. build intent with that digest,
        //   3. set `od.cellarIntentHash = keccak256(abi.encode(intent))`.
        // The digest does NOT include `cellarIntentHash` (see LibSettlerHashing) so step 1's
        // output is stable across step 3.
        bytes32 digest = LibSettlerHashing.computeOrderDigest(settler, order, od);
        intent = CellarIntent({
            orderDigest: digest,
            expectedCaller: address(factory),
            settler: settler,
            deadline: uint256(order.fillDeadline),
            orderSize: orderSize,
            allowPartialFills: allowPartialFills,
            allowUnderfill: allowUnderfill,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks
        });
        od.cellarIntentHash = keccak256(abi.encode(intent));

        // Re-encode `orderData` now that `od` is final.
        order.orderData = abi.encode(od);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Filler-data builders — encode per RFC 003 §A.10 / extension §5.4
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Exact rollover-leg fillerData: 1 raw byte for outputIndex + abi.encode(struct).
    function _buildExactRolloverFillerData(address destination) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(0)), abi.encode(RolloverFillerData({destination: destination})));
    }

    /// @notice Exact premium-leg fillerData: 1 raw byte for outputIndex + abi.encode(struct).
    function _buildExactPremiumFillerData(address debitFrom) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(1)), abi.encode(PremiumFillerData({debitFrom: debitFrom})));
    }

    /// @notice Partial-path fillerData: `abi.encode(outputIndex, PartialFillerData)` per
    ///         extension §5.4.
    /// @param outputIndex Leg discriminator — 0 for rollover, 1 for premium.
    /// @param destination Where to route dstCST at settlement.
    /// @param debitFrom Account whose ERC-6909 premium balance is debited.
    /// @param targetFiller Filler identity used for per-filler state keying.
    /// @param intent Cellar intent; MUST match `od.cellarIntentHash`.
    /// @param cellarSig UW's signature over `intent`.
    function _buildPartialFillerData(
        uint8 outputIndex,
        address destination,
        address debitFrom,
        address targetFiller,
        CellarIntent memory intent,
        bytes memory cellarSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            outputIndex,
            PartialFillerData({
                destination: destination,
                debitFrom: debitFrom,
                targetFiller: targetFiller,
                intent: intent,
                cellarSig: cellarSig
            })
        );
    }

    /// @notice `originFillerData` passed at `openFor` time per RFC 003 §A.11.
    function _buildOriginFillerData(uint256 outputAmount, address repaymentTo) internal pure returns (bytes memory) {
        return abi.encode(OriginFillerData({outputAmount: outputAmount, repaymentTo: repaymentTo}));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Balance / state helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Deposit `amount` of `token` into the filler's ERC-6909 premium balance.
    /// @dev Mints the token to the filler, approves the premium contract, then deposits. Concrete
    ///      suites that need bespoke transfer semantics (e.g. the reentrancy MockERC20) override.
    function _depositPremium(address filler, address token, uint256 amount) internal virtual {
        // DummyERC20.deposit requires ether; we mint via its public `mint(to, amount)` helper
        // (inherited from `ERC20Mock`).
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", filler, amount));
        require(ok, "BaseTestSettler: mint failed");
        vm.startPrank(filler);
        IERC20(token).approve(address(premium), amount);
        premium.deposit(token, filler, amount);
        vm.stopPrank();
    }

    /// @notice `vm.warp` convenience wrapper — sets `block.timestamp` to `timestamp`.
    function _advanceTo(uint256 timestamp) internal {
        vm.warp(timestamp);
    }

    // ─── Snapshots ────────────────────────────────────────────────────────────────────────
    //
    // The snapshot struct's concrete fields evolve across PR 4b/4c/4d as settler state surfaces.
    // Keep the struct here minimal; concrete suites `_snapshot` bodies populate the fields they
    // care about and zero-out the rest. `_assertSnapshotDelta` is left abstract so each suite
    // can implement the exact invariants relevant to its leaves.

    /// @notice Aggregate settler-side state for a given `(orderDigest, filler)` pair.
    /// @param erc6909 Filler's ERC-6909 premium balance (for `od.premiumToken`).
    /// @param settlerDstCst dstCST balance held by the settler (escrow).
    /// @param cellarDstCst dstCST balance held by the cellar (post-rollover).
    /// @param filledSoFar Cumulative fill amount recorded by the settler for this order.
    /// @param fillerFilled Amount filled by this specific filler (partial-fill only).
    struct SettlerSnapshot {
        uint256 erc6909;
        uint256 settlerDstCst;
        uint256 cellarDstCst;
        uint256 filledSoFar;
        uint256 fillerFilled;
    }

    /// @notice Capture `(orderDigest, filler)`-keyed state.
    function _snapshot(bytes32 orderDigest, address filler) internal view virtual returns (SettlerSnapshot memory);

    /// @notice Assert `after_ - before_ == expected` field-by-field. Concrete suites implement
    ///         the exact equality semantics (some fields are deltas, others are absolute).
    function _assertSnapshotDelta(
        SettlerSnapshot memory before_,
        SettlerSnapshot memory after_,
        SettlerSnapshot memory expected
    ) internal pure virtual;
}
