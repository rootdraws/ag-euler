// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved (phoenix source had no SPDX marker;
// inheriting the repo's default per phoenix/LICENSE). Only used in tests — not shipped as part of
// the deployed contracts.
//
// Significant deviation from the phoenix source: the original `BaseTest` deploys the full phoenix
// stack in `setUp()` (WhitelistManager, DefaultCorkController, ConstraintRateAdapter,
// CorkPoolManagerMock, SharesFactory, MockBundler3, CorkAdapter). Settler tests don't need any of
// those — settlers only interact with cellar's factory, modules, and the ERC6909Premium contract.
// Instead of forking the whole phoenix dependency graph (whose types collide with our own
// `@openzeppelin/contracts` because phoenix pins a different OZ version), this fork keeps only the
// named-actor scaffolding that `BaseTestCorkCellar` and downstream settler tests rely on:
// `bravo`, `alice`, `bob`, `charlie`, `eve`, `pauser`, `unpauser`, `overridenAddress`, plus the
// `overridePrank` / `revertPrank` helpers. If a future settler test needs the real pool manager
// (to drive rollover execution end-to-end), expand this fork at that time — for PR 4a–4d the
// test-spec leaves pool-manager interaction out of scope (it's covered via `CorkPoolManagerMock`
// attached to `RolloverModule` at deploy time, which the settler never calls directly).
/// @dev Forked from phoenix@40d9b17/test/forge/BaseTest.sol. Re-sync on lib/cellar bumps that
///      classify as rollover-affecting (see plan/implementation-plan.md → Mid-plan submodule bump
///      procedure).

import {Test} from "forge-std/Test.sol";

abstract contract BaseTest is Test {
    address internal CORK_PROTOCOL_TREASURY = address(789);
    // by default, all admin privileges are held by this address
    address internal bravo = address(90);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal eve = makeAddr("eve");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal whitelistAdder = makeAddr("whitelistAdder");
    address internal whitelistRemover = makeAddr("whitelistRemover");
    address internal overridenAddress;
    address internal ensOwner = bob;

    uint256 internal snapshotId;

    function setUp() public virtual {
        // Start a prank as `bravo` so `BaseTestCorkCellar.setUp()` can call `vm.stopPrank()` as
        // the original phoenix `BaseTest.setUp()` does (its last statement is
        // `vm.startPrank(bravo)`). This keeps the cellar-side ordering identical.
        vm.startPrank(bravo);
        _labelActors();
    }

    function _labelActors() internal {
        vm.label(bravo, "bravo");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(charlie, "charlie");
        vm.label(eve, "eve");
        vm.label(pauser, "pauser");
        vm.label(unpauser, "unpauser");
        vm.label(whitelistAdder, "Whitelist Adder");
        vm.label(whitelistRemover, "Whitelist Remover");
        vm.label(CORK_PROTOCOL_TREASURY, "Cork Protocol Treasury");
    }

    // modifier has two "_" so that we can still declare an internal function on the helper using one "_"
    modifier __as(address _actor) {
        overridePrank(_actor);
        _;
    }

    function overridePrank(address _actor) public {
        address _currentCaller = currentCaller();
        overridenAddress = _currentCaller;
        vm.startPrank(_actor);
    }

    function revertPrank() public {
        vm.stopPrank();
        vm.startPrank(overridenAddress);

        overridenAddress = address(0);
    }

    function currentCaller() internal returns (address _currentCaller) {
        (, _currentCaller,) = vm.readCallers();
    }

    function snapshotState() internal {
        snapshotId = vm.snapshotState();
    }

    function revertState() internal {
        vm.revertToState(snapshotId);
    }
}
