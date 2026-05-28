// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BaseSettlerTestBase} from "test/base/BaseSettlerTestBase.sol";
import {MockBaseSettler} from "test/base/MockBaseSettler.sol";
import {InvalidSignature} from "contracts/interfaces/RolloverTypes.sol";

contract RevertingWallet {
    fallback() external {
        revert("boom");
    }
}

contract WrongMagicWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

contract SelfDestructWallet {
    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        selfdestruct(payable(msg.sender));
        return bytes4(0x1626ba7e);
    }
}

contract BaseSettler_recover is BaseSettlerTestBase {
    bytes32 internal digest;
    bytes32 internal eip712Hash;

    function setUp() public override {
        super.setUp();
        digest = keccak256("test-digest");
        eip712Hash = keccak256(abi.encodePacked("\x19\x01", mockSettler.domainSeparator(), digest));
    }

    function test_recover_emptySignature_revertsInvalidSignature() public {
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, "");
    }

    function test_recover_ecdsa65_validSigner_succeeds() public view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        mockSettler.exposed_recover(digest, user.addr, abi.encodePacked(r, s, v));
    }

    function test_recover_ecdsa65_wrongSigner_revertsInvalidSignature() public {
        Vm.Wallet memory other = vm.createWallet("other");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(other.privateKey, eip712Hash);
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, abi.encodePacked(r, s, v));
    }

    // OZ ECDSA.tryRecover only supports 65-byte sigs; 64-byte EIP-2098 compact is rejected
    // as InvalidSignatureLength. This test confirms that behavior.
    function test_recover_eip2098Compact_revertsInvalidSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        bytes32 vs;
        if (v == 28) {
            vs = s | bytes32(uint256(1) << 255);
        } else {
            vs = s;
        }
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, abi.encodePacked(r, vs));
    }

    function test_recover_malleableS_revertsInvalidSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, abi.encodePacked(r, flippedS, flippedV));
    }

    function test_recover_invalidLength_revertsInvalidSignature() public {
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, hex"aabbccdd");
    }

    function test_recover_smartWallet_validMagic_succeeds() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, eip712Hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user.addr);
        smartWallet.sign(eip712Hash, sig);

        mockSettler.exposed_recover(digest, smartWalletAddr, sig);
    }

    function test_recover_smartWallet_wrongMagic_revertsInvalidSignature() public {
        WrongMagicWallet w = new WrongMagicWallet();
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, address(w), hex"aa");
    }

    function test_recover_smartWallet_reverts_revertsInvalidSignature() public {
        RevertingWallet w = new RevertingWallet();
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, address(w), hex"aa");
    }

    function test_recover_smartWallet_selfdestructs_revertsInvalidSignature() public {
        SelfDestructWallet w = new SelfDestructWallet();
        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, address(w), hex"aa");
    }

    function test_recover_crossSettlerDomain_revertsInvalidSignature() public {
        MockBaseSettler otherSettler = new MockBaseSettler(address(factory), address(premium));
        bytes32 otherEip712Hash = keccak256(abi.encodePacked("\x19\x01", otherSettler.domainSeparator(), digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, otherEip712Hash);

        vm.expectRevert(InvalidSignature.selector);
        mockSettler.exposed_recover(digest, user.addr, abi.encodePacked(r, s, v));
    }
}
