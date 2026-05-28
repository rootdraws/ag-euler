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
import {MockERC1271Signer} from "test/mocks/MockERC1271Signer.sol";

contract LibSettlerHashingEIP712Test is Test {
    // ─────────────────────────────────────────────────────────────────────────────
    // Type-hash constants
    // ─────────────────────────────────────────────────────────────────────────────

    function test_GASLESS_ORDER_TYPE_HASH_matchesLiteral() public pure {
        bytes32 expected = keccak256(
            "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,"
            "uint256 originChainId,uint32 openDeadline,uint32 fillDeadline," "bytes32 orderDataType,bytes orderData)"
        );
        assertEq(GASLESS_ORDER_TYPE_HASH, expected, "GASLESS_ORDER_TYPE_HASH drift");
    }

    function test_CANCEL_TYPE_HASH_matchesLiteral() public pure {
        bytes32 expected = keccak256("Cancel(bytes32 orderId,uint256 cancelDeadline)");
        assertEq(CANCEL_TYPE_HASH, expected, "CANCEL_TYPE_HASH drift");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOpenForDigest — reference vector (independently computed via ethers.js)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Reference vector computed via ethers.js TypedDataEncoder. See
    ///      script/tools/compute-eip712-reference.js for the independent computation.
    function test_computeOpenForDigest_referenceVector() public pure {
        IOriginSettler.GaslessCrossChainOrder memory order = IOriginSettler.GaslessCrossChainOrder({
            originSettler: 0xAAaA000000000000000000000000000000000001,
            user: 0xb0B0000000000000000000000000000000000001,
            nonce: 42,
            originChainId: 1,
            openDeadline: uint32(1800000000),
            fillDeadline: uint32(1800000100),
            orderDataType: bytes32(uint256(0xC0C0)),
            orderData: hex"00112233445566778899aabbccddeeff"
        });

        bytes32 expected = 0xf7c7d7ad316ab6e84291e8000680b9269e6f43e8484f0eb0e53f06f17b72726f;
        bytes32 actual = LibSettlerHashing.computeOpenForDigest(order);
        assertEq(actual, expected, "computeOpenForDigest does not match ethers.js reference");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOpenForDigest — mutation tests
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOpenForDigest_HashesRawOrderDataBytes() public pure {
        IOriginSettler.GaslessCrossChainOrder memory orderA = _eip712FixtureOrder();
        IOriginSettler.GaslessCrossChainOrder memory orderB = _eip712FixtureOrder();
        orderB.orderData = hex"deadbeef";

        bytes32 hashA = LibSettlerHashing.computeOpenForDigest(orderA);
        bytes32 hashB = LibSettlerHashing.computeOpenForDigest(orderB);
        assertNotEq(hashA, hashB, "digest must change when orderData mutates");
    }

    function test_computeOpenForDigest_ChangesWithEachField() public pure {
        IOriginSettler.GaslessCrossChainOrder memory base = _eip712FixtureOrder();
        bytes32 baseHash = LibSettlerHashing.computeOpenForDigest(base);

        IOriginSettler.GaslessCrossChainOrder memory m1 = _eip712FixtureOrder();
        m1.originSettler = address(0x9999);
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m1), baseHash, "originSettler");

        IOriginSettler.GaslessCrossChainOrder memory m2 = _eip712FixtureOrder();
        m2.user = address(0x9999);
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m2), baseHash, "user");

        IOriginSettler.GaslessCrossChainOrder memory m3 = _eip712FixtureOrder();
        m3.nonce = 999;
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m3), baseHash, "nonce");

        IOriginSettler.GaslessCrossChainOrder memory m4 = _eip712FixtureOrder();
        m4.originChainId = 137;
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m4), baseHash, "originChainId");

        IOriginSettler.GaslessCrossChainOrder memory m5 = _eip712FixtureOrder();
        m5.openDeadline = uint32(9999);
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m5), baseHash, "openDeadline");

        IOriginSettler.GaslessCrossChainOrder memory m6 = _eip712FixtureOrder();
        m6.fillDeadline = uint32(9999);
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m6), baseHash, "fillDeadline");

        IOriginSettler.GaslessCrossChainOrder memory m7 = _eip712FixtureOrder();
        m7.orderDataType = bytes32(uint256(0xDEAD));
        assertNotEq(LibSettlerHashing.computeOpenForDigest(m7), baseHash, "orderDataType");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOrderDigest — allowUnderfill inclusion (L4)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOrderDigest_ChangesWhenAllowUnderfillFlips() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _eip712FixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        odA.allowUnderfill = false;

        OrderData memory odB = _fixtureOrderData();
        odB.allowUnderfill = true;

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        assertNotEq(hashA, hashB, "orderDigest must differ when allowUnderfill flips");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeOrderDigest — cellarSignature excluded
    // ─────────────────────────────────────────────────────────────────────────────

    function test_computeOrderDigest_StaysStableAcrossCellarSignatureMutations() public {
        vm.chainId(1);
        address settler = address(0xF00D);
        IOriginSettler.GaslessCrossChainOrder memory order = _eip712FixtureOrder();

        OrderData memory odA = _fixtureOrderData();
        odA.cellarSignature = hex"aabbccdd";

        OrderData memory odB = _fixtureOrderData();
        odB.cellarSignature = hex"11223344556677889900";

        bytes32 hashA = LibSettlerHashing.computeOrderDigest(settler, order, odA);
        bytes32 hashB = LibSettlerHashing.computeOrderDigest(settler, order, odB);
        assertEq(hashA, hashB, "orderDigest must ignore cellarSignature");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // computeCancelDigest — EIP-712 conformance
    // ─────────────────────────────────────────────────────────────────────────────

    function test_cancelDigest_MatchesEIP712Form() public pure {
        bytes32 orderId = keccak256("test-order-id");
        uint256 cancelDeadline = 1800000200;

        bytes32 expected = keccak256(abi.encode(CANCEL_TYPE_HASH, orderId, cancelDeadline));
        bytes32 actual = LibSettlerHashing.computeCancelDigest(orderId, cancelDeadline);
        assertEq(actual, expected, "cancel digest must match manual EIP-712 encoding");
    }

    /// @dev Cross-validated against ethers.js reference vector.
    function test_cancelDigest_ReferenceVector() public pure {
        bytes32 orderId = 0x5241fdda2811dea0d20565b1b2df3ffb92f40ea6e30a36a86aa6c86fa1ea0dcf;
        uint256 cancelDeadline = 1800000200;

        bytes32 expected = 0xc4a8aa14b5a7d26e2815652d572501a6a558bafef29ce6f65c872212e7aa4801;
        bytes32 actual = LibSettlerHashing.computeCancelDigest(orderId, cancelDeadline);
        assertEq(actual, expected, "cancel digest does not match ethers.js reference");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // ERC-1271 envelope test
    // ─────────────────────────────────────────────────────────────────────────────

    function test_erc1271_acceptsAuthorizedDigest() public {
        MockERC1271Signer signer = new MockERC1271Signer();

        IOriginSettler.GaslessCrossChainOrder memory order = _eip712FixtureOrder();
        bytes32 structHash = LibSettlerHashing.computeOpenForDigest(order);

        signer.authorize(structHash);

        bytes4 result = signer.isValidSignature(structHash, "");
        assertEq(result, bytes4(0x1626ba7e), "ERC-1271 must accept authorized digest");
    }

    function test_erc1271_rejectsUnauthorizedDigest() public {
        MockERC1271Signer signer = new MockERC1271Signer();

        IOriginSettler.GaslessCrossChainOrder memory order = _eip712FixtureOrder();
        bytes32 structHash = LibSettlerHashing.computeOpenForDigest(order);

        // Authorize a different digest
        signer.authorize(keccak256("wrong"));

        bytes4 result = signer.isValidSignature(structHash, "");
        assertEq(result, bytes4(0xffffffff), "ERC-1271 must reject unauthorized digest");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────────

    function _eip712FixtureOrder() internal pure returns (IOriginSettler.GaslessCrossChainOrder memory) {
        return IOriginSettler.GaslessCrossChainOrder({
            originSettler: 0xAAaA000000000000000000000000000000000001,
            user: 0xb0B0000000000000000000000000000000000001,
            nonce: 42,
            originChainId: 1,
            openDeadline: uint32(1800000000),
            fillDeadline: uint32(1800000100),
            orderDataType: bytes32(uint256(0xC0C0)),
            orderData: hex"00112233445566778899aabbccddeeff"
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
