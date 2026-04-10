// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {ManageClusterBase} from "evk-periphery-scripts/production/ManageClusterBase.s.sol";
import {OracleVerifier} from "evk-periphery-scripts/utils/SanityCheckOracle.s.sol";
import {console} from "forge-std/console.sol";
import "./AddressesMainnet.sol";

/// @title Warren Credit Pool Cluster
/// @notice Deploys Credit Pool USDC vault - liquidation backstop with punitive rates
/// @dev Includes existing Loop Vault to satisfy LTV validation, deploys only Credit Pool
contract WarrenCreditPoolCluster is ManageClusterBase, AddressesMainnet {
    
    function defineCluster() internal override {
        cluster.clusterAddressesPath = "/script/clusters/WarrenCreditPoolCluster.json";

        cluster.assets = [
            INF_1W,   // 0 - existing
            INF_4W,   // 1 - existing
            INF_8W,   // 2 - existing
            USDC,     // 3 - existing Loop Vault
            USDC      // 4 - NEW Credit Pool
        ];
    }

    function configureCluster() internal override {
        // Governance
        cluster.oracleRoutersGovernor = WARREN_MULTISIG;
        cluster.vaultsGovernor = WARREN_MULTISIG;

        // Unit of account
        cluster.unitOfAccount = USD;

        // Fees
        cluster.feeReceiver = WARREN_TREASURY;
        cluster.interestFee = 0.1e4;

        // Liquidation
        cluster.maxLiquidationDiscount = 0.15e4;
        cluster.liquidationCoolOffTime = 1;

        // Hook - default OP_LIQUIDATE only
        cluster.hookTarget = LIQUIDATOR_HOOK;
        cluster.hookedOps = 0x800;

        // Credit Pool (index 4) hooks both LIQUIDATE and BORROW
        // Can't use hookedOpsOverride[USDC] - conflicts with index 3
        // Need to set via index after deployment or use different approach

        // Config flags
        cluster.configFlags = 0;

        // Oracle providers
        cluster.oracleProviders[INF_1W] = addressToString(INF_1W_ORACLE);
        cluster.oracleProviders[INF_4W] = addressToString(INF_4W_ORACLE);
        cluster.oracleProviders[INF_8W] = addressToString(INF_8W_ORACLE);
        cluster.oracleProviders[USDC]   = addressToString(USDC_ORACLE);

        // Supply caps
        cluster.supplyCaps[INF_1W] = 10_000_000;
        cluster.supplyCaps[INF_4W] = 2_000_000;
        cluster.supplyCaps[INF_8W] = 2_000_000;
        cluster.supplyCaps[USDC]   = 10_000_000;

        // Borrow caps
        cluster.borrowCaps[INF_1W] = 9_000_000;
        cluster.borrowCaps[INF_4W] = 1_800_000;
        cluster.borrowCaps[INF_8W] = 1_800_000;
        cluster.borrowCaps[USDC]   = 10_000_000;

        // IRM - zeros for existing vaults (already configured)
        cluster.kinkIRMParams[INF_1W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        cluster.kinkIRMParams[INF_4W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        cluster.kinkIRMParams[INF_8W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        
        // Credit Pool IRM: 20% base → 30% at 80% kink → 50% at 100%
        cluster.kinkIRMParams[USDC] = [
            uint256(5777540112238977000),  // baseRate (20%)
            uint256(738204818),            // slope1 (to 30% at 80%)
            uint256(5279068394),           // slope2 (to 50% at 100%)
            uint256(3435973836)            // kink (80%)
        ];

        // LTV timing
        cluster.rampDuration = 1 days;
        cluster.spreadLTV = 0; // 0% spread - borrow LTV = liquidation LTV for Credit Pool

        // LTV Matrix (5x5)
        // Loop Vault (3) and Credit Pool (4) isolated from each other
        // liUSD borrows from Loop at 80%, from Credit Pool at 100%
        // Credit Pool fully cross-collateralized with liUSD at 100%
        cluster.ltvs = [
        //                0              1              2              3              4
        //                INF_1W         INF_4W         INF_8W         USDC_LOOP      USDC_CP
        /* 0 INF_1W */ [uint16(0.00e4), 0.80e4,        0.80e4,        0.80e4,        1.00e4],
        /* 1 INF_4W */ [uint16(0.80e4), 0.00e4,        0.80e4,        0.80e4,        1.00e4],
        /* 2 INF_8W */ [uint16(0.80e4), 0.80e4,        0.00e4,        0.80e4,        1.00e4],
        /* 3 USDC_LP*/ [uint16(0.80e4), 0.80e4,        0.80e4,        0.00e4,        0.00e4],
        /* 4 USDC_CP*/ [uint16(1.00e4), 1.00e4,        1.00e4,        0.00e4,        0.00e4]
        ];
    }

    function postOperations() internal override {
        for (uint256 i = 0; i < cluster.vaults.length; ++i) {
            OracleVerifier.verifyOracleConfig(lensAddresses.oracleLens, cluster.vaults[i], false);
        }
        
        console.log("");
        console.log("========================================");
        console.log("WARREN CREDIT POOL DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Credit Pool Vault (USDC):", cluster.vaults[4]);
        console.log("");
        console.log("IMPORTANT: Credit Pool needs OP_BORROW hooked.");
        console.log("The hookedOpsOverride couldn't distinguish USDC vaults.");
        console.log("Run setHookConfig on Credit Pool vault to add 0x840.");
        console.log("");
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("========================================");
        console.log("1. Set hook config on Credit Pool:");
        console.log("   vault.setHookConfig(LIQUIDATOR_HOOK, 0x840)");
        console.log("");
        console.log("2. Deploy EulerSwap pools");
        console.log("");
        console.log("3. Whitelist EulerSwap pools for OP_BORROW:");
        console.log("   LIQUIDATOR_HOOK.grantRole(borrowSelector, pool)");
        console.log("========================================");
    }

    function addressToString(address _addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(_addr);
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            str[2+i*2] = alphabet[uint8(value[i] >> 4)];
            str[3+i*2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
