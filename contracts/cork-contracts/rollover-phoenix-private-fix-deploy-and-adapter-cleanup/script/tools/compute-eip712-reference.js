#!/usr/bin/env node
/**
 * Computes the EIP-712 struct hash for a GaslessCrossChainOrder using ethers.js
 * TypedDataEncoder. This provides an independent reference vector for the
 * Solidity test in test/libs/LibSettlerHashing_eip712.t.sol.
 *
 * Usage: node script/tools/compute-eip712-reference.js
 */

const { ethers } = require("ethers");

// EIP-712 type definition for GaslessCrossChainOrder
const types = {
  GaslessCrossChainOrder: [
    { name: "originSettler", type: "address" },
    { name: "user", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "originChainId", type: "uint256" },
    { name: "openDeadline", type: "uint32" },
    { name: "fillDeadline", type: "uint32" },
    { name: "orderDataType", type: "bytes32" },
    { name: "orderData", type: "bytes" },
  ],
};

// Test payload — must match the Solidity test exactly
const order = {
  originSettler: "0xAAAA000000000000000000000000000000000001",
  user: "0xB0B0000000000000000000000000000000000001",
  nonce: 42n,
  originChainId: 1n,
  openDeadline: 1800000000,
  fillDeadline: 1800000100,
  orderDataType: ethers.zeroPadValue(ethers.toBeHex(0xc0c0), 32),
  orderData: "0x00112233445566778899aabbccddeeff",
};

// Compute the type hash
const typeHash = ethers.keccak256(
  ethers.toUtf8Bytes(
    "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce," +
      "uint256 originChainId,uint32 openDeadline,uint32 fillDeadline," +
      "bytes32 orderDataType,bytes orderData)"
  )
);

console.log("TYPE_HASH:", typeHash);

// Compute hashStruct manually (matching Solidity abi.encode logic)
// For EIP-712: hashStruct = keccak256(typeHash || encode(fields))
// Dynamic types (bytes, string) are encoded as keccak256(value)
const orderDataHash = ethers.keccak256(order.orderData);

const encodedData = ethers.AbiCoder.defaultAbiCoder().encode(
  [
    "bytes32",
    "address",
    "address",
    "uint256",
    "uint256",
    "uint32",
    "uint32",
    "bytes32",
    "bytes32",
  ],
  [
    typeHash,
    order.originSettler,
    order.user,
    order.nonce,
    order.originChainId,
    order.openDeadline,
    order.fillDeadline,
    order.orderDataType,
    orderDataHash,
  ]
);

const structHash = ethers.keccak256(encodedData);

console.log("orderData keccak256:", orderDataHash);
console.log("hashStruct (computeOpenForDigest):", structHash);

// Also compute using TypedDataEncoder for cross-validation
const hashStructViaEncoder = ethers.TypedDataEncoder.hashStruct(
  "GaslessCrossChainOrder",
  types,
  order
);

console.log("hashStruct via TypedDataEncoder:", hashStructViaEncoder);

// Verify they match
if (structHash === hashStructViaEncoder) {
  console.log("\nSUCCESS: Both methods agree.");
} else {
  console.error("\nMISMATCH: Manual and TypedDataEncoder disagree!");
  process.exit(1);
}

// Also compute the Cancel type hash
const cancelTypeHash = ethers.keccak256(
  ethers.toUtf8Bytes("Cancel(bytes32 orderId,uint256 cancelDeadline)")
);
console.log("\nCANCEL_TYPE_HASH:", cancelTypeHash);

// Cancel struct hash test vector
const testOrderId = ethers.keccak256(ethers.toUtf8Bytes("test-order-id"));
const testCancelDeadline = 1800000200n;

const cancelEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
  ["bytes32", "bytes32", "uint256"],
  [cancelTypeHash, testOrderId, testCancelDeadline]
);
const cancelStructHash = ethers.keccak256(cancelEncoded);
console.log("Cancel struct hash (orderId=keccak256('test-order-id'), deadline=1800000200):", cancelStructHash);
console.log("  testOrderId:", testOrderId);
