// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTestSettler} from "test/BaseTestSettler.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";

/// @title BaseTestFiller
/// @notice Test harness for Cork rollover *filler* tests. Extends `BaseTestSettler` (which already
///         deploys the registry, `CorkCellarFactory`, user / smart-wallet cellars, all modules,
///         `ERC6909Premium`, `ExactFillSettler`, and `PartialFillSettler`) and layers the two
///         canonical reference filler instances on top — one `ExactRolloverFiller` bound to the
///         exact settler, one `PartialRolloverFiller` bound to the partial settler — plus
///         filler-level convenience helpers.
/// @dev Abstract on purpose — mirrors `BaseTestSettler`. The five abstract signing/snapshot hooks
///      inherited from `BaseTestSettler` stay abstract so downstream Exact / Partial filler test
///      bases can bind them to the concrete settler's `domainSeparator()` surface.
abstract contract BaseTestFiller is BaseTestSettler {
    // ─── Filler stack ──────────────────────────────────────────────────────────────────────
    ExactRolloverFiller internal rolloverFillerExact;
    PartialRolloverFiller internal rolloverFillerPartial;

    function setUp() public virtual override {
        super.setUp();
        rolloverFillerExact = new ExactRolloverFiller(address(exactSettler), address(0));
        rolloverFillerPartial = new PartialRolloverFiller(address(partialSettler), address(factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Filler-level convenience helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Approve `filler` to pull `amount` of `token` from `actor`.
    function _approveFillerToPullSrcCst(address actor, address filler, address token, uint256 amount) internal {
        vm.prank(actor);
        IERC20(token).approve(filler, amount);
    }

    /// @notice Prepare `actor`'s on-chain preconditions for a filler `execute` call against the
    ///         Exact filler.
    function _prepareFillerState(
        address actor,
        ExactRolloverFiller filler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareFillerStateInternal(
            actor, address(filler), filler.SETTLER(), srcCstToken, srcCstAmount, premiumToken, premiumAmount
        );
    }

    /// @notice Prepare `actor`'s on-chain preconditions for a filler `execute` call against the
    ///         Partial filler.
    function _prepareFillerState(
        address actor,
        PartialRolloverFiller filler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareFillerStateInternal(
            actor, address(filler), filler.SETTLER(), srcCstToken, srcCstAmount, premiumToken, premiumAmount
        );
    }

    function _prepareFillerStateInternal(
        address actor,
        address filler,
        address boundSettler,
        address srcCstToken,
        uint256 srcCstAmount,
        address premiumToken,
        uint256 premiumAmount
    ) private {
        _depositPremium(actor, premiumToken, premiumAmount);

        vm.prank(actor);
        premium.setOperator(boundSettler, true);

        (bool ok,) = srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", actor, srcCstAmount));
        require(ok, "BaseTestFiller: srcCst mint failed");

        _approveFillerToPullSrcCst(actor, filler, srcCstToken, srcCstAmount);
    }

    /// @notice Wrapper around `ExactRolloverFiller.execute` pranked as `caller`.
    function _executeRollover(
        ExactRolloverFiller filler,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination,
        address caller
    ) internal {
        vm.prank(caller);
        filler.execute(orderData, signature, originFillerData, srcCstAmount, debitFrom, destination);
    }

    /// @notice Wrapper around `PartialRolloverFiller.execute` pranked as `caller`.
    function _executeRollover(
        PartialRolloverFiller filler,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination,
        address caller
    ) internal {
        vm.prank(caller);
        filler.execute(orderData, signature, originFillerData, srcCstAmount, debitFrom, destination);
    }

    /// @notice Post-execute invariant asserter for Exact fillers. Enforces INV-F1 (filler holds
    ///         zero of each token) and INV-F2 (filler has zero allowance to its bound settler).
    function _fillerSnapshot(ExactRolloverFiller filler, address[] memory tokens) internal view {
        _fillerSnapshotInternal(address(filler), filler.SETTLER(), tokens);
    }

    /// @notice Post-execute invariant asserter for Partial fillers.
    function _fillerSnapshot(PartialRolloverFiller filler, address[] memory tokens) internal view {
        _fillerSnapshotInternal(address(filler), filler.SETTLER(), tokens);
    }

    function _fillerSnapshotInternal(address filler, address settler_, address[] memory tokens) private view {
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(IERC20(tokens[i]).balanceOf(filler), 0, "BaseTestFiller: INV-F1 filler token balance");
            assertEq(IERC20(tokens[i]).allowance(filler, settler_), 0, "BaseTestFiller: INV-F2 filler allowance");
        }
    }
}
