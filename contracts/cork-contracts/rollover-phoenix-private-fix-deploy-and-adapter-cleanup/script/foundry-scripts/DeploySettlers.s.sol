// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC6909Premium} from "contracts/erc6909/ERC6909Premium.sol";
import {ExactFillSettler} from "contracts/settlers/ExactFillSettler.sol";
import {PartialFillSettler} from "contracts/settlers/PartialFillSettler.sol";

contract DeploySettlers is Script {
    /// @dev Production env override key — read once by `run()`. Parameterised on
    ///      `_resolveFactoryAddress` for test isolation (forge tests share process env, so tests
    ///      that drive the resolver directly use unique keys to avoid env-var bleed).
    string internal constant ENV_KEY = "FACTORY_ADDRESS_OVERRIDE";

    /// @dev Production `networks.json` key prefix — the chain id and `.address` suffix are
    ///      appended at resolution time.
    string internal constant NETWORKS_JSON_KEY_PREFIX = ".CorkCellarFactory.";

    /// @dev Thrown when neither the env override nor the `CorkCellarFactory` key in
    ///      `lib/cellar/networks.json` resolves a non-zero factory address for the active chain.
    ///      Fails the deploy at resolution time rather than silently binding a stale or legacy
    ///      key (closes #54 / D-6 — the pre-rebrand `COWShedFactory` fallback is removed).
    error DeploySettlers__FactoryNotResolved();

    function run() external returns (address erc6909, address exactSettler, address partialSettler) {
        address factory = _resolveFactoryAddress(ENV_KEY, NETWORKS_JSON_KEY_PREFIX);
        console2.log("Factory address:", factory);

        vm.startBroadcast();
        erc6909 = address(new ERC6909Premium());
        exactSettler = address(new ExactFillSettler(factory, erc6909));
        partialSettler = address(new PartialFillSettler(factory, erc6909));
        vm.stopBroadcast();

        console2.log("ERC6909Premium:", erc6909);
        console2.log("ExactFillSettler:", exactSettler);
        console2.log("PartialFillSettler:", partialSettler);

        require(ExactFillSettler(exactSettler).factory() == factory, "wiring-exact-factory");
        require(ExactFillSettler(exactSettler).erc6909Premium() == erc6909, "wiring-exact-premium");
        require(PartialFillSettler(partialSettler).factory() == factory, "wiring-partial-factory");
        require(PartialFillSettler(partialSettler).erc6909Premium() == erc6909, "wiring-partial-premium");
    }

    /// @dev Resolve the cellar factory address via a single, documented order:
    ///      (1) env var at `envKey` (address(0) is treated as unresolved),
    ///      (2) `lib/cellar/networks.json` key `<jsonKeyPrefix><chainId>.address`,
    ///      (3) revert with `DeploySettlers__FactoryNotResolved`.
    ///      The pre-rebrand `.COWShedFactory.` fallback is intentionally absent — RFC 003 §§2–7
    ///      knows only the `CorkCellarFactory` key, and a deploy-time revert is strictly safer
    ///      than silently binding a legacy target (closes #54 / D-6).
    ///      Visibility is `internal` (not `private`) and the two lookup keys are parameters (not
    ///      hard-coded reads of `ENV_KEY` / `NETWORKS_JSON_KEY_PREFIX`) so a test harness can
    ///      drive each branch with a unique env key per case — forge tests share process env
    ///      state, so env-var-based coverage on a fixed key would be order-dependent.
    function _resolveFactoryAddress(string memory envKey, string memory jsonKeyPrefix) internal view returns (address) {
        try vm.envAddress(envKey) returns (address override_) {
            if (override_ == address(0)) revert DeploySettlers__FactoryNotResolved();
            console2.log("Using env override:", envKey);
            return override_;
        } catch {}

        try vm.readFile("lib/cellar/networks.json") returns (string memory networksJson) {
            string memory key = string.concat(jsonKeyPrefix, vm.toString(block.chainid), ".address");
            try vm.parseJsonAddress(networksJson, key) returns (address factory) {
                if (factory == address(0)) revert DeploySettlers__FactoryNotResolved();
                console2.log("Resolved factory from networks.json key:", key);
                return factory;
            } catch {}
        } catch {}

        revert DeploySettlers__FactoryNotResolved();
    }
}
