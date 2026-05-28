// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {
    LibRolloverOrder,
    OrderData,
    RolloverFillerData,
    PremiumFillerData,
    PartialFillerData,
    OriginFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing, CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";
import {MarketId} from "phoenix/interfaces/IPoolManager.sol";

/// @dev Thin wrapper exposing the library's calldata decoders so test bytes blobs reach them
///      through a proper calldata slot rather than `bytes memory`.
contract DecoderHarness {
    function decodeOrderData(bytes calldata data) external pure returns (OrderData memory) {
        return LibRolloverOrder.decodeOrderData(data);
    }

    function decodeRolloverFillerData(bytes calldata data) external pure returns (RolloverFillerData memory) {
        return LibRolloverOrder.decodeRolloverFillerData(data);
    }

    function decodePremiumFillerData(bytes calldata data) external pure returns (PremiumFillerData memory) {
        return LibRolloverOrder.decodePremiumFillerData(data);
    }

    function decodePartialFillerData(bytes calldata data) external pure returns (PartialFillerData memory) {
        return LibRolloverOrder.decodePartialFillerData(data);
    }

    function decodeOriginFillerData(bytes calldata data) external pure returns (OriginFillerData memory) {
        return LibRolloverOrder.decodeOriginFillerData(data);
    }

    function decodePrefixed(bytes calldata data) external pure returns (uint8 idx, bytes memory rest) {
        idx = abi.decode(data[0:32], (uint8));
        // Re-decode the struct shape via the full payload — used to confirm the prefix round-trips.
        rest = data;
    }
}

