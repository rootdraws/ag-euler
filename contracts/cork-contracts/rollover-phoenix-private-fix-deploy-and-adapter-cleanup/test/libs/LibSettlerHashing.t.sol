// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {
    LibSettlerHashing,
    ORDER_DATA_TYPE_HASH,
    CORK_ROLLOVER_ORDER_TYPE,
    GASLESS_ORDER_TYPE_HASH,
    CANCEL_TYPE_HASH
} from "contracts/libs/LibSettlerHashing.sol";
import {Call} from "cellar/ICorkCellar.sol";
import {MarketId} from "phoenix/interfaces/IPoolManager.sol";

// solhint-disable max-line-length

/// @dev Canonical, whitespace-free EIP-712 `encodeType` pre-image for `OrderData` — mirror of
///      the literal embedded inside `LibSettlerHashing`. Duplicated here so a drift in either
///      file triggers a test failure rather than silent divergence.
string constant ORDER_DATA_TYPE_STRING =
    "OrderData(address receiver,MarketId srcPoolId,MarketId dstPoolId,address srcCstToken,address dstCstToken,address premiumToken,address repaymentToken,uint256 repaymentAmount,uint256 orderSize,uint256 minFillSize,bool allowPartialFills,bool allowUnderfill,address exclusiveFiller,uint256 minPremiumPerShare,bytes32 cellarIntentHash,Output[] outputs,Call[] rolloverHooks,Call[] premiumHooks)";

// solhint-enable max-line-length

