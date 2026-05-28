// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @notice ERC6909-specific invariant handler for premium balance conservation.
contract ERC6909PremiumInvariantHandler is Test {
    uint256 internal constant ACTOR_COUNT = 4;

    ERC6909Premium public premium;
    DummyERC20 public token;
    uint256 public tokenId;

    address[] public actors;
    address public mockSettler;

    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdraws;
    uint256 public ghost_totalSettles;
    uint256 public ghost_settleCallCount;
    uint256 public ghost_settleRevertCount;
    uint256 public ghost_unauthorizedSettleAttempts;
    uint256 public ghost_unauthorizedSettleReverts;
    mapping(address => uint256) public ghost_balances;
    mapping(address => mapping(address => bool)) public ghost_operators;

    constructor() {
        premium = new ERC6909Premium();
        token = new DummyERC20("PremToken", "PREM", 18);
        tokenId = uint256(uint160(address(token)));

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = vm.createWallet(string(abi.encodePacked("erc6909actor", i))).addr;
            actors.push(actor);
        }
        mockSettler = actors[0];
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorCount() external pure returns (uint256) {
        return ACTOR_COUNT;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Handler actions
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, 10_000e18);
        address actor = _selectActor(actorSeed);

        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(premium), amount);
        premium.deposit(address(token), actor, amount);
        vm.stopPrank();

        ghost_totalDeposits += amount;
        ghost_balances[actor] += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _selectActor(actorSeed);
        uint256 bal = ghost_balances[actor];
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try premium.withdraw(tokenId, actor, amount) {
            ghost_totalWithdraws += amount;
            ghost_balances[actor] -= amount;
        } catch {}
    }

    function settle(uint256 debitSeed, uint256 fillerSeed, uint256 amount) external {
        address debitFrom = _selectActor(debitSeed);
        address filler = _selectActor(fillerSeed);
        uint256 bal = ghost_balances[debitFrom];
        if (bal == 0) return;
        amount = bound(amount, 0, bal);

        bool callerAuth = mockSettler == debitFrom || ghost_operators[debitFrom][mockSettler];
        bool fillerAuth = filler == debitFrom || ghost_operators[debitFrom][filler];
        if (!callerAuth || !fillerAuth) return;

        address recipient = actors[1];
        uint256 balBefore = premium.balanceOf(debitFrom, tokenId);

        vm.prank(mockSettler);
        try premium.settle(debitFrom, filler, tokenId, amount, recipient) {
            ghost_totalSettles += amount;
            ghost_balances[debitFrom] -= amount;
            ghost_settleCallCount += 1;
        } catch {
            ghost_settleRevertCount += 1;
            uint256 balAfter = premium.balanceOf(debitFrom, tokenId);
            assertEq(balAfter, balBefore);
        }
    }

    function setOperator(uint256 ownerSeed, uint256 operatorSeed) external {
        address owner = _selectActor(ownerSeed);
        address operator = _selectActor(operatorSeed);
        if (owner == operator) return;

        vm.prank(owner);
        premium.setOperator(operator, true);
        ghost_operators[owner][operator] = true;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _selectActor(fromSeed);
        address to = _selectActor(toSeed);
        if (from == to) return;

        uint256 bal = ghost_balances[from];
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        try premium.withdraw(tokenId, from, amount) {
            ghost_totalWithdraws += amount;
            ghost_balances[from] -= amount;

            token.mint(from, amount);
            vm.startPrank(from);
            token.approve(address(premium), amount);
            premium.deposit(address(token), to, amount);
            vm.stopPrank();

            ghost_totalDeposits += amount;
            ghost_balances[to] += amount;
        } catch {}
    }

    function settle_unauthorized(uint256 debitSeed, uint256 callerSeed, uint256 amount) external {
        address debitFrom = _selectActor(debitSeed);
        address caller = _selectActor(callerSeed);

        bool callerAuth = caller == debitFrom || ghost_operators[debitFrom][caller];
        if (callerAuth) return;

        uint256 bal = ghost_balances[debitFrom];
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        address filler = actors[0];
        address recipient = actors[1];

        ghost_unauthorizedSettleAttempts += 1;
        vm.prank(caller);
        try premium.settle(debitFrom, filler, tokenId, amount, recipient) {}
        catch {
            ghost_unauthorizedSettleReverts += 1;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════════════════════

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }
}
