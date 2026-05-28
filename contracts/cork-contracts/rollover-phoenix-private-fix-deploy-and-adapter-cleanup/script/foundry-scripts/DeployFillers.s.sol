// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ExactRolloverFiller} from "contracts/fillers/ExactRolloverFiller.sol";
import {PartialRolloverFiller} from "contracts/fillers/PartialRolloverFiller.sol";
import {IBaseSettlerFactory} from "contracts/interfaces/IBaseSettlerFactory.sol";

/// @notice Deploys the four canonical reference fillers (per RFC 003 §7.2 / #43 split): one
///         `ExactRolloverFiller` + one `PartialRolloverFiller`. The Partial deployment is a
///         **canonical reference only**: production Partial fillers MUST deploy their own
///         `PartialRolloverFiller` instance per user identity, because `PartialFillSettler` keys
///         per-filler state on `msg.sender` — a shared Partial filler collapses every caller into
///         one slot and reverts on the second fill.
contract DeployFillers is Script {
    /// @dev Thrown when neither the env override nor `networks.json` resolves a settler address.
    error DeployFillers__SettlerNotResolved(bool isPartial);

    /// @notice Deploys both reference fillers. Settler resolution order per role:
    ///         (1) env override (`EXACT_SETTLER_OVERRIDE` / `PARTIAL_SETTLER_OVERRIDE`),
    ///         (2) `networks.json` at the repo root under
    ///             `.ExactFillSettler.<chain>.address` / `.PartialFillSettler.<chain>.address`,
    ///         (3) revert with `DeployFillers__SettlerNotResolved`.
    ///         Only the filler deployments are broadcast; resolution is read-only.
    function run() external returns (address exactFiller, address partialFiller) {
        address exactSettler = _resolveSettler("EXACT_SETTLER_OVERRIDE", ".ExactFillSettler.", false);
        address partialSettler = _resolveSettler("PARTIAL_SETTLER_OVERRIDE", ".PartialFillSettler.", true);

        console2.log("ExactFillSettler:", exactSettler);
        console2.log("PartialFillSettler:", partialSettler);

        // Read the Partial settler's factory immutable once so the filler constructor's
        // `expectedFactory_` cross-check has a value to match against. On the Exact path we pass
        // address(0) — the FACTORY immutable is unused and the constructor forbids any other value.
        address partialFactory = IBaseSettlerFactory(partialSettler).factory();

        vm.startBroadcast();
        exactFiller = address(new ExactRolloverFiller(exactSettler, address(0)));
        partialFiller = address(new PartialRolloverFiller(partialSettler, partialFactory));
        vm.stopBroadcast();

        console2.log("ExactRolloverFiller:", exactFiller);
        console2.log("PartialRolloverFiller (canonical ref only):", partialFiller);

        require(ExactRolloverFiller(exactFiller).SETTLER() == exactSettler, "wiring-exact-settler");
        require(PartialRolloverFiller(partialFiller).SETTLER() == partialSettler, "wiring-partial-settler");
        require(PartialRolloverFiller(partialFiller).FACTORY() == partialFactory, "wiring-partial-factory");
    }

    /// @dev Resolve a settler address via env override first, then `networks.json` at repo root.
    ///      `jsonKeyPrefix` is the leading JSON path (e.g. `.ExactFillSettler.`) to which the
    ///      decimal chain id and `.address` suffix are appended.
    ///      Visibility is `internal` (not `private`) so the test harness can drive each
    ///      resolution branch directly with explicit inputs — forge tests share process
    ///      env state across cases, so env-var-based coverage is fragile by construction.
    function _resolveSettler(string memory envKey, string memory jsonKeyPrefix, bool isPartial)
        internal
        view
        returns (address)
    {
        // Env override: treat address(0) as an unresolved sentinel rather than a live target.
        try vm.envAddress(envKey) returns (address override_) {
            if (override_ == address(0)) revert DeployFillers__SettlerNotResolved(isPartial);
            console2.log("Using env override:", envKey);
            return override_;
        } catch {}

        // networks.json path — read the file first (file-missing is a distinguishable failure
        // handled outside the inner `try`, but the swallow pattern is preserved to match the
        // `DeploySettlers.s.sol` sibling's "resolve, else fall through" shape). The zero-address
        // guard inside applies here too: a misconfigured networks.json entry of 0x0000... is
        // rejected the same way the env override is.
        try vm.readFile("networks.json") returns (string memory networksJson) {
            string memory key = string.concat(jsonKeyPrefix, vm.toString(block.chainid), ".address");
            try vm.parseJsonAddress(networksJson, key) returns (address settler) {
                if (settler == address(0)) revert DeployFillers__SettlerNotResolved(isPartial);
                console2.log("Resolved settler from networks.json key:", key);
                return settler;
            } catch {}
        } catch {}

        revert DeployFillers__SettlerNotResolved(isPartial);
    }
}