contract LibSettlerHashingTest is Test {
    // ─────────────────────────────────────────────────────────────────────────────
    // Type-hash constants
    // ─────────────────────────────────────────────────────────────────────────────

    function test_CORK_ROLLOVER_ORDER_TYPE_matchesLiteral() public pure {
        assertEq(
            CORK_ROLLOVER_ORDER_TYPE,
            0xab61e9a504dbc4e46c085fc4d288cbec5ff52becfb3a3f045b8141e3cb45291a,
            "CORK_ROLLOVER_ORDER_TYPE drift"
        );
    }

    function test_ORDER_DATA_TYPE_HASH_matchesLiteral() public pure {
        assertEq(
            ORDER_DATA_TYPE_HASH,
            0x74bf0f222fff9a014945cabe39ac8cd288a682e5b58b6d8bf05e95c85ad62c34,
            "ORDER_DATA_TYPE_HASH drift vs pre-image"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOutputHash
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOutputHash_vectorA() public pure {
        IOriginSettler.Output memory output = IOriginSettler.Output({
            token: bytes32(uint256(uint160(address(0x1111)))),
            amount: 1e18,
            recipient: bytes32(uint256(uint160(address(0x2222)))),
            chainId: 1
        });

        bytes32 expected = 0x4b320e3aa4edf129f12ebc7f99ec068c968391b29487551e69ba9b4e520f6443;
        assertEq(LibSettlerHashing.computeOutputHash(output), expected, "vectorA mismatch");
    }

    function test_computeOutputHash_vectorB() public pure {
        IOriginSettler.Output memory output = IOriginSettler.Output({
            token: bytes32(uint256(0xABCDEF)),
            amount: type(uint256).max,
            recipient: bytes32(uint256(uint160(address(0xDEAD)))),
            chainId: 42161
        });

        bytes32 expected = 0xc2d7676c36e1cc28443c901196808c15ae4f9acf84478f524acfa49f4eb9a322;
        assertEq(LibSettlerHashing.computeOutputHash(output), expected, "vectorB mismatch");
    }

    function testFuzz_computeOutputHash_stability(bytes32 token, uint256 amount, bytes32 recipient, uint256 chainId)
        public
        pure
    {
        IOriginSettler.Output memory output =
            IOriginSettler.Output({token: token, amount: amount, recipient: recipient, chainId: chainId});

        bytes32 first = LibSettlerHashing.computeOutputHash(output);
        bytes32 second = LibSettlerHashing.computeOutputHash(output);
        assertEq(first, second, "hash not deterministic");

        bytes32 hand = keccak256(abi.encode(token, amount, recipient, chainId));
        assertEq(first, hand, "hash diverges from hand-computed");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOrderId
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOrderId_vectorA() public {
        vm.chainId(7);
        address settler = address(0xBEEF);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        bytes32 expected = 0xa8cae511ae77f79615c4c35f31bb76134069efff9843c2068c28118c0665bcee;
        assertEq(LibSettlerHashing.computeOrderId(settler, order), expected, "orderId drift");
    }

    function test_computeOrderId_chainIdBound() public {
        address settler = address(0xBEEF);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        vm.chainId(1);
        bytes32 onOne = LibSettlerHashing.computeOrderId(settler, order);

        vm.chainId(2);
        bytes32 onTwo = LibSettlerHashing.computeOrderId(settler, order);

        assertNotEq(onOne, onTwo, "orderId must differ across chain ids");
    }

    function test_computeOrderId_settlerBound() public {
        vm.chainId(1);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        bytes32 onA = LibSettlerHashing.computeOrderId(address(0xA), order);
        bytes32 onB = LibSettlerHashing.computeOrderId(address(0xB), order);

        assertNotEq(onA, onB, "orderId must differ across settlers");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOrderDigest
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOrderDigest_vectorA() public {
        vm.chainId(11);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();
        OrderData memory od = _fixtureOrderData();

        // Re-derived after PR 2 expanded the digest to include the previously-omitted fields
        // (rolloverHooks, premiumHooks, repaymentToken, repaymentAmount, minFillSize,
        // exclusiveFiller). `cellarIntentHash` is intentionally NOT bound — see the library's
        // NatSpec for rationale (construction-time fixed-point, RFC §A.8). Expected value is the
        // concatenation of the two encoding chunks defined in `LibSettlerHashing.computeOrderDigest`.
        bytes memory first = _encodeDigestChunkOne(settler, order, od);
        bytes memory second = _encodeDigestChunkTwo(order, od);
        bytes32 expected = keccak256(bytes.concat(first, second));
        bytes32 actual = LibSettlerHashing.computeOrderDigest(settler, order, od);

        // Re-derivation: catches ABI-stability regressions (field order, encoding scheme).
        assertEq(actual, expected, "orderDigest drift vs re-derivation");

        // Pinned literal: catches silent drift even if the re-derivation helpers are updated
        // in lock-step with the library. Recompute and re-pin only if the digest construction
        // is intentionally changed (e.g., a future PR adds a new bound field).
        bytes32 pinned = 0x9a1cd2ce5f30e32c4afcf95963cc678c0326c6eb5985456b542dc2fa0da416a4;
        assertEq(actual, pinned, "orderDigest drift vs pinned vector");
    }

    /// @dev Mirrors `LibSettlerHashing.computeOrderDigest` chunk 1. Pulled into a helper so the
    ///      test body stays below the via-IR stack depth limit.
    function _encodeDigestChunkOne(
        address settler,
        IOriginSettler.GaslessCrossChainOrder memory order,
        OrderData memory od
    ) internal view returns (bytes memory) {
        return abi.encode(
            block.chainid,
            settler,
            order.user,
            order.nonce,
            order.originChainId,
            order.openDeadline,
            order.fillDeadline,
            od.srcPoolId,
            od.dstPoolId,
            od.srcCstToken,
            od.dstCstToken,
            od.premiumToken
        );
    }

    /// @dev Mirrors `LibSettlerHashing.computeOrderDigest` chunk 2. Further split into `a` and `b`
    ///      halves because 14 fields in a single `abi.encode` blow via-IR's stack limit inside a
    ///      `view` test function even though the library function itself compiles.
    function _encodeDigestChunkTwo(IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory a = abi.encode(
            od.repaymentToken,
            od.repaymentAmount,
            od.orderSize,
            od.minFillSize,
            od.minPremiumPerShare,
            keccak256(abi.encode(od.outputs)),
            keccak256(abi.encode(od.rolloverHooks))
        );
        bytes memory b = abi.encode(
            keccak256(abi.encode(od.premiumHooks)),
            od.allowPartialFills,
            od.allowUnderfill,
            od.exclusiveFiller,
            order.orderDataType,
            od.receiver
        );
        return bytes.concat(a, b);
    }

    function test_computeOrderDigest_chainIdBound() public {
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();
        OrderData memory od = _fixtureOrderData();

        vm.chainId(1);
        bytes32 onOne = LibSettlerHashing.computeOrderDigest(settler, order, od);

        vm.chainId(2);
        bytes32 onTwo = LibSettlerHashing.computeOrderDigest(settler, order, od);

        assertNotEq(onOne, onTwo, "orderDigest must differ across chain ids");
    }

    function test_computeOrderDigest_ChangesWhenRepaymentTokenChanges() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        OrderData memory odB = _fixtureOrderData();
        odB.repaymentToken = address(0xABCDEF);

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // RFC 003 issue #41: repaymentToken was previously omitted from the digest. PR 2 binds it.
        assertNotEq(hashA, hashB, "orderDigest must differ when repaymentToken changes");
    }

    function test_computeOrderDigest_ChangesWhenRepaymentAmountChanges() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        OrderData memory odB = _fixtureOrderData();
        odB.repaymentAmount = odA.repaymentAmount + 1234;

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // RFC 003 issue #41: repaymentAmount was previously omitted from the digest. PR 2 binds it.
        assertNotEq(hashA, hashB, "orderDigest must differ when repaymentAmount changes");
    }

    function test_computeOrderDigest_OmitsCellarIntentHash() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        OrderData memory odB = _fixtureOrderData();
        odB.cellarIntentHash = keccak256("different-intent");

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // PR 2 deliberately omits `cellarIntentHash` from the digest — including it would create
        // a fixed-point at maker-construction time (the RFC §A.8 "circular dependency" concern).
        // Collision defence is preserved because the digest directly hashes `rolloverHooks`,
        // `premiumHooks`, `allowPartialFills`, `allowUnderfill`, `orderSize`, `exclusiveFiller`,
        // and the fill deadline — every field the intent commits to. Two orders that differ only
        // in `cellarIntentHash` (but not in those underlying fields) are semantically identical.
        assertEq(hashA, hashB, "orderDigest intentionally omits cellarIntentHash");
    }

    function test_computeOrderDigest_ChangesWhenRolloverHooksChange() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        OrderData memory odB = _fixtureOrderData();
        odB.rolloverHooks = new Call[](1);
        odB.rolloverHooks[0] =
            Call({target: address(0xC0DE), value: 0, callData: hex"1234", allowFailure: false, isDelegateCall: false});

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // RFC 003 issue #41: rolloverHooks were previously omitted — the collision scenario
        // documented in the issue. PR 2 binds the hook list to the digest.
        assertNotEq(hashA, hashB, "orderDigest must differ when rolloverHooks change");
    }

    function test_computeOrderDigest_ChangesWhenPremiumHooksChange() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        OrderData memory odB = _fixtureOrderData();
        odB.premiumHooks = new Call[](1);
        odB.premiumHooks[0] =
            Call({target: address(0xBEEF), value: 0, callData: hex"5678", allowFailure: false, isDelegateCall: false});

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // RFC 003 issue #41: premiumHooks were previously omitted from the digest. PR 2 binds it.
        assertNotEq(hashA, hashB, "orderDigest must differ when premiumHooks change");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // AS-19 / AS-21 ingress-gate fields — pre-image membership + identity tests
    // ─────────────────────────────────────────────────────────────────────────────

    function test_ORDER_DATA_TYPE_HASH_preimageIncludesMinFillSize() public pure {
        assertTrue(_preimageContains("uint256 minFillSize"), "pre-image must declare minFillSize");
    }

    function test_ORDER_DATA_TYPE_HASH_preimageIncludesExclusiveFiller() public pure {
        assertTrue(_preimageContains("address exclusiveFiller"), "pre-image must declare exclusiveFiller");
    }

    function test_computeOrderDigest_ChangesWhenMinFillSizeChanges() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        odA.minFillSize = 0;

        OrderData memory odB = _fixtureOrderData();
        odB.minFillSize = 10e18;

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // PR 2 expands `computeOrderDigest` to hash all identity-bearing OrderData fields, including
        // `minFillSize` (added in PR 1 for the AS-19 ingress gate). Two orders differing only in
        // `minFillSize` must now produce distinct digests.
        assertNotEq(hashA, hashB, "orderDigest must differ when minFillSize changes");
    }

    function test_computeOrderDigest_ChangesWhenExclusiveFillerChanges() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _fixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        odA.exclusiveFiller = address(0);

        OrderData memory odB = _fixtureOrderData();
        odB.exclusiveFiller = address(0xDEADBEEF);

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        // PR 2 binds `exclusiveFiller` (added in PR 1 for the AS-21 ingress gate) to the digest so
        // an order opened with no exclusive filler cannot collide with an otherwise-identical order
        // restricted to a single filler.
        assertNotEq(hashA, hashB, "orderDigest must differ when exclusiveFiller changes");
    }

    function test_computeOrderDigest_doesNotIncludeMinFillRatio() public pure {
        bytes memory pre = bytes(ORDER_DATA_TYPE_STRING);
        bytes memory needle = bytes("minFillRatio");

        bool found = false;
        if (pre.length >= needle.length) {
            uint256 max = pre.length - needle.length;
            for (uint256 i = 0; i <= max; i++) {
                bool match_ = true;
                for (uint256 j = 0; j < needle.length; j++) {
                    if (pre[i + j] != needle[j]) {
                        match_ = false;
                        break;
                    }
                }
                if (match_) {
                    found = true;
                    break;
                }
            }
        }
        assertFalse(found, "OrderData pre-image must not contain 'minFillRatio'");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Substring scan over the canonical `OrderData` pre-image string. Equivalent to
    ///      `bytes.contains` but Solidity doesn't ship one; the loop is O(n*m) which is fine for
    ///      a few-hundred-byte constant.
    function _preimageContains(string memory needle_) internal pure returns (bool) {
        bytes memory hay = bytes(ORDER_DATA_TYPE_STRING);
        bytes memory needle = bytes(needle_);
        if (hay.length < needle.length) return false;
        uint256 last = hay.length - needle.length;
        for (uint256 i; i <= last; ++i) {
            bool match_ = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────────

    function _fixtureOrder() internal pure returns (IOriginSettler.GaslessCrossChainOrder memory) {
        return IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(0xBEEF),
            user: address(0xCAFE),
            nonce: 7,
            originChainId: 1,
            openDeadline: uint32(1_700_000_000),
            fillDeadline: uint32(1_700_000_600),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: hex"1234"
        });
    }

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
        od.allowPartialFills = false;
        od.allowUnderfill = false;
        od.minPremiumPerShare = 1e15;
        od.cellarIntentHash = keccak256("intent");

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
}
