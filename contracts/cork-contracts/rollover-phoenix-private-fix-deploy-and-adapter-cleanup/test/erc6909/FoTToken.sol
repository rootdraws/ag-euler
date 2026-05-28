// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FoTToken
/// @notice Minimal fee-on-transfer ERC20 used by the §39 delta-accounting tests: BOTH
///         `transfer` and `transferFrom` burn a configurable fee from the forwarded amount so
///         the recipient receives strictly less than `amount`. Covers the deposit-side
///         (`transferFrom`) and settle-side (`transfer`) FoT mismatch paths uniformly.
///         Any caller may mint and tune the fee — this is test-only.
contract FoTToken is ERC20 {
    uint256 public feeBps;

    constructor() ERC20("FoTToken", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev `feeBps` is in basis points (1/10_000). A fee of 0 restores standard ERC20 behaviour.
    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;
        _transfer(msg.sender, to, net);
        if (fee > 0) {
            _burn(msg.sender, fee);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;
        _transfer(from, to, net);
        if (fee > 0) {
            _burn(from, fee);
        }
        return true;
    }
}
