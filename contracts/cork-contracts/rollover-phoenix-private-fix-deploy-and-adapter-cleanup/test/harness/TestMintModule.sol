// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";

/// @notice Delegatecall-compatible test module that reads fillAmount from CorkCellar's transient
///         storage and mints dstCST to the settler. Used in integration tests as a substitute for
///         RolloverModule (which requires a real PoolManager).
contract TestMintModule {
    bytes32 internal constant FILL_AMOUNT_SLOT = bytes32(uint256(keccak256("CorkCellar.fillAmount")) - 1);

    /// @param dstCstToken The destination CST token (DummyERC20) to mint.
    /// @param settler The settler address that receives the minted tokens.
    function execute(address dstCstToken, address settler) external {
        uint256 fillAmount;
        bytes32 slot = FILL_AMOUNT_SLOT;
        assembly {
            fillAmount := tload(slot)
        }
        ERC20Mock(payable(dstCstToken)).mint(settler, fillAmount);
    }
}

/// @notice Delegatecall-compatible test module that always reverts. Used in INT-13 to test that
///         premium hook reverts roll back the entire fill atomically.
contract RevertModule {
    error ForcedRevert();

    function execute() external pure {
        revert ForcedRevert();
    }
}

/// @notice Delegatecall-compatible test module that reverts iff `(block.number & 1) == parity`.
///         Hard-wired so a UW's signed premiumHooks can mimic conditional reverts without adding
///         any storage writes (modules are delegatecalled — storage reads land on the cellar).
contract ConditionalRevertModule {
    error ConditionalForcedRevert();

    uint256 public immutable parity;

    constructor(uint256 parity_) {
        parity = parity_;
    }

    function execute() external view {
        if ((block.number & 1) == parity) {
            revert ConditionalForcedRevert();
        }
    }
}
