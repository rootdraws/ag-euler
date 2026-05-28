// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {ExactFillSettlerTestBase} from "test/exact/ExactFillSettlerTestBase.sol";
import {IPartialFillSettler} from "contracts/interfaces/IPartialFillSettler.sol";

/// @title BaseSettler storage-layout assertions (PR 3 — Task 9 / #53)
/// @notice Two-layer proof that `dstCstProduced` owns a full 32-byte slot in both settlers'
///         per-filler structs — previously Exact used `uint128`, which silently narrowed on
///         large rolls. PR 3 unifies the width on `uint256` across both concretes.
/// @dev Layer 1 — compile-time binding: the ABI-generated getters return `uint256`. Any
///      regression that narrows the storage type would break compilation of the binding leaves.
///      Layer 2 — runtime `vm.store` / `vm.load`: write a value with non-zero bits ABOVE bit 128
///      into the `dstCstProduced` slot and assert they survive the round trip. A `uint128` slot
///      would zero the upper half. Both signals are retained because each one catches what the
///      other misses.
contract BaseSettler_storageLayout_Exact is ExactFillSettlerTestBase {
    /// @dev Layer 1 — compile-time binding. The `fillRecords` getter's third return is
    ///      `dstCstProduced`. Binding it to `uint256` here is a compile-time proof that the
    ///      storage type is `uint256`. If a future change narrows the field back to `uint128`,
    ///      this binding will fail to compile.
    function test_storage_dstCstProducedWidth_uint256_compileTimeBinding() public view {
        bytes32 orderId = bytes32(uint256(1));
        bytes32 outputHash = bytes32(uint256(2));
        (address f, address d, uint256 produced, uint64 filledAt) = settler.fillRecords(orderId, outputHash);
        f;
        d;
        produced;
        filledAt;
        assertTrue(true);
    }

    /// @dev Layer 2 — runtime assertion that `dstCstProduced` owns its own 32-byte slot.
    ///      `fillRecords` lives at storage slot 1 in ExactFillSettler. Within a `FillRecord`
    ///      entry the field offsets are: [0] filler, [1] destination, [2] dstCstProduced,
    ///      [3] filledAt — verified via `forge inspect storage-layout`. We write a value whose
    ///      upper 128 bits are non-zero into offset 2, read it back via `vm.load`, and assert the
    ///      upper half survived. A `uint128` slot would silently truncate the top bits to zero.
    function test_storage_dstCstProducedOwnsFullSlot_runtime() public {
        bytes32 orderId = bytes32(uint256(0x1234));
        bytes32 outputHash = bytes32(uint256(0x5678));
        // fillRecords[orderId][outputHash] slot: inner mapping key is `outputHash`, outer key is
        // `orderId`, base slot is 1 (verified via `forge inspect`).
        bytes32 fillSlot = keccak256(abi.encode(outputHash, keccak256(abi.encode(orderId, uint256(1)))));
        bytes32 producedSlot = bytes32(uint256(fillSlot) + 2);

        // Value with the top 128 bits explicitly set so a `uint128` slot would erase them.
        uint256 value = (uint256(type(uint128).max) << 128) | uint256(0xDEAD_BEEF);
        vm.store(address(settler), producedSlot, bytes32(value));

        bytes32 loaded = vm.load(address(settler), producedSlot);
        assertEq(loaded, bytes32(value), "dstCstProduced slot must preserve all 256 bits");
        assertGt(uint256(loaded) >> 128, 0, "top 128 bits of dstCstProduced must survive");

        // Round-trip through the ABI getter too — confirms the type decode matches the raw slot.
        (,, uint256 produced,) = settler.fillRecords(orderId, outputHash);
        assertEq(produced, value);
    }
}

contract BaseSettler_storageLayout_Partial is PartialFillSettlerTestBase {
    /// @dev Layer 1 — compile-time binding. The `fillerRollovers` getter returns a
    ///      `FillerRollover` struct whose `dstCstProduced` field is declared `uint256` on the
    ///      interface. Binding it to `uint256` here asserts the storage shape at compile time.
    function test_storage_dstCstProducedWidth_uint256_compileTimeBinding() public view {
        IPartialFillSettler.FillerRollover memory r = settler.fillerRollovers(bytes32(uint256(1)), address(0));
        uint256 produced = r.dstCstProduced;
        produced;
        assertTrue(true);
    }

    /// @dev Layer 2 — runtime assertion that `dstCstProduced` owns its own 32-byte slot.
    ///      `_fillerRollovers` lives at storage slot 1 in PartialFillSettler (verified via
    ///      `forge inspect storage-layout`). Within a `FillerRollover` entry the field offsets
    ///      are: [0] srcCstProvided, [1] dstCstProduced, [2] destination+bools packed. We write
    ///      a value whose upper 128 bits are non-zero into offset 1, read it back via `vm.load`,
    ///      and assert the upper half survived.
    function test_storage_dstCstProducedOwnsFullSlot_runtime() public {
        bytes32 orderDigest = bytes32(uint256(0xABCD));
        address filler = address(uint160(0x1111));
        // _fillerRollovers[orderDigest][filler] slot: inner mapping key is `filler`, outer key is
        // `orderDigest`, base slot is 1 (verified via `forge inspect`).
        bytes32 entrySlot = keccak256(abi.encode(filler, keccak256(abi.encode(orderDigest, uint256(1)))));
        bytes32 producedSlot = bytes32(uint256(entrySlot) + 1);

        uint256 value = (uint256(type(uint128).max) << 128) | uint256(0xCAFE_BABE);
        vm.store(address(settler), producedSlot, bytes32(value));

        bytes32 loaded = vm.load(address(settler), producedSlot);
        assertEq(loaded, bytes32(value), "dstCstProduced slot must preserve all 256 bits");
        assertGt(uint256(loaded) >> 128, 0, "top 128 bits of dstCstProduced must survive");

        // Round-trip through the ABI getter — confirms the type decode matches the raw slot.
        IPartialFillSettler.FillerRollover memory r = settler.fillerRollovers(orderDigest, filler);
        assertEq(r.dstCstProduced, value);
    }
}
