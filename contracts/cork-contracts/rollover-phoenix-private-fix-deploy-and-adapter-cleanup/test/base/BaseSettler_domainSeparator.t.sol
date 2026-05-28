// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseSettlerTestBase} from "test/base/BaseSettlerTestBase.sol";
import {MockBaseSettler} from "test/base/MockBaseSettler.sol";

contract BaseSettler_domainSeparator is BaseSettlerTestBase {
    function test_domainSeparator_computesEIP712DomainOverSettlerAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CorkRolloverSettler"),
                keccak256("1"),
                block.chainid,
                address(mockSettler)
            )
        );
        assertEq(mockSettler.domainSeparator(), expected);
    }

    function test_domainSeparator_bindsChainIdAtDeployTime() public {
        bytes32 original = mockSettler.domainSeparator();

        // Fork to a different chainId — the cached separator should still be returned
        // when chainId matches deploy-time. On a different chain, it recomputes.
        vm.chainId(999);

        bytes32 recomputed = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CorkRolloverSettler"),
                keccak256("1"),
                uint256(999),
                address(mockSettler)
            )
        );
        assertEq(mockSettler.domainSeparator(), recomputed);
        assertNotEq(mockSettler.domainSeparator(), original);
    }

    function test_domainSeparator_differsBetweenTwoInstances() public {
        MockBaseSettler second = new MockBaseSettler(address(factory), address(premium));
        assertNotEq(mockSettler.domainSeparator(), second.domainSeparator());
    }
}
