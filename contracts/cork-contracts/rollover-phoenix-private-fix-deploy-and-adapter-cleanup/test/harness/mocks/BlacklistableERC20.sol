// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20, ERC20Mock} from "test/harness/mocks/ERC20Mock.sol";

/// @title BlacklistableERC20
/// @notice USDC-style mock: a blacklist mapping whose entries cause `transfer` /
///         `transferFrom` to revert whenever either the sender OR the recipient is flagged.
///         Used to exercise the blacklist-stuck-Opened branch (#39) in the settler finalise
///         payout loops. Any caller may mint or toggle the blacklist — this is test-only.
/// @dev Extends `ERC20Mock` so `TestMintModule.execute` (which calls `ERC20Mock(token).mint`)
///      can populate the settler's dstCST escrow through the standard rollover hook path.
contract BlacklistableERC20 is ERC20Mock {
    uint8 internal __decimals;

    mapping(address => bool) public blacklisted;

    error Blacklisted(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        __decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return __decimals;
    }

    function setBlacklisted(address account, bool flag) external {
        blacklisted[account] = flag;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[msg.sender]) revert Blacklisted(msg.sender);
        if (blacklisted[to]) revert Blacklisted(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        return super.transferFrom(from, to, amount);
    }
}
