// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployFillers} from "script/foundry-scripts/DeployFillers.s.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";

/// @dev Test-only subclass that exposes the internal `_resolveSettler` so each branch can be
///      exercised with explicit, per-test inputs. Using env vars here is fragile: forge tests
///      share a single process env, so `vm.setEnv` in one test bleeds into sibling tests and
///      makes branch coverage order-dependent (P26-G2 is about coverage, not env plumbing).
contract DeployFillersHarness is DeployFillers {
    function exposeResolveSettler(string memory envKey, string memory jsonKeyPrefix, bool isPartial)
        external
        view
        returns (address)
    {
        return _resolveSettler(envKey, jsonKeyPrefix, isPartial);
    }
}

/// @notice Unit tests for `DeployFillers.s.sol`. Covers each settler-resolution path and the
///         zero-address guard (P26-A1) the env + networks.json branches share.
/// @dev The RolloverFiller constructor reads two selectors on the Partial settler — `factory()`
///      and `totalDstCstEscrowed(bytes32)` — and calls `totalDstCstEscrowed(bytes32)` on the
///      Exact settler as a negative-shape probe. `setUp` installs both mocks on the fake
///      addresses so construction succeeds whenever either filler ends up built; individual
///      tests override env state or network-file state to exercise the resolver's branches.
contract DeployFillersTest is Test {
    address internal constant FAKE_EXACT = address(0xE1E1);
    address internal constant FAKE_PARTIAL = address(0xBABE);
    address internal constant FAKE_FACTORY = address(0xF0F0);
    address internal constant FAKE_ERC6909 = address(0x6909);

    DeployFillersHarness internal harness;

    function setUp() public {
        harness = new DeployFillersHarness();

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
        // RolloverFiller constructor caches `settler.erc6909Premium()` (A2 caller-side auth).
        // Both fake settlers must answer the selector so construction succeeds.
        vm.mockCall(FAKE_EXACT, abi.encodeWithSignature("erc6909Premium()"), abi.encode(FAKE_ERC6909));
        vm.mockCall(FAKE_PARTIAL, abi.encodeWithSignature("erc6909Premium()"), abi.encode(FAKE_ERC6909));
    }

    // ═══════════════════════════════════════════════════════════════
    //  End-to-end env override happy path (single-env-write only)
    // ═══════════════════════════════════════════════════════════════

    /// @dev This is the only test that uses the env-var path end-to-end via `run()`. Forge tests
    ///      share process env and `setEnv` writes leak across tests — so branch coverage of the
    ///      env / JSON / zero paths is exercised via `DeployFillersHarness.exposeResolveSettler`
    ///      below instead of multiple env-based tests.
    function test_run_EnvOverrideWiringAssertsPass_Exact() public {
        vm.setEnv("EXACT_SETTLER_OVERRIDE", vm.toString(FAKE_EXACT));
        vm.setEnv("PARTIAL_SETTLER_OVERRIDE", vm.toString(FAKE_PARTIAL));

        DeployFillers deployer = new DeployFillers();
        (address exactFiller, address partialFiller) = deployer.run();

        assertEq(ExactRolloverFiller(exactFiller).SETTLER(), FAKE_EXACT, "exact settler");

        assertEq(PartialRolloverFiller(partialFiller).SETTLER(), FAKE_PARTIAL, "partial settler");
        assertEq(PartialRolloverFiller(partialFiller).FACTORY(), FAKE_FACTORY, "partial factory");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zero-address guard (P26-A1) — via harness
    // ═══════════════════════════════════════════════════════════════

    /// @dev `EXACT_SETTLER_OVERRIDE=0x0000...` must not silently resolve to a live target.
    ///      The guard inside `_resolveSettler` short-circuits on `override_ == address(0)` and
    ///      reverts with `DeployFillers__SettlerNotResolved`.
    function test_resolve_RevertsOnZeroEnvOverride() public {
        string memory key = "DEPLOY_FILLERS_TEST_ZERO_ENV";
        vm.setEnv(key, vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployFillers.DeployFillers__SettlerNotResolved.selector, false));
        harness.exposeResolveSettler(key, ".ExactFillSettler.", false);
    }

    /// @dev Symmetric guard for the Partial role — the `isPartial` flag is forwarded to the error.
    function test_resolve_RevertsOnZeroEnvOverride_PartialRole() public {
        string memory key = "DEPLOY_FILLERS_TEST_ZERO_ENV_PARTIAL";
        vm.setEnv(key, vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployFillers.DeployFillers__SettlerNotResolved.selector, true));
        harness.exposeResolveSettler(key, ".PartialFillSettler.", true);
    }

    /// @dev With no env var set for a unique key and no networks.json, the resolver falls through
    ///      to the terminal revert. The uncommon key guarantees this test is independent of other
    ///      tests' setEnv calls.
    function test_resolve_RevertsWhenBothMissing() public {
        string memory key = "DEPLOY_FILLERS_TEST_UNSET_UNIQUE_KEY_0xdeadbeef";
        vm.expectRevert(abi.encodeWithSelector(DeployFillers.DeployFillers__SettlerNotResolved.selector, false));
        harness.exposeResolveSettler(key, ".ExactFillSettler.", false);
    }

    // ═══════════════════════════════════════════════════════════════
    //  networks.json path (P26-G2) — via harness
    // ═══════════════════════════════════════════════════════════════

    /// @dev Exercises BOTH the success and zero-address branches of the networks.json read in one
    ///      test, because forge may parallelise tests within a file and they would both write to
    ///      the same hardcoded `networks.json` filename. Sequencing both branches serially here
    ///      guarantees no filename collision while still proving each branch's behavior.
    function test_resolve_NetworksJsonBranches() public {
        string memory chainId = vm.toString(block.chainid);
        string memory key = "DEPLOY_FILLERS_TEST_UNSET_FOR_JSON_0xbeefcafe";

        // Branch 1: valid address under the correct key resolves.
        string memory goodJson =
            string.concat("{", '"ExactFillSettler":{"', chainId, '":{"address":"', vm.toString(FAKE_EXACT), '"}}', "}");
        vm.writeFile("networks.json", goodJson);
        address resolved;
        try harness.exposeResolveSettler(key, ".ExactFillSettler.", false) returns (address r) {
            resolved = r;
        } catch (bytes memory reason) {
            vm.removeFile("networks.json");
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        assertEq(resolved, FAKE_EXACT, "valid networks.json address resolves");

        // Branch 2: overwrite with a zero-address entry — the guard trips.
        string memory zeroJson =
            string.concat("{", '"ExactFillSettler":{"', chainId, '":{"address":"', vm.toString(address(0)), '"}}', "}");
        vm.writeFile("networks.json", zeroJson);
        try harness.exposeResolveSettler(key, ".ExactFillSettler.", false) {
            vm.removeFile("networks.json");
            fail();
        } catch (bytes memory reason) {
            vm.removeFile("networks.json");
            assertEq(
                bytes4(reason),
                DeployFillers.DeployFillers__SettlerNotResolved.selector,
                "zero-in-json must hit SettlerNotResolved"
            );
        }
    }
}
