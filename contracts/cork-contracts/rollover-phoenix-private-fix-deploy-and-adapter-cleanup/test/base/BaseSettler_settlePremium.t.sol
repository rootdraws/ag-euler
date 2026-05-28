// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseSettlerTestBase} from "test/base/BaseSettlerTestBase.sol";
import {MockERC20} from "test/erc6909/MockERC20.sol";
import {IERC6909Premium} from "contracts/interfaces/IERC6909Premium.sol";

contract BaseSettler_settlePremium is BaseSettlerTestBase {
    address internal filler;
    address internal cellar;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        filler = address(0xF111);
        cellar = factory.cellarOf(user.addr);
        tokenId = uint256(uint160(address(vaultUnderlying)));
    }

    function test_settlePremium_zeroAmount_noop() public {
        uint256 erc6909Before = premium.balanceOf(address(mockSettler), tokenId);
        uint256 erc20Before = IERC20(address(vaultUnderlying)).balanceOf(cellar);

        mockSettler.exposed_settlePremium(tokenId, 0, address(mockSettler), address(mockSettler), cellar);

        assertEq(premium.balanceOf(address(mockSettler), tokenId), erc6909Before, "6909 balance moved on zero");
        assertEq(IERC20(address(vaultUnderlying)).balanceOf(cellar), erc20Before, "cellar balance moved on zero");
    }

    function test_settlePremium_sufficientBalanceAndDualAuth_debitsAndTransfers() public {
        uint256 amount = 100e18;
        _depositPremiumForSettler(filler, address(vaultUnderlying), amount);

        vm.prank(filler);
        premium.setOperator(address(mockSettler), true);
        vm.prank(filler);
        premium.setOperator(filler, true);

        uint256 balBefore = IERC20(address(vaultUnderlying)).balanceOf(cellar);
        mockSettler.exposed_settlePremium(tokenId, amount, filler, filler, cellar);
        uint256 balAfter = IERC20(address(vaultUnderlying)).balanceOf(cellar);

        assertEq(balAfter - balBefore, amount);
        assertEq(premium.balanceOf(filler, tokenId), 0);
    }

    function test_settlePremium_insufficientBalance_reverts() public {
        _depositPremiumForSettler(filler, address(vaultUnderlying), 50e18);

        vm.prank(filler);
        premium.setOperator(address(mockSettler), true);

        vm.expectRevert(IERC6909Premium.InsufficientBalance.selector);
        mockSettler.exposed_settlePremium(tokenId, 100e18, filler, filler, cellar);
    }

    function test_settlePremium_unauthorizedSettler_reverts() public {
        _depositPremiumForSettler(filler, address(vaultUnderlying), 100e18);

        vm.expectRevert(IERC6909Premium.UnauthorizedSettler.selector);
        mockSettler.exposed_settlePremium(tokenId, 100e18, filler, filler, cellar);
    }

    function test_settlePremium_unauthorizedPremiumFiller_reverts() public {
        _depositPremiumForSettler(filler, address(vaultUnderlying), 100e18);

        vm.prank(filler);
        premium.setOperator(address(mockSettler), true);

        address unauthorizedFiller = address(0xBAD);
        vm.expectRevert(IERC6909Premium.UnauthorizedPremiumFiller.selector);
        mockSettler.exposed_settlePremium(tokenId, 100e18, filler, unauthorizedFiller, cellar);
    }

    function test_settlePremium_transferRevert_bubblesAndLeavesBalanceUnchanged() public {
        MockERC20 badToken = new MockERC20();
        uint256 badTokenId = uint256(uint160(address(badToken)));
        uint256 amount = 100e18;

        badToken.mint(filler, amount);
        vm.startPrank(filler);
        badToken.approve(address(premium), amount);
        premium.deposit(address(badToken), filler, amount);
        premium.setOperator(address(mockSettler), true);
        vm.stopPrank();

        badToken.setRevertOnTransfer(true);

        uint256 balBefore = premium.balanceOf(filler, badTokenId);
        // Bare expectRevert: revert originates from mock ERC20 (RevertOnTransferToken),
        // selector is implementation-dependent.
        vm.expectRevert();
        mockSettler.exposed_settlePremium(badTokenId, amount, filler, filler, cellar);
        assertEq(premium.balanceOf(filler, badTokenId), balBefore);
    }

    function _depositPremiumForSettler(address to, address token, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint failed");
        vm.startPrank(to);
        IERC20(token).approve(address(premium), amount);
        premium.deposit(token, to, amount);
        vm.stopPrank();
    }
}
