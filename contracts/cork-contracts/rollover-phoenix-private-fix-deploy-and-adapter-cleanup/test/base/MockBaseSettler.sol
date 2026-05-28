// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseSettler} from "contracts/settlers/BaseSettler.sol";
import {CellarIntent} from "cellar/ICorkCellar.sol";

/// @title MockBaseSettler
/// @notice Minimal concrete extension of BaseSettler that exposes internal primitives for testing.
contract MockBaseSettler is BaseSettler {
    constructor(address factory_, address erc6909Premium_) BaseSettler(factory_, erc6909Premium_) {}

    function exposed_recover(bytes32 digest, address user_, bytes calldata signature) external view {
        _recover(digest, user_, signature);
    }

    function exposed_forwardToFactory(
        address cellar,
        bytes32 orderDigest,
        uint8 phase,
        CellarIntent calldata intent,
        bytes calldata cellarSig,
        uint256 fillAmount,
        address filler
    ) external returns (uint256) {
        return _forwardToFactory(cellar, orderDigest, phase, intent, cellarSig, fillAmount, filler);
    }

    function exposed_settlePremium(
        uint256 tokenId,
        uint256 amount,
        address debitFrom,
        address premiumFiller,
        address cellar
    ) external {
        _settlePremium(tokenId, amount, debitFrom, premiumFiller, cellar);
    }

    function exposed_domainSeparator() external view returns (bytes32) {
        return domainSeparator();
    }
}
