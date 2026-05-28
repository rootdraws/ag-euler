// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    LibRolloverOrder,
    RolloverFillerData,
    PremiumFillerData,
    PartialFillerData
} from "contracts/libs/LibRolloverOrder.sol";
import {CellarIntent, Call} from "cellar/ICorkCellar.sol";

/// @title LibRolloverOrder_EncoderRoundTrip
/// @notice Pashov A8: the three filler-data encoders now emit `bytes1(outputIndex) ||
///         abi.encode(fd)`. This matches `BaseSettler.fill`'s split —
///         `uint8(bytes1(fillerData[0:1]))` followed by `abi.decode(fillerData[1:], (...))`.
///         Each test round-trips through exactly that production decode path.
contract LibRolloverOrder_EncoderRoundTrip_Test is Test {
    // ═══════════════════════════════════════════════════════════════
    //  Production-path round-trip harness
    // ═══════════════════════════════════════════════════════════════

    /// @dev Mirrors `BaseSettler.fill`'s split exactly. `fillerData` is accepted as calldata so
    ///      we exercise the slicing arithmetic that `BaseSettler` performs on-chain.
    function splitProdPath(bytes calldata fillerData) external pure returns (uint8 idx, bytes memory tail) {
        idx = uint8(bytes1(fillerData[0:1]));
        tail = fillerData[1:];
    }

    // ═══════════════════════════════════════════════════════════════
    //  Rollover leg
    // ═══════════════════════════════════════════════════════════════

    function test_encodeRolloverFillerData_roundTrips_through_production_split() public view {
        RolloverFillerData memory fd = RolloverFillerData({destination: address(0xD35713)});

        bytes memory encoded = LibRolloverOrder.encodeRolloverFillerData(fd);
        (uint8 idx, bytes memory tail) = this.splitProdPath(encoded);
        RolloverFillerData memory decoded = abi.decode(tail, (RolloverFillerData));

        assertEq(idx, 0, "rollover leg prefix must be 0");
        assertEq(decoded.destination, fd.destination, "destination round-trips");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Premium leg
    // ═══════════════════════════════════════════════════════════════

    function test_encodePremiumFillerData_roundTrips_through_production_split() public view {
        PremiumFillerData memory fd = PremiumFillerData({debitFrom: address(0xDEB17)});

        bytes memory encoded = LibRolloverOrder.encodePremiumFillerData(fd);
        (uint8 idx, bytes memory tail) = this.splitProdPath(encoded);
        PremiumFillerData memory decoded = abi.decode(tail, (PremiumFillerData));

        assertEq(idx, 1, "premium leg prefix must be 1");
        assertEq(decoded.debitFrom, fd.debitFrom, "debitFrom round-trips");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Partial path — both legs
    // ═══════════════════════════════════════════════════════════════

    function test_encodePartialFillerData_roundTrips_through_production_split_both_legs() public view {
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
                allowPartialFills: true,
                allowUnderfill: false,
                rolloverHooks: new Call[](0),
                premiumHooks: new Call[](0)
            }),
            cellarSig: hex"DEADBEEF"
        });

        for (uint8 prefix = 0; prefix < 2; prefix++) {
            bytes memory encoded = LibRolloverOrder.encodePartialFillerData(prefix, fd);
            (uint8 idx, bytes memory tail) = this.splitProdPath(encoded);
            PartialFillerData memory decoded = abi.decode(tail, (PartialFillerData));

            assertEq(idx, prefix, "partial prefix round-trips");
            assertEq(decoded.destination, fd.destination, "destination");
            assertEq(decoded.debitFrom, fd.debitFrom, "debitFrom");
            assertEq(decoded.targetFiller, fd.targetFiller, "targetFiller");
            assertEq(decoded.intent.orderDigest, fd.intent.orderDigest, "intent.orderDigest");
            assertEq(decoded.intent.expectedCaller, fd.intent.expectedCaller, "intent.expectedCaller");
            assertEq(decoded.intent.settler, fd.intent.settler, "intent.settler");
            assertEq(decoded.intent.deadline, fd.intent.deadline, "intent.deadline");
            assertEq(decoded.intent.orderSize, fd.intent.orderSize, "intent.orderSize");
            assertEq(decoded.intent.allowPartialFills, fd.intent.allowPartialFills, "intent.allowPartialFills");
            assertEq(decoded.intent.allowUnderfill, fd.intent.allowUnderfill, "intent.allowUnderfill");
            assertEq(decoded.intent.rolloverHooks.length, 0, "rolloverHooks len");
            assertEq(decoded.intent.premiumHooks.length, 0, "premiumHooks len");
            assertEq(keccak256(decoded.cellarSig), keccak256(fd.cellarSig), "cellarSig");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Byte-level shape sanity
    // ═══════════════════════════════════════════════════════════════

    /// @notice The first byte is the RAW outputIndex — not zero-padded into a 32-byte word. This
    ///         is the exact shape `BaseSettler.fill` consumes via `bytes1(fillerData[0:1])`.
    function test_rollover_encoded_first_byte_is_raw_prefix() public pure {
        RolloverFillerData memory fd = RolloverFillerData({destination: address(0xABCD)});
        bytes memory encoded = LibRolloverOrder.encodeRolloverFillerData(fd);

        assertEq(uint8(encoded[0]), 0, "first byte is the raw uint8 prefix");
    }

    function test_premium_encoded_first_byte_is_raw_prefix() public pure {
        PremiumFillerData memory fd = PremiumFillerData({debitFrom: address(0xBEEF)});
        bytes memory encoded = LibRolloverOrder.encodePremiumFillerData(fd);

        assertEq(uint8(encoded[0]), 1, "first byte is the raw uint8 prefix");
    }
}
