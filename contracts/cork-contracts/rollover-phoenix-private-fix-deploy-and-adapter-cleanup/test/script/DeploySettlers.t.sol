// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeploySettlers} from "script/foundry-scripts/DeploySettlers.s.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";

/// @dev Test-only subclass exposing `_resolveFactoryAddress` so each branch can be driven with
///      explicit, per-test env keys. Forge tests share process env across cases, so
///      env-var-driven branch coverage on a single hardcoded key (`FACTORY_ADDRESS_OVERRIDE`)
///      would be order-dependent. The harness lets each test pick a unique key.
contract DeploySettlersHarness is DeploySettlers {
    function exposeResolveFactoryAddress(string memory envKey, string memory jsonKeyPrefix)
        external
        view
        returns (address)
    {
        return _resolveFactoryAddress(envKey, jsonKeyPrefix);
    }
}

contract DeploySettlersTest is Test {
    function test_run_WiringAssertsPass() public {
        address fakeFactory = address(0xF0F0);
        vm.setEnv("FACTORY_ADDRESS_OVERRIDE", vm.toString(fakeFactory));

        DeploySettlers deployer = new DeploySettlers();
        (address erc6909, address exactSettler, address partialSettler) = deployer.run();

        assertEq(ExactFillSettler(exactSettler).factory(), fakeFactory, "exact factory");
        assertEq(ExactFillSettler(exactSettler).erc6909Premium(), erc6909, "exact erc6909");
        assertEq(PartialFillSettler(partialSettler).factory(), fakeFactory, "partial factory");
        assertEq(PartialFillSettler(partialSettler).erc6909Premium(), erc6909, "partial erc6909");

        // Env cleanup: forge tests share a single process env; leaking `FACTORY_ADDRESS_OVERRIDE`
        // into sibling tests would let the fake factory address short-circuit any future
        // resolver branch that reads the shared production key. Reset to empty string post-
        // assertion (mirrors the pattern in `test/script/DeployEvcAdapters.t.sol`).
        vm.setEnv("FACTORY_ADDRESS_OVERRIDE", "");
    }

    /// @dev Closes #54 / D-6. An env override of `address(0)` is treated as an unresolved
    ///      sentinel rather than a live target — the resolver must NOT fall through to the
    ///      `networks.json` path when the operator explicitly set the env to the zero address.
    ///      Uses a unique env key so this assertion is independent of other tests' setEnv calls.
    function test_resolveFactory_RevertsOnZeroEnvOverride() public {
        string memory key = "DEPLOY_SETTLERS_TEST_ZERO_ENV_0xdeadbeef";
        vm.setEnv(key, vm.toString(address(0)));
        DeploySettlersHarness harness = new DeploySettlersHarness();
        vm.expectRevert(DeploySettlers.DeploySettlers__FactoryNotResolved.selector);
        harness.exposeResolveFactoryAddress(key, ".CorkCellarFactory.");
    }

    /// @dev Closes #54 / D-6. With no env var and no matching `CorkCellarFactory` key in
    ///      `lib/cellar/networks.json` for the active chain, the single-resolution-path
    ///      reverts at the terminal `DeploySettlers__FactoryNotResolved`. Proves the
    ///      legacy `.COWShedFactory.` fallback is gone: a deploy-time revert is strictly safer
    ///      than silently binding a pre-rebrand key. Uses both a unique env key and a unique
    ///      JSON prefix so no other test can bleed into this resolution.
    function test_resolveFactory_RevertsWhenBothMissing() public {
        string memory envKey = "DEPLOY_SETTLERS_TEST_UNSET_UNIQUE_KEY_0xbeefcafe";
        string memory jsonKeyPrefix = ".DeploySettlersTest_NoSuchKey.";
        DeploySettlersHarness harness = new DeploySettlersHarness();
        vm.expectRevert(DeploySettlers.DeploySettlers__FactoryNotResolved.selector);
        harness.exposeResolveFactoryAddress(envKey, jsonKeyPrefix);
    }
}
