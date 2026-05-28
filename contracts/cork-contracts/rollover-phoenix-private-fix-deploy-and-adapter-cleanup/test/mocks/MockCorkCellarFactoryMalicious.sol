// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CellarIntent, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";

/// @title MockCorkCellarFactoryMalicious
/// @notice Configurable mock that decouples `actualRolled` return value from the tokens actually
///         transferred. Allows testing the DisproportionateOutput guard by returning a high
///         `actualRolled` while minting fewer dst tokens to the settler.
contract MockCorkCellarFactoryMalicious {
    address public srcToken;
    address public dstToken;

    uint256 public nextActualRolled;
    uint256 public nextDstDelta;
    uint256 public nextSrcLeftover;

    mapping(address => address) public cellars;
    mapping(bytes32 => uint256) public hookNoncesMap;

    address public settler_;

    function setTokens(address src, address dst) external {
        srcToken = src;
        dstToken = dst;
    }

    function setResponse(uint256 actualRolled_, uint256 dstDelta_, uint256 srcLeftover_) external {
        nextActualRolled = actualRolled_;
        nextDstDelta = dstDelta_;
        nextSrcLeftover = srcLeftover_;
    }

    function setCellar(address owner, address cellar) external {
        cellars[owner] = cellar;
    }

    function cellarOf(address owner) external view returns (address) {
        return cellars[owner];
    }

    function setOriginatingSettler(address settler) external {
        settler_ = settler;
    }

    function setHookNonces(bytes32 orderDigest, uint256 nonce) external {
        hookNoncesMap[orderDigest] = nonce;
    }

    function executeIntentHooks(address, bytes32, uint8 phase, CellarIntent calldata, bytes calldata, uint256, address)
        external
        returns (uint256)
    {
        if (phase == 0) {
            if (nextDstDelta > 0) {
                ERC20Mock(payable(dstToken)).mint(msg.sender, nextDstDelta);
            }
            if (nextSrcLeftover > 0) {
                ERC20Mock(payable(srcToken)).mint(msg.sender, nextSrcLeftover);
            }
        }
        return nextActualRolled;
    }

    function validateModuleForForwarding(address) external pure {}

    function originatingSettler() external view returns (address) {
        return settler_;
    }

    function hookNonces(bytes32 orderDigest) external view returns (uint256) {
        return hookNoncesMap[orderDigest];
    }

    function rolled(bytes32) external pure returns (uint256) {
        return 0;
    }
}
