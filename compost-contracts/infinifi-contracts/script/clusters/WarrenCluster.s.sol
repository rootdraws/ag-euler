// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {ManageClusterBase} from "evk-periphery-scripts/production/ManageClusterBase.s.sol";
import {OracleVerifier} from "evk-periphery-scripts/utils/SanityCheckOracle.s.sol";
import {console} from "forge-std/console.sol";
import "./AddressesMainnet.sol";

/// @title Warren Protocol Cluster
/// @notice Deploys Warren's InfiniFI lending markets with USDC as the borrowable asset
contract WarrenCluster is ManageClusterBase, AddressesMainnet {
    
    function defineCluster() internal override {
        // Define the path to the cluster addresses file
        cluster.clusterAddressesPath = "/script/clusters/WarrenCluster.json";

        // Define Warren's assets: 3 liUSD maturities + USDC
        // IMPORTANT: Do not change the order of assets after deployment
        cluster.assets = [
            INF_1W,  // liUSD-1w (1 week maturity)
            INF_4W,  // liUSD-4w (4 week maturity)
            INF_8W,  // liUSD-8w (8 week maturity)
            USDC     // USDC (borrowable asset)
        ];
    }

    function configureCluster() internal override {
        // Governance addresses
        cluster.oracleRoutersGovernor = WARREN_MULTISIG;
        cluster.vaultsGovernor = WARREN_MULTISIG;

        // Unit of account (USD for pricing)
        cluster.unitOfAccount = USD;

        // Fee configuration
        cluster.feeReceiver = WARREN_TREASURY;
        cluster.interestFee = 0.1e4; // 10% of interest goes to protocol

        // Liquidation parameters
        cluster.maxLiquidationDiscount = 0.15e4; // 15% max discount
        cluster.liquidationCoolOffTime = 1; // 1 second

        // Hook configuration - Use HookTargetAccessControl
        cluster.hookTarget = 0x5e306F12E7eBCC0F7d3e5639Dc8f003791D76515;
        cluster.hookedOps = 0x800; // OP_LIQUIDATE (1 << 11)

        // Config flags
        cluster.configFlags = 0;

        // Oracle providers - Use our deployed adapters
        cluster.oracleProviders[INF_1W] = addressToString(INF_1W_ORACLE);
        cluster.oracleProviders[INF_4W] = addressToString(INF_4W_ORACLE);
        cluster.oracleProviders[INF_8W] = addressToString(INF_8W_ORACLE);
        cluster.oracleProviders[USDC]   = addressToString(USDC_ORACLE);

        // Supply caps (in asset decimals)
        cluster.supplyCaps[INF_1W] = 10_000_000; // 10M liUSD-1w
        cluster.supplyCaps[INF_4W] = 2_000_000;  // 2M liUSD-4w
        cluster.supplyCaps[INF_8W] = 2_000_000;  // 2M liUSD-8w
        
        // USDC supply cap calculation:
        // Max potential borrows: (10M + 2M + 2M) * 0.8 = 11.2M USDC
        // Add 50% buffer for liquidation swaps: 11.2M * 1.5 = 16.8M
        cluster.supplyCaps[USDC] = 20_000_000; // 20M USDC

        // Borrow caps - All assets are borrowable
        cluster.borrowCaps[INF_1W] = 9_000_000;  // 9M liUSD-1w borrowable
        cluster.borrowCaps[INF_4W] = 1_800_000;  // 1.8M liUSD-4w borrowable
        cluster.borrowCaps[INF_8W] = 1_800_000;  // 1.8M liUSD-8w borrowable
        
        // USDC borrow cap: 12M to leave 8M available for liquidation swaps
        cluster.borrowCaps[USDC] = 12_000_000; // 12M USDC borrowable

        // IRM Configuration
        // Setting to zero allows post-deployment configuration via setInterestRateModel()
        cluster.kinkIRMParams[INF_1W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        cluster.kinkIRMParams[INF_4W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        cluster.kinkIRMParams[INF_8W] = [uint256(0), uint256(0), uint256(0), uint256(0)];
        cluster.kinkIRMParams[USDC]   = [uint256(0), uint256(0), uint256(0), uint256(0)];

        // Ramp duration for LTV changes
        cluster.rampDuration = 1 days;

        // Spread between borrow and liquidation LTV
        cluster.spreadLTV = 0.02e4; // 2%

        // Liquidation LTV matrix - All borrowing at 80% LTV
        // Columns = liability vaults, Rows = collateral vaults
        cluster.ltvs = [
        //                0              1              2              3
        //                INF_1W         INF_4W         INF_8W         USDC
        /* 0 INF_1W */ [uint16(0.00e4), 0.80e4,        0.80e4,        0.80e4], // 80% LTV for all
        /* 1 INF_4W */ [uint16(0.80e4), 0.00e4,        0.80e4,        0.80e4], // 80% LTV for all
        /* 2 INF_8W */ [uint16(0.80e4), 0.80e4,        0.00e4,        0.80e4], // 80% LTV for all
        /* 3 USDC   */ [uint16(0.80e4), 0.80e4,        0.80e4,        0.00e4]  // 80% LTV for all
        ];
    }

    function postOperations() internal override {
        // Verify oracle configuration for each vault
        for (uint256 i = 0; i < cluster.vaults.length; ++i) {
            OracleVerifier.verifyOracleConfig(lensAddresses.oracleLens, cluster.vaults[i], false);
        }
        
        console.log("");
        console.log("========================================");
        console.log("WARREN PROTOCOL CLUSTER DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("-------------------");
        
        // List all vaults with their assets
        for (uint256 i = 0; i < cluster.vaults.length; ++i) {
            string memory assetName;
            if (cluster.assets[i] == INF_1W) assetName = "INF_1W";
            else if (cluster.assets[i] == INF_4W) assetName = "INF_4W";
            else if (cluster.assets[i] == INF_8W) assetName = "INF_8W";
            else if (cluster.assets[i] == USDC) assetName = "USDC";
            
            console.log(string(abi.encodePacked(assetName, " Vault: ")), cluster.vaults[i]);
            console.log(string(abi.encodePacked("  Etherscan: https://etherscan.io/address/", addressToString(cluster.vaults[i]))));
        }
        
        console.log("");
        console.log("========================================");
        console.log("");
        
        // Verify contracts on Etherscan
        console.log("Verifying contracts on Etherscan...");
        console.log("Note: Run this command manually if needed:");
        console.log("");
        
        for (uint256 i = 0; i < cluster.vaults.length; ++i) {
            string memory assetSymbol;
            if (cluster.assets[i] == INF_1W) assetSymbol = "INF_1W";
            else if (cluster.assets[i] == INF_4W) assetSymbol = "INF_4W";
            else if (cluster.assets[i] == INF_8W) assetSymbol = "INF_8W";
            else if (cluster.assets[i] == USDC) assetSymbol = "USDC";
            
            console.log(string(abi.encodePacked("forge verify-contract ", addressToString(cluster.vaults[i]), " EVault --etherscan-api-key $ETHERSCAN_API --watch")));
        }
        
        console.log("");
        console.log("========================================");
    }

    /// @notice Helper to convert address to string for oracle providers
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
