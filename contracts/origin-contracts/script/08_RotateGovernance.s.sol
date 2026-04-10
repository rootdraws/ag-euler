// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IEulerRouter {
    function governor() external view returns (address);
    function transferGovernance(address newGovernor) external;
}

interface IEVault {
    function setGovernorAdmin(address newGovernorAdmin) external;
    function governorAdmin() external view returns (address);
}

/// @title 08_RotateGovernance
/// @notice Post-deployment: rotate governance on the EulerRouter and both EVK vaults
///         from the deployer EOA to the AlphaGrowth multisig.
///
/// @dev This is a one-shot, production-posture rotation. After execution:
///      - EulerRouter.governor       == AG_MULTISIG
///      - ARM collateral vault admin == AG_MULTISIG
///      - WETH borrow vault admin    == AG_MULTISIG
///
///      The deployer EOA loses all governance powers on this deployment.
///      Further changes (setLTV, govSetResolvedVault, setHookConfig, etc.)
///      must be executed via a Safe transaction.
///
/// @dev Prerequisites (must be set in .env):
///      EULER_ROUTER, ARM_COLLATERAL_VAULT, WETH_BORROW_VAULT, AG_MULTISIG
///
/// @dev Run:
///      source .env && forge script script/08_RotateGovernance.s.sol \
///        --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY --broadcast
contract RotateGovernance is Script {
    function run() external {
        address router     = vm.envAddress("EULER_ROUTER");
        address collVault  = vm.envAddress("ARM_COLLATERAL_VAULT");
        address borrVault  = vm.envAddress("WETH_BORROW_VAULT");
        address multisig   = vm.envAddress("AG_MULTISIG");

        require(multisig != address(0), "AG_MULTISIG not set");

        // Pre-flight: confirm deployer is currently the governor on all three contracts.
        address routerGov = IEulerRouter(router).governor();
        address collGov   = IEVault(collVault).governorAdmin();
        address borrGov   = IEVault(borrVault).governorAdmin();

        console.log("Before:");
        console.log("  EulerRouter.governor       = %s", routerGov);
        console.log("  collateral.governorAdmin   = %s", collGov);
        console.log("  borrow.governorAdmin       = %s", borrGov);
        console.log("  target (AG_MULTISIG)       = %s", multisig);

        require(routerGov == collGov && collGov == borrGov, "Governors diverged, investigate");

        vm.startBroadcast();

        IEulerRouter(router).transferGovernance(multisig);
        IEVault(collVault).setGovernorAdmin(multisig);
        IEVault(borrVault).setGovernorAdmin(multisig);

        vm.stopBroadcast();

        // Post-flight: confirm rotation applied.
        require(IEulerRouter(router).governor() == multisig, "router rotation failed");
        require(IEVault(collVault).governorAdmin() == multisig, "collateral rotation failed");
        require(IEVault(borrVault).governorAdmin() == multisig, "borrow rotation failed");

        console.log("\n=== STEP 8 COMPLETE: Governance Rotated to AG Multisig ===");
        console.log("All further admin calls must originate from %s", multisig);
    }
}