contract LibRolloverOrderTest is Test {
    DecoderHarness internal harness;

    function setUp() public {
        harness = new DecoderHarness();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 1-2. OrderData round-trips
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_OrderData_roundTrip() public view {
        OrderData memory od = _fixtureOrderData();

        bytes memory encoded = LibRolloverOrder.encodeOrderData(od);
        OrderData memory decoded = harness.decodeOrderData(encoded);

        _assertOrderDataEq(decoded, od);
    }

    function testFuzz_encodeDecode_OrderData_roundTrip(
        address receiver,
        bytes32 srcPool,
        bytes32 dstPool,
        uint256 orderSize,
        bool allowPartialFills,
        bool allowUnderfill,
        uint256 minPremiumPerShare,
        uint8 numOutputs,
        uint8 numRolloverHooks,
        uint8 numPremiumHooks
    ) public view {
        OrderData memory od;
        od.receiver = receiver;
        od.srcPoolId = MarketId.wrap(srcPool);
        od.dstPoolId = MarketId.wrap(dstPool);
        od.srcCstToken = address(0x5001);
        od.dstCstToken = address(0x5002);
        od.premiumToken = address(0x5003);
        od.repaymentToken = address(0x5004);
        od.repaymentAmount = 1e18;
        od.orderSize = orderSize;
        od.allowPartialFills = allowPartialFills;
        od.allowUnderfill = allowUnderfill;
        od.minPremiumPerShare = minPremiumPerShare;
        od.cellarIntentHash = keccak256(abi.encode(receiver, orderSize));

        uint256 nOut = bound(uint256(numOutputs), 0, 4);
        od.outputs = new IOriginSettler.Output[](nOut);
        for (uint256 i = 0; i < nOut; i++) {
            od.outputs[i] = IOriginSettler.Output({
                token: bytes32(uint256(uint160(address(0x6000 + uint160(i))))),
                amount: (i + 1) * 1e18,
                recipient: bytes32(uint256(uint160(receiver))),
                chainId: 1 + i
            });
        }

        od.rolloverHooks = _mkHooks(bound(uint256(numRolloverHooks), 0, 3));
        od.premiumHooks = _mkHooks(bound(uint256(numPremiumHooks), 0, 3));
        od.cellarSignature = abi.encodePacked(keccak256("sig"));

        bytes memory encoded = LibRolloverOrder.encodeOrderData(od);
        OrderData memory decoded = harness.decodeOrderData(encoded);

        _assertOrderDataEq(decoded, od);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 2a. OrderData round-trip — AS-19 / AS-21 ingress-gate fields (minFillSize, exclusiveFiller)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_OrderData_carriesMinFillSizeAndExclusiveFiller() public view {
        OrderData memory od = _fixtureOrderData();
        od.minFillSize = 42e18;
        od.exclusiveFiller = address(0xFEE71E);

        bytes memory encoded = LibRolloverOrder.encodeOrderData(od);
        OrderData memory decoded = harness.decodeOrderData(encoded);

        assertEq(decoded.minFillSize, od.minFillSize, "minFillSize must round-trip");
        assertEq(decoded.exclusiveFiller, od.exclusiveFiller, "exclusiveFiller must round-trip");
        _assertOrderDataEq(decoded, od);
    }

    function testFuzz_encodeDecode_OrderData_gateFieldsRoundTrip(uint256 minFillSize, address exclusiveFiller)
        public
        view
    {
        OrderData memory od = _fixtureOrderData();
        od.minFillSize = minFillSize;
        od.exclusiveFiller = exclusiveFiller;

        bytes memory encoded = LibRolloverOrder.encodeOrderData(od);
        OrderData memory decoded = harness.decodeOrderData(encoded);

        assertEq(decoded.minFillSize, minFillSize, "minFillSize fuzz round-trip");
        assertEq(decoded.exclusiveFiller, exclusiveFiller, "exclusiveFiller fuzz round-trip");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 3. RolloverFillerData round-trip (uint8(0) prefix)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_RolloverFillerData_roundTrip() public pure {
        RolloverFillerData memory fd = RolloverFillerData({destination: address(0xABCD)});

        bytes memory encoded = LibRolloverOrder.encodeRolloverFillerData(fd);
        // Packed 1-byte prefix + abi.encoded struct — matches BaseSettler.fill's split.
        uint8 idx = uint8(encoded[0]);
        bytes memory tail = _sliceFromOne(encoded);
        RolloverFillerData memory decoded = abi.decode(tail, (RolloverFillerData));

        assertEq(idx, 0, "outputIndex prefix must be 0 for rollover leg");
        assertEq(decoded.destination, fd.destination, "destination mismatch");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 4. PremiumFillerData round-trip (uint8(1) prefix)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_PremiumFillerData_roundTrip() public pure {
        PremiumFillerData memory fd = PremiumFillerData({debitFrom: address(0xBEEF)});

        bytes memory encoded = LibRolloverOrder.encodePremiumFillerData(fd);
        uint8 idx = uint8(encoded[0]);
        bytes memory tail = _sliceFromOne(encoded);
        PremiumFillerData memory decoded = abi.decode(tail, (PremiumFillerData));

        assertEq(idx, 1, "outputIndex prefix must be 1 for premium leg");
        assertEq(decoded.debitFrom, fd.debitFrom, "debitFrom mismatch");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 5. PartialFillerData round-trip at outputIndex 0 and 1
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_PartialFillerData_roundTrip() public pure {
        PartialFillerData memory fd = PartialFillerData({
            destination: address(0xD001),
            debitFrom: address(0xD002),
            targetFiller: address(0xD003),
            intent: CellarIntent({
                orderDigest: keccak256("digest"),
                expectedCaller: address(0xFAC),
                settler: address(0x5E77),
                deadline: 1_700_000_000,
                orderSize: 1000e18,
                allowPartialFills: false,
                allowUnderfill: false,
                rolloverHooks: _mkHooks(1),
                premiumHooks: _mkHooks(2)
            }),
            cellarSig: abi.encodePacked(keccak256("sig"))
        });

        for (uint8 prefix = 0; prefix < 2; prefix++) {
            bytes memory encoded = LibRolloverOrder.encodePartialFillerData(prefix, fd);
            uint8 idx = uint8(encoded[0]);
            bytes memory tail = _sliceFromOne(encoded);
            PartialFillerData memory decoded = abi.decode(tail, (PartialFillerData));

            assertEq(idx, prefix, "prefix round-trip");
            assertEq(decoded.destination, fd.destination, "destination");
            assertEq(decoded.debitFrom, fd.debitFrom, "debitFrom");
            assertEq(decoded.targetFiller, fd.targetFiller, "targetFiller");
            assertEq(decoded.intent.orderDigest, fd.intent.orderDigest, "intent.orderDigest");
            assertEq(decoded.intent.expectedCaller, fd.intent.expectedCaller, "intent.expectedCaller");
            assertEq(decoded.intent.deadline, fd.intent.deadline, "intent.deadline");
            assertEq(decoded.intent.rolloverHooks.length, fd.intent.rolloverHooks.length, "rolloverHooks len");
            assertEq(decoded.intent.premiumHooks.length, fd.intent.premiumHooks.length, "premiumHooks len");
            assertEq(keccak256(decoded.cellarSig), keccak256(fd.cellarSig), "cellarSig");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 6. OriginFillerData round-trip
    // ─────────────────────────────────────────────────────────────────────────────

    function test_encodeDecode_OriginFillerData_roundTrip() public view {
        OriginFillerData memory ofd = OriginFillerData({outputAmount: 42e18, repaymentTo: address(0x9876)});

        bytes memory encoded = LibRolloverOrder.encodeOriginFillerData(ofd);
        OriginFillerData memory decoded = harness.decodeOriginFillerData(encoded);

        assertEq(decoded.outputAmount, ofd.outputAmount, "outputAmount");
        assertEq(decoded.repaymentTo, ofd.repaymentTo, "repaymentTo");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 7. Garbage input reverts
    // ─────────────────────────────────────────────────────────────────────────────

    function test_decodeOrderData_rejectsGarbage() public {
        bytes memory garbage = hex"deadbeef";
        // Bare expectRevert: abi.decode fails on malformed data with a
        // Solidity-level panic (empty revert data), selector not predictable.
        vm.expectRevert();
        harness.decodeOrderData(garbage);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 7a. Defensive — legacy (pre-PR-1) 17-field OrderData encoding must not decode
    // silently. The current struct has 19 fields (17 head + `minFillSize` +
    // `exclusiveFiller`); a pre-PR-1 encoding is SHORTER than the current shape, so
    // `abi.decode` must trap rather than deserialize garbage.
    // ─────────────────────────────────────────────────────────────────────────────

    function test_decodeOrderData_rejectsLegacyShape() public {
        // Reconstruct a pre-PR-1 `OrderData` encoding by omitting `minFillSize` and
        // `exclusiveFiller`. The encoding is produced by `abi.encode` over the 17 surviving
        // fields in their original order — this is the exact wire format that a deployed
        // settler running pre-PR-1 would have produced.
        IOriginSettler.Output[] memory emptyOutputs = new IOriginSettler.Output[](0);
        Call[] memory emptyHooks = new Call[](0);

        bytes memory legacyEncoded = abi.encode(
            address(0xC0FFEE), // receiver
            MarketId.wrap(bytes32(uint256(1))), // srcPoolId
            MarketId.wrap(bytes32(uint256(2))), // dstPoolId
            address(0x5001), // srcCstToken
            address(0x5002), // dstCstToken
            address(0x5003), // premiumToken
            address(0x5004), // repaymentToken
            uint256(1e18), // repaymentAmount
            uint256(100e18), // orderSize
            // [minFillSize intentionally OMITTED]
            true, // allowPartialFills
            false, // allowUnderfill
            // [exclusiveFiller intentionally OMITTED]
            uint256(1e15), // minPremiumPerShare
            bytes32(0), // cellarIntentHash
            emptyOutputs, // outputs
            emptyHooks, // rolloverHooks
            emptyHooks, // premiumHooks
            hex"" // cellarSignature
        );
        // Bare expectRevert: `abi.decode` traps when the payload is shorter than the target
        // struct; the exact panic selector is not part of this contract's API. The REQUIREMENT
        // is that decoding does not silently succeed with garbage in the two new fields.
        vm.expectRevert();
        harness.decodeOrderData(legacyEncoded);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 8. extractCellarIntentFromOrderData — consistency across fields
    // ─────────────────────────────────────────────────────────────────────────────

    function test_extractCellarIntentFromOrderData_buildsConsistentIntent() public {
        vm.chainId(1);

        OrderData memory od = _fixtureOrderData();
        od.rolloverHooks = _mkHooks(2);
        od.premiumHooks = _mkHooks(3);
        od.cellarSignature = abi.encodePacked(keccak256("uw-sig"));

        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder(od);
        address settler = address(0xBEEF);
        address factory = address(0xFAC);

        (CellarIntent memory intent, bytes memory sig) =
            LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);

        assertEq(intent.deadline, uint256(order.fillDeadline), "deadline must equal fillDeadline");
        assertEq(intent.expectedCaller, factory, "expectedCaller must equal factory");
        assertEq(intent.rolloverHooks.length, od.rolloverHooks.length, "rolloverHooks length");
        for (uint256 i = 0; i < intent.rolloverHooks.length; i++) {
            _assertCallEq(intent.rolloverHooks[i], od.rolloverHooks[i]);
        }
        assertEq(intent.premiumHooks.length, od.premiumHooks.length, "premiumHooks length");
        for (uint256 i = 0; i < intent.premiumHooks.length; i++) {
            _assertCallEq(intent.premiumHooks[i], od.premiumHooks[i]);
        }
        assertEq(
            intent.orderDigest, LibSettlerHashing.computeOrderDigest(settler, order, od), "orderDigest not consistent"
        );
        assertEq(keccak256(sig), keccak256(od.cellarSignature), "cellarSig forwarded verbatim");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 9. extractCellarIntentFromOrderData — hash matches cellarIntentHash when caller commits
    // ─────────────────────────────────────────────────────────────────────────────

    function test_extractCellarIntentFromOrderData_hashMatchesCellarIntentHash() public {
        vm.chainId(1);

        // Build an OrderData with placeholder cellarIntentHash; compute the real intent; populate
        // od.cellarIntentHash with its hash; re-extract and assert equality. This mirrors what a
        // well-formed UW flow does off-chain when producing the signed payload.
        OrderData memory od = _fixtureOrderData();
        od.rolloverHooks = _mkHooks(2);
        od.premiumHooks = _mkHooks(1);

        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder(od);
        address settler = address(0xBEEF);
        address factory = address(0xFAC);

        (CellarIntent memory intent,) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);
        bytes32 committed = keccak256(abi.encode(intent));

        od.cellarIntentHash = committed;

        // Re-extract after committing the hash — since cellarIntentHash does not feed the digest
        // (digest field list excludes it per §A.8 + extension §5.2), the orderDigest is
        // unchanged; therefore the intent hash is unchanged; therefore the equality holds.
        (CellarIntent memory intent2,) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);
        assertEq(keccak256(abi.encode(intent2)), od.cellarIntentHash, "intent hash must equal od.cellarIntentHash");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 10. Fuzz: extraction is deterministic per input
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_extractCellarIntentFromOrderData_stableUnderFieldShuffle(
        address settler,
        address factory,
        uint256 nonce,
        uint32 fillDeadline,
        uint256 orderSize,
        bool allowPartialFills
    ) public {
        vm.chainId(1);
        vm.assume(settler != address(0));
        vm.assume(factory != address(0));

        OrderData memory od = _fixtureOrderData();
        od.orderSize = orderSize;
        od.allowPartialFills = allowPartialFills;

        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder(od);
        order.nonce = nonce;
        order.fillDeadline = fillDeadline;

        (CellarIntent memory intentA,) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);
        (CellarIntent memory intentB,) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);

        assertEq(keccak256(abi.encode(intentA)), keccak256(abi.encode(intentB)), "extraction not deterministic");

        // Changing a field that feeds orderDigest must produce a distinct intent hash.
        order.nonce = nonce == type(uint256).max ? nonce - 1 : nonce + 1;
        (CellarIntent memory intentC,) = LibRolloverOrder.extractCellarIntentFromOrderData(od, order, settler, factory);
        assertNotEq(
            keccak256(abi.encode(intentA)),
            keccak256(abi.encode(intentC)),
            "distinct nonce must produce distinct intent"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fixtures / helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _fixtureOrderData() internal pure returns (OrderData memory od) {
        od.receiver = address(0xC0FFEE);
        od.srcPoolId = MarketId.wrap(bytes32(uint256(1)));
        od.dstPoolId = MarketId.wrap(bytes32(uint256(2)));
        od.srcCstToken = address(0x5001);
        od.dstCstToken = address(0x5002);
        od.premiumToken = address(0x5003);
        od.repaymentToken = address(0x5004);
        od.repaymentAmount = 1e18;
        od.orderSize = 100e18;
        od.allowPartialFills = true;
        od.allowUnderfill = false;
        od.minPremiumPerShare = 1e15;
        od.cellarIntentHash = bytes32(0);

        od.outputs = new IOriginSettler.Output[](1);
        od.outputs[0] = IOriginSettler.Output({
            token: bytes32(uint256(uint160(od.dstCstToken))),
            amount: 100e18,
            recipient: bytes32(uint256(uint160(address(0xDEAD)))),
            chainId: 1
        });

        od.rolloverHooks = new Call[](0);
        od.premiumHooks = new Call[](0);
        od.cellarSignature = hex"";
    }

    function _fixtureOrder(OrderData memory od) internal pure returns (IOriginSettler.GaslessCrossChainOrder memory) {
        return IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(0xBEEF),
            user: address(0xCAFE),
            nonce: 7,
            originChainId: 1,
            openDeadline: uint32(1_700_000_000),
            fillDeadline: uint32(1_700_000_600),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: LibRolloverOrder.encodeOrderData(od)
        });
    }

    function _mkHooks(uint256 n) internal pure returns (Call[] memory hooks) {
        hooks = new Call[](n);
        for (uint256 i = 0; i < n; i++) {
            hooks[i] = Call({
                target: address(uint160(0x7000 + i)),
                value: 0,
                callData: abi.encodePacked(bytes4(keccak256("call(uint256)")), i),
                allowFailure: false,
                isDelegateCall: false
            });
        }
    }

    function _assertCallEq(Call memory a, Call memory b) internal pure {
        assertEq(a.target, b.target, "call.target");
        assertEq(a.value, b.value, "call.value");
        assertEq(keccak256(a.callData), keccak256(b.callData), "call.callData");
        assertEq(a.allowFailure, b.allowFailure, "call.allowFailure");
        assertEq(a.isDelegateCall, b.isDelegateCall, "call.isDelegateCall");
    }

    function _assertOrderDataEq(OrderData memory a, OrderData memory b) internal pure {
        assertEq(a.receiver, b.receiver, "receiver");
        assertEq(MarketId.unwrap(a.srcPoolId), MarketId.unwrap(b.srcPoolId), "srcPoolId");
        assertEq(MarketId.unwrap(a.dstPoolId), MarketId.unwrap(b.dstPoolId), "dstPoolId");
        assertEq(a.srcCstToken, b.srcCstToken, "srcCstToken");
        assertEq(a.dstCstToken, b.dstCstToken, "dstCstToken");
        assertEq(a.premiumToken, b.premiumToken, "premiumToken");
        assertEq(a.repaymentToken, b.repaymentToken, "repaymentToken");
        assertEq(a.repaymentAmount, b.repaymentAmount, "repaymentAmount");
        assertEq(a.orderSize, b.orderSize, "orderSize");
        assertEq(a.minFillSize, b.minFillSize, "minFillSize");
        assertEq(a.allowPartialFills, b.allowPartialFills, "allowPartialFills");
        assertEq(a.allowUnderfill, b.allowUnderfill, "allowUnderfill");
        assertEq(a.exclusiveFiller, b.exclusiveFiller, "exclusiveFiller");
        assertEq(a.minPremiumPerShare, b.minPremiumPerShare, "minPremiumPerShare");
        assertEq(a.cellarIntentHash, b.cellarIntentHash, "cellarIntentHash");

        assertEq(a.outputs.length, b.outputs.length, "outputs len");
        for (uint256 i = 0; i < a.outputs.length; i++) {
            assertEq(a.outputs[i].token, b.outputs[i].token, "out.token");
            assertEq(a.outputs[i].amount, b.outputs[i].amount, "out.amount");
            assertEq(a.outputs[i].recipient, b.outputs[i].recipient, "out.recipient");
            assertEq(a.outputs[i].chainId, b.outputs[i].chainId, "out.chainId");
        }

        assertEq(a.rolloverHooks.length, b.rolloverHooks.length, "rolloverHooks len");
        for (uint256 i = 0; i < a.rolloverHooks.length; i++) {
            _assertCallEq(a.rolloverHooks[i], b.rolloverHooks[i]);
        }
        assertEq(a.premiumHooks.length, b.premiumHooks.length, "premiumHooks len");
        for (uint256 i = 0; i < a.premiumHooks.length; i++) {
            _assertCallEq(a.premiumHooks[i], b.premiumHooks[i]);
        }
        assertEq(keccak256(a.cellarSignature), keccak256(b.cellarSignature), "cellarSignature");
    }

    /// @dev Returns `encoded[1:]` as a fresh `bytes memory`. Used to split the packed 1-byte
    ///      outputIndex prefix from the abi-encoded struct tail produced by the library's
    ///      post-Pashov-A8 encoders.
    function _sliceFromOne(bytes memory encoded) internal pure returns (bytes memory out) {
        require(encoded.length >= 1, "encoded too short");
        uint256 tailLen = encoded.length - 1;
        out = new bytes(tailLen);
        for (uint256 i = 0; i < tailLen; i++) {
            out[i] = encoded[i + 1];
        }
    }
}
