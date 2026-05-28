// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {IBaseSettlerFactory} from "contracts/interfaces/IBaseSettlerFactory.sol";

/// @notice Deploys a **contract-verification reference pair** of EVC adapters per RFC 003 §7.3 /
///         #43 split — one `EvcExactFillAdapter` + one `EvcPartialFillAdapter` — against a shared
///         `EthereumVaultConnector`. Both adapters are wired to a single dummy `AUTHORIZED_CALLER`
///         for bytecode / contract-verification purposes only; per-subaccount deployment is the
///         mandatory production path. Two properties force per-subaccount deployment:
///           1. Each adapter is bound to one `AUTHORIZED_CALLER` at deploy — every subaccount
///              that authenticates through the adapter needs its own instance wired to its own
///              caller identity.
///           2. `PartialFillSettler` keys per-filler state on `msg.sender`, so a shared Partial
///              adapter collapses every subaccount into one slot and reverts on the second fill.
contract DeployEvcAdapters is Script {
    /// @dev Thrown when neither the env override nor `networks.json` resolves a settler address.
    error DeployEvcAdapters__SettlerNotResolved(bool isPartial);

    /// @dev Thrown when neither the env override nor `networks.json` resolves the EVC address.
    error DeployEvcAdapters__EvcNotResolved();

    /// @dev Thrown when `EVC_AUTHORIZED_CALLER_OVERRIDE` is unset or resolves to `address(0)`.
    error DeployEvcAdapters__AuthorizedCallerNotResolved();

    /// @dev Thrown when the Partial settler does not expose a readable `factory()` immutable.
    error DeployEvcAdapters__PartialSettlerMissingFactory(address partialSettler);

    /// @notice Deploys both adapters against a single dummy `AUTHORIZED_CALLER` for bytecode /
    ///         contract-verification purposes only. Production deployments MUST repeat this
    ///         process per subaccount identity with a real authorised caller.
    function run() external returns (address exactAdapter, address partialAdapter) {
        address exactSettler = _resolveSettler("EXACT_SETTLER_OVERRIDE", ".ExactFillSettler.", false);
        address partialSettler = _resolveSettler("PARTIAL_SETTLER_OVERRIDE", ".PartialFillSettler.", true);
        address evc = _resolveEvc("EVC_ADDRESS_OVERRIDE");
        address authorizedCaller = _resolveAuthorizedCaller("EVC_AUTHORIZED_CALLER_OVERRIDE");

        console2.log("ExactFillSettler:", exactSettler);
        console2.log("PartialFillSettler:", partialSettler);
        console2.log("EthereumVaultConnector:", evc);
        console2.log("AUTHORIZED_CALLER (reference pair only):", authorizedCaller);

        address partialFactory;
        try IBaseSettlerFactory(partialSettler).factory() returns (address factory_) {
            partialFactory = factory_;
        } catch {
            revert DeployEvcAdapters__PartialSettlerMissingFactory(partialSettler);
        }

        vm.startBroadcast();
        exactAdapter = address(new EvcExactFillAdapter(exactSettler, address(0), evc, authorizedCaller));
        partialAdapter = address(new EvcPartialFillAdapter(partialSettler, partialFactory, evc, authorizedCaller));
        vm.stopBroadcast();

        console2.log("EvcExactFillAdapter:", exactAdapter);
        console2.log("EvcPartialFillAdapter (canonical ref only):", partialAdapter);

        require(EvcExactFillAdapter(exactAdapter).SETTLER() == exactSettler, "wiring-exact-settler");
        require(EvcExactFillAdapter(exactAdapter).FACTORY() == address(0), "wiring-exact-factory");
        require(EvcExactFillAdapter(exactAdapter).EVC() == evc, "wiring-exact-evc");
        require(EvcPartialFillAdapter(partialAdapter).SETTLER() == partialSettler, "wiring-partial-settler");
        require(EvcPartialFillAdapter(partialAdapter).FACTORY() == partialFactory, "wiring-partial-factory");
        require(EvcPartialFillAdapter(partialAdapter).EVC() == evc, "wiring-partial-evc");
    }

    /// @dev Resolve a settler address via env override first, then `networks.json` at repo root.
    function _resolveSettler(string memory envKey, string memory jsonKeyPrefix, bool isPartial)
        internal
        view
        returns (address)
    {
        try vm.envAddress(envKey) returns (address override_) {
            if (override_ == address(0)) revert DeployEvcAdapters__SettlerNotResolved(isPartial);
            console2.log("Using env override:", envKey);
            return override_;
        } catch {}

        try vm.readFile("networks.json") returns (string memory networksJson) {
            string memory key = string.concat(jsonKeyPrefix, vm.toString(block.chainid), ".address");
            try vm.parseJsonAddress(networksJson, key) returns (address settler) {
                if (settler == address(0)) revert DeployEvcAdapters__SettlerNotResolved(isPartial);
                console2.log("Resolved settler from networks.json key:", key);
                return settler;
            } catch {}
        } catch {}

        revert DeployEvcAdapters__SettlerNotResolved(isPartial);
    }

    /// @dev Resolve the EVC address via env override first, then `networks.json`.
    function _resolveEvc(string memory envKey) internal view returns (address) {
        try vm.envAddress(envKey) returns (address override_) {
            if (override_ == address(0)) revert DeployEvcAdapters__EvcNotResolved();
            console2.log("Using env override:", envKey);
            return override_;
        } catch {}

        try vm.readFile("networks.json") returns (string memory networksJson) {
            string memory key = string.concat(".EthereumVaultConnector.", vm.toString(block.chainid), ".address");
            try vm.parseJsonAddress(networksJson, key) returns (address evc_) {
                if (evc_ == address(0)) revert DeployEvcAdapters__EvcNotResolved();
                console2.log("Resolved EVC from networks.json key:", key);
                return evc_;
            } catch {}
        } catch {}

        revert DeployEvcAdapters__EvcNotResolved();
    }

    /// @dev Resolve the dummy `AUTHORIZED_CALLER` for the verification-only reference pair.
    ///      Env-only — the caller is deployment-specific (per subaccount in production).
    function _resolveAuthorizedCaller(string memory envKey) internal view returns (address) {
        try vm.envAddress(envKey) returns (address override_) {
            if (override_ == address(0)) revert DeployEvcAdapters__AuthorizedCallerNotResolved();
            console2.log("Using env override:", envKey);
            return override_;
        } catch {}

        revert DeployEvcAdapters__AuthorizedCallerNotResolved();
    }
}
