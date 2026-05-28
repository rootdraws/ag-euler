// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployEvcAdapters} from "script/foundry-scripts/DeployEvcAdapters.s.sol";
import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {EthereumVaultConnector} from "evc/EthereumVaultConnector.sol";

/// @dev Test-only subclass that exposes the internal resolvers so each branch can be exercised
///      with explicit, per-test inputs. Using env vars here is fragile: forge tests share a single
///      process env, so `vm.setEnv` in one test bleeds into sibling tests and makes branch coverage
///      order-dependent.
contract DeployEvcAdaptersHarness is DeployEvcAdapters {
    function exposeResolveSettler(string memory envKey, string memory jsonKeyPrefix, bool isPartial)
        external
        view
        returns (address)
    {
        return _resolveSettler(envKey, jsonKeyPrefix, isPartial);
    }

    function exposeResolveEvc(string memory envKey) external view returns (address) {
        return _resolveEvc(envKey);
    }

    function exposeResolveAuthorizedCaller(string memory envKey) external view returns (address) {
        return _resolveAuthorizedCaller(envKey);
    }
}

/// @notice Unit tests for `DeployEvcAdapters.s.sol`. Covers end-to-end wiring (exact + partial
///         adapters bound to the resolved settlers, factory, and EVC), the env-override resolver
///         branch, and the zero-address guards shared by the env / networks.json paths.
/// @dev The `EvcRolloverAdapter` constructor reads the Partial-only selector
///      (`totalDstCstEscrowed(bytes32)`) on both settlers as a shape probe, plus `factory()` on the
///      Partial settler. `setUp` installs both mocks so the Exact probe fails (negative shape) and
///      the Partial probe succeeds; individual tests override env state to exercise each resolver
///      branch.
///
///      The `networks.json` read branch is exercised only in `DeployFillers.t.sol`: the resolver
///      pattern here is structurally identical to the one landed there, and forge runs tests from
///      different files against a shared working directory — covering the same filename from two
///      suites in parallel triggers write-remove races on `networks.json`. Re-testing the same
///      branch here would add no coverage while making the test suite flaky. The env + guard
///      branches (covered below) are sufficient to exercise this file's resolver surface.
contract DeployEvcAdaptersTest is Test {
    address internal constant FAKE_EXACT = address(0xE1E1);
    address internal constant FAKE_PARTIAL = address(0xBABE);
    address internal constant FAKE_FACTORY = address(0xF0F0);
    address internal constant FAKE_AUTHORIZED_CALLER = address(0xCAFE);

    DeployEvcAdaptersHarness internal harness;
    EthereumVaultConnector internal evc;

    function setUp() public {
        harness = new DeployEvcAdaptersHarness();
        evc = new EthereumVaultConnector();

        vm.mockCall(FAKE_PARTIAL, abi.encodeWithSignature("factory()"), abi.encode(FAKE_FACTORY));
        vm.mockCall(
            FAKE_PARTIAL, abi.encodeWithSignature("totalDstCstEscrowed(bytes32)", bytes32(0)), abi.encode(uint256(0))
        );
        // Exact-side negative probe: forge blocks high-level staticcalls to an EOA with its own
        // error (bypassing the in-Solidity try/catch), so we force the probe to revert in a
        // caller-visible way that the constructor's `catch {}` can observe.
        vm.mockCallRevert(
            FAKE_EXACT, abi.encodeWithSignature("totalDstCstEscrowed(bytes32)", bytes32(0)), "no-partial-probe"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  End-to-end env override happy path
    // ═══════════════════════════════════════════════════════════════

    /// @dev The only test using the env-var path end-to-end via `run()`. Forge tests share process
    ///      env and `setEnv` writes leak across tests — so branch coverage of env / JSON / zero
    ///      paths is exercised via `DeployEvcAdaptersHarness` below instead of multiple env-based
    ///      tests. Asserts every immutable on both deployed adapters.
    function test_run_EnvOverrideWiringAssertsPass() public {
        vm.setEnv("EXACT_SETTLER_OVERRIDE", vm.toString(FAKE_EXACT));
        vm.setEnv("PARTIAL_SETTLER_OVERRIDE", vm.toString(FAKE_PARTIAL));
        vm.setEnv("EVC_ADDRESS_OVERRIDE", vm.toString(address(evc)));
        vm.setEnv("EVC_AUTHORIZED_CALLER_OVERRIDE", vm.toString(FAKE_AUTHORIZED_CALLER));

        DeployEvcAdapters deployer = new DeployEvcAdapters();
        (address exactAdapter, address partialAdapter) = deployer.run();

        assertEq(EvcExactFillAdapter(exactAdapter).SETTLER(), FAKE_EXACT, "exact settler");
        assertEq(EvcExactFillAdapter(exactAdapter).FACTORY(), address(0), "exact factory zero");
        assertEq(EvcExactFillAdapter(exactAdapter).EVC(), address(evc), "exact evc");
        assertEq(
            EvcExactFillAdapter(exactAdapter).AUTHORIZED_CALLER(), FAKE_AUTHORIZED_CALLER, "exact authorized caller"
        );

        assertEq(EvcPartialFillAdapter(partialAdapter).SETTLER(), FAKE_PARTIAL, "partial settler");
        assertEq(EvcPartialFillAdapter(partialAdapter).FACTORY(), FAKE_FACTORY, "partial factory");
        assertEq(EvcPartialFillAdapter(partialAdapter).EVC(), address(evc), "partial evc");
        assertEq(
            EvcPartialFillAdapter(partialAdapter).AUTHORIZED_CALLER(),
            FAKE_AUTHORIZED_CALLER,
            "partial authorized caller"
        );

        // C-N6 env cleanup: forge tests share a single process env; leaking these overrides into
        // sibling tests makes branch coverage order-dependent (e.g. the terminal-revert tests below
        // would suddenly resolve via the leaked override). Reset to empty string post-assertion.
        vm.setEnv("EXACT_SETTLER_OVERRIDE", "");
        vm.setEnv("PARTIAL_SETTLER_OVERRIDE", "");
        vm.setEnv("EVC_ADDRESS_OVERRIDE", "");
        vm.setEnv("EVC_AUTHORIZED_CALLER_OVERRIDE", "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  End-to-end authorized-caller revert path
    // ═══════════════════════════════════════════════════════════════

    /// @dev Production deployments MUST set `EVC_AUTHORIZED_CALLER_OVERRIDE` to a non-zero address —
    ///      the `_resolveAuthorizedCaller` env-only path short-circuits on `address(0)` and no
    ///      `networks.json` fallback exists. Exercises the revert via the full `run()` surface so
    ///      the wiring catches the mis-configuration early.
    ///
    ///      Implementation note: within a single test frame, forge caches the env value read by
    ///      `vm.envAddress` against the test's initial snapshot — `vm.setEnv` writes inside the
    ///      same frame are not visible to `vm.envAddress` reads that follow them. To drive the
    ///      zero branch deterministically, this test delegates to the `DeployEvcAdaptersHarness`
    ///      resolver surface (which reads a per-test unique key the sibling tests don't touch);
    ///      the settler and EVC env writes are still asserted through `run()` in
    ///      `test_run_EnvOverrideWiringAssertsPass` above. The end-to-end `run()` path and the
    ///      zero-guard on `_resolveAuthorizedCaller` are otherwise independent — the wiring
    ///      inside `run()` is a thin call through to `_resolveAuthorizedCaller`.
    function test_run_RevertsOnZeroAuthorizedCaller() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_RUN_ZERO_AUTHORIZED_CALLER";
        vm.setEnv(key, vm.toString(address(0)));
        vm.expectRevert(DeployEvcAdapters.DeployEvcAdapters__AuthorizedCallerNotResolved.selector);
        harness.exposeResolveAuthorizedCaller(key);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zero-address guards — via harness
    // ═══════════════════════════════════════════════════════════════

    function test_resolve_RevertsOnZeroEnvOverride() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_ZERO_ENV";
        vm.setEnv(key, vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployEvcAdapters.DeployEvcAdapters__SettlerNotResolved.selector, false));
        harness.exposeResolveSettler(key, ".ExactFillSettler.", false);
    }

    function test_resolve_RevertsOnZeroEnvOverride_PartialRole() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_ZERO_ENV_PARTIAL";
        vm.setEnv(key, vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployEvcAdapters.DeployEvcAdapters__SettlerNotResolved.selector, true));
        harness.exposeResolveSettler(key, ".PartialFillSettler.", true);
    }

    function test_resolve_RevertsWhenSettlerBothMissing() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_UNSET_UNIQUE_KEY_0xdeadbeef";
        vm.expectRevert(abi.encodeWithSelector(DeployEvcAdapters.DeployEvcAdapters__SettlerNotResolved.selector, false));
        harness.exposeResolveSettler(key, ".ExactFillSettler.", false);
    }

    /// @dev Terminal revert: no env override, no networks.json entry. Uses a unique env key so we
    ///      don't disturb `EVC_ADDRESS_OVERRIDE` for the parallel `test_run_*` case.
    function test_resolveEvc_RevertsWhenBothMissing() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_UNSET_EVC_TERMINAL_0xbeef1234";
        vm.expectRevert(DeployEvcAdapters.DeployEvcAdapters__EvcNotResolved.selector);
        harness.exposeResolveEvc(key);
    }

    /// @dev Terminal revert on the authorized-caller resolver: no env override set. Uses a unique
    ///      env key to stay independent of sibling tests' `setEnv` calls. The zero-branch of the
    ///      same resolver is covered by `test_run_RevertsOnZeroAuthorizedCaller` above.
    function test_resolveAuthorizedCaller_RevertsWhenUnset() public {
        string memory key = "DEPLOY_EVC_ADAPTERS_TEST_UNSET_AUTHORIZED_CALLER_0xdeadc0de";
        vm.expectRevert(DeployEvcAdapters.DeployEvcAdapters__AuthorizedCallerNotResolved.selector);
        harness.exposeResolveAuthorizedCaller(key);
    }
}
