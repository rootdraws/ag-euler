// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IRMLinearKink} from "evk/InterestRateModels/IRMLinearKink.sol";

// ─── Inline interfaces for contracts in euler-price-oracle-cork ──────────────

interface ICorkOracleImpl {
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256);
}

interface ICSTZeroOracle {
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256);
}

// ─── Inline interfaces for evk-periphery-cork new contracts ──────────────────

interface IERC4626EVCCollateralCork {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface IProtectedLoopHook {
    function isHookTarget() external view returns (bytes4);
}

interface ICorkProtectedLoopLiquidator {
    function isCustomLiquidationVault(address vault) external view returns (bool);
}

/// @title CorkProtectedLoopDeployment
/// @notice 8-phase Foundry deployment script for the Cork Protected Loop cluster on Euler mainnet.
///
/// @dev Run with:
///      forge script script/production/mainnet/clusters/CorkProtectedLoop.s.sol \
///        --rpc-url $RPC_URL_HTTP_1 \
///        --private-key $PRIVATE_KEY \
///        --broadcast \
///        --verify
///
/// @dev Deployment prerequisites (external):
///      1. Cork team must whitelist deployer EOA and liquidator contract on the Cork pool.
///         Call WhitelistManager.addToMarketWhitelist(POOL_ID, address) for each.
///      2. After deployment, update cork-euler-labels products.json with deployed addresses.
///
/// @dev IRM parameters computed for: Base=0% APY, Kink(80%)=4% APY, Max(100%)=44% APY.
///      Run to verify: node lib/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow 0 4 44 80
contract CorkProtectedLoopDeployment is Script {
    // ─── Ethereum Mainnet Addresses ────────────────────────────────────────────

    // Assets
    address constant vbUSDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e; // 6 decimals
    address constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;  // 18 decimals
    address constant cST = 0x1B42544F897B7Ab236C111A4f800A54D94840688;    // 18 decimals (vbUSDC4cST)
    address constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;   // 18 decimals
    address constant USD = address(840); // 0x0000000000000000000000000000000000000348

    // Euler Infrastructure
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant eVaultFactory = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address constant eVaultImplementation = 0x8Ff1C814719096b61aBf00Bb46EAd0c9A529Dd7D;
    address constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant protocolConfig = 0x4cD6BF1D183264c02Be7748Cb5cd3A47d013351b;
    address constant sequenceRegistry = 0xEADDD21618ad5Deb412D3fD23580FD461c106B54;
    address constant balanceTracker = 0x0D52d06ceB8Dcdeeb40Cfd9f17489B350dD7F8a3;

    // Existing Oracles (reuse)
    address constant usdeUsdOracle = 0x93840A424aBc32549809Dd0Bc07cEb56E137221C; // ChainlinkInfrequentOracle USDe/USD

    // Cork Infrastructure
    address constant corkPoolManager = 0xccCCcCcCCccCfAE2Ee43F0E727A8c2969d74B9eC;
    bytes32 constant corkPoolId = 0xab4988fb673606b689a98dc06bdb3799c88a1300b6811421cd710aa8f86b702a;
    uint256 constant cstExpiry = 1776686400; // April 19, 2026

    // ─── Cluster Configuration ─────────────────────────────────────────────────

    // LTVs (Euler 1e4 scale: 0.80e4 = 80%)
    uint16 constant vbUSDC_BORROW_LTV = 0.80e4;
    uint16 constant vbUSDC_LLTV = 0.85e4;
    uint16 constant cST_BORROW_LTV = 0;
    uint16 constant cST_LLTV = 0;
    uint16 constant MAX_LIQUIDATION_DISCOUNT = 0.15e4; // 15% max discount for liquidators

    // Supply / borrow caps
    // TODO: Replace with proper AmountCap-encoded values for 1M / 800k caps before mainnet.

    // IRM parameters (Base=0%, Kink(80%)=4% APY, Max=44% APY)
    uint256 constant IRM_BASE_RATE = 0;
    uint256 constant IRM_SLOPE1 = 361_718_388;    // ~4% APY at 80% utilization
    uint256 constant IRM_SLOPE2 = 12_005_010_303; // steep slope above kink
    uint32 constant IRM_KINK = 3_435_973_836;     // 80% utilization in uint32.max scale

    // ─── Script State ──────────────────────────────────────────────────────────

    address deployer;

    // Deployed contract addresses (populated during run)
    address router;
    address corkOracleImpl;
    address cstZeroOracle;
    address sUSDeBorrowVault;
    address vbUSDCVault;
    address cSTVault;
    address hook;
    address irm;
    address liquidator;

    function run() external {
        deployer = msg.sender;
        vm.startBroadcast();

        _phase1_deployRouter();
        _phase2_deployOracles();
        _phase3_deployVaults();
        _phase4_wireRouter();
        _phase5_deployAndAttachHook();
        _phase6_configureCluster();
        _phase7_deployLiquidator();

        vm.stopBroadcast();

        _printSummary();
        _phase8_frontendInstructions();
    }

    // ─── Phase 1: Oracle Router ────────────────────────────────────────────────

    function _phase1_deployRouter() internal {
        console.log("\n=== Phase 1: Deploy EulerRouter ===");
        address _routerAddr = vm.envOr("EULER_ROUTER", address(0));
        if (_routerAddr != address(0)) {
            router = _routerAddr;
            console.log("EulerRouter (reused):", router);
        } else {
            router = address(new EulerRouter(EVC, deployer));
            console.log("EulerRouter deployed:", router);
        }
    }

    // ─── Phase 2: Oracles ─────────────────────────────────────────────────────

    function _phase2_deployOracles() internal {
        console.log("\n=== Phase 2: Deploy Oracles ===");

        // 2a. Deploy CorkOracleImpl (standard BaseAdapter pricing vbUSDC/USD).
        //     sUsdePriceOracle = router (will resolve sUSDe→USDe→Chainlink after Phase 4 wiring).
        address _corkOracleImplAddr = vm.envOr("CORK_ORACLE_IMPL", address(0));
        if (_corkOracleImplAddr == address(0)) {
            console.log("WARNING: CORK_ORACLE_IMPL not set. Set env var after deploying CorkOracleImpl.");
            console.log("  Constructor args:");
            console.log("    corkPoolManager:", corkPoolManager);
            console.log("    corkPoolId:", vm.toString(corkPoolId));
            console.log("    base (vbUSDC):", vbUSDC);
            console.log("    quote (USD):", USD);
            console.log("    sUsdeToken:", sUSDe);
            console.log("    sUsdePriceOracle (router):", router);
            console.log("    hPool: 1e18 (no impairment)");
            console.log("    governor:", deployer);
        }
        corkOracleImpl = _corkOracleImplAddr;

        // 2b. Deploy CSTZeroOracle (always returns 0 for cST/USD).
        address _cstOracleAddr = vm.envOr("CST_ZERO_ORACLE", address(0));
        if (_cstOracleAddr == address(0)) {
            console.log("WARNING: CST_ZERO_ORACLE not set.");
            console.log("  Deploy CSTZeroOracle with args:");
            console.log("    _base (cST):", cST);
            console.log("    _quote (USD):", USD);
        }
        cstZeroOracle = _cstOracleAddr;

        console.log("CorkOracleImpl:", corkOracleImpl);
        console.log("CSTZeroOracle:", cstZeroOracle);
    }

    // ─── Phase 3: Vaults ──────────────────────────────────────────────────────

    function _phase3_deployVaults() internal {
        console.log("\n=== Phase 3: Deploy Vaults ===");

        // 3a. Deploy sUSDe borrow vault FIRST (standard EVK upgradeable proxy).
        sUSDeBorrowVault = address(
            GenericFactory(eVaultFactory).createProxy(
                address(0), // use current factory implementation
                true, // upgradeable
                abi.encodePacked(sUSDe, router, USD)
            )
        );
        console.log("sUSDe Borrow Vault deployed:", sUSDeBorrowVault);

        // 3b. Deploy vbUSDC collateral vault (ERC4626EVCCollateralCork, isRefVault=true).
        //     borrowVault = sUSDeBorrowVault (needed for debtOf checks in _withdraw/_deposit).
        address _vbUSDCVaultAddr = vm.envOr("VBUSDC_VAULT", address(0));
        if (_vbUSDCVaultAddr == address(0)) {
            console.log("WARNING: VBUSDC_VAULT not set.");
            console.log("  Deploy ERC4626EVCCollateralCork (vbUSDC) with args:");
            console.log("    evc:", EVC);
            console.log("    permit2:", permit2);
            console.log("    admin:", deployer);
            console.log("    borrowVault (sUSDe borrow vault):", sUSDeBorrowVault);
            console.log("    asset (vbUSDC):", vbUSDC);
            console.log("    name: Euler Collateral: vbUSDC");
            console.log("    symbol: ecvbUSDC");
            console.log("    isRefVault: true");
        }
        vbUSDCVault = _vbUSDCVaultAddr;

        // 3c. Deploy cST collateral vault (ERC4626EVCCollateralCork, isRefVault=false).
        address _cstVaultAddr = vm.envOr("CST_VAULT", address(0));
        if (_cstVaultAddr == address(0)) {
            console.log("WARNING: CST_VAULT not set.");
            console.log("  Deploy ERC4626EVCCollateralCork (cST) with args:");
            console.log("    evc:", EVC);
            console.log("    permit2:", permit2);
            console.log("    admin:", deployer);
            console.log("    borrowVault (sUSDe borrow vault):", sUSDeBorrowVault);
            console.log("    asset (cST):", cST);
            console.log("    name: Euler Collateral: vbUSDC4cST");
            console.log("    symbol: eccST");
            console.log("    isRefVault: false");
        }
        cSTVault = _cstVaultAddr;

        console.log("sUSDe Borrow Vault:", sUSDeBorrowVault);
        console.log("vbUSDC Collateral Vault:", vbUSDCVault);
        console.log("cST Collateral Vault:", cSTVault);
    }

    // ─── Phase 4: Wire Oracle Router ──────────────────────────────────────────

    function _phase4_wireRouter() internal {
        console.log("\n=== Phase 4: Wire EulerRouter ===");
        require(router != address(0), "router not deployed");

        EulerRouter r = EulerRouter(router);

        // sUSDe/USD: resolve sUSDe (ERC4626) -> USDe via convertToAssets, then Chainlink USDe/USD.
        r.govSetResolvedVault(sUSDe, true);
        console.log("govSetResolvedVault(sUSDe, true)");

        r.govSetConfig(USDe, USD, usdeUsdOracle);
        console.log("govSetConfig(USDe, USD, ChainlinkInfrequentOracle):", usdeUsdOracle);

        // vbUSDC/USD: resolve vbUSDCVault -> vbUSDC via convertToAssets (1:1),
        // then CorkOracleImpl (standard BaseAdapter) for pricing.
        if (vbUSDCVault != address(0)) {
            r.govSetResolvedVault(vbUSDCVault, true);
            console.log("govSetResolvedVault(vbUSDCVault, true)");
        }
        if (corkOracleImpl != address(0)) {
            r.govSetConfig(vbUSDC, USD, corkOracleImpl);
            console.log("govSetConfig(vbUSDC, USD, CorkOracleImpl):", corkOracleImpl);
        }

        // cST/USD: resolve cSTVault -> cST, then CSTZeroOracle (always returns 0).
        if (cSTVault != address(0)) {
            r.govSetResolvedVault(cSTVault, true);
            console.log("govSetResolvedVault(cSTVault, true)");
        }
        if (cstZeroOracle != address(0)) {
            r.govSetConfig(cST, USD, cstZeroOracle);
            console.log("govSetConfig(cST, USD, CSTZeroOracle)");
        }

        console.log("EulerRouter wired successfully.");
    }

    // ─── Phase 5: Deploy and Attach Hook ──────────────────────────────────────

    function _phase5_deployAndAttachHook() internal {
        console.log("\n=== Phase 5: Deploy and Attach ProtectedLoopHook ===");

        address _hookAddr = vm.envOr("PROTECTED_LOOP_HOOK", address(0));
        if (_hookAddr == address(0)) {
            console.log("WARNING: PROTECTED_LOOP_HOOK not set.");
            console.log("  Deploy ProtectedLoopHook with args:");
            console.log("    eVaultFactory:", eVaultFactory);
            console.log("    evc:", EVC);
            console.log("    refVault (vbUSDCVault):", vbUSDCVault);
            console.log("    cstVault:", cSTVault);
            console.log("    borrowVault (sUSDeBorrowVault):", sUSDeBorrowVault);
            console.log("    cstToken:", cST);
            console.log("    cstExpiry:", cstExpiry);
        }
        hook = _hookAddr;

        if (hook != address(0)) {
            IEVault(sUSDeBorrowVault).setHookConfig(hook, 64);
            console.log("sUSDeBorrowVault.setHookConfig(hook, OP_BORROW=64)");
        } else {
            console.log("Skipping borrow hook attachment -- hook address not set.");
        }

        // Wire paired vault references for pairing enforcement in _withdraw/_deposit.
        if (vbUSDCVault != address(0) && cSTVault != address(0)) {
            (bool ok1,) = vbUSDCVault.call(
                abi.encodeWithSignature("setPairedVault(address)", cSTVault)
            );
            if (ok1) {
                console.log("vbUSDCVault.setPairedVault(cSTVault)");
            } else {
                console.log("WARNING: vbUSDCVault.setPairedVault failed -- run manually as governor");
            }

            (bool ok2,) = cSTVault.call(
                abi.encodeWithSignature("setPairedVault(address)", vbUSDCVault)
            );
            if (ok2) {
                console.log("cSTVault.setPairedVault(vbUSDCVault)");
            } else {
                console.log("WARNING: cSTVault.setPairedVault failed -- run manually as governor");
            }
        }
    }

    // ─── Phase 6: Cluster Configuration ──────────────────────────────────────

    function _phase6_configureCluster() internal {
        console.log("\n=== Phase 6: Configure Cluster ===");
        require(sUSDeBorrowVault != address(0), "sUSDe borrow vault not deployed");

        IEVault bv = IEVault(sUSDeBorrowVault);

        irm = address(new IRMLinearKink(IRM_BASE_RATE, IRM_SLOPE1, IRM_SLOPE2, IRM_KINK));
        console.log("IRMLinearKink deployed:", irm);

        bv.setInterestRateModel(irm);
        console.log("setInterestRateModel(IRM)");

        bv.setMaxLiquidationDiscount(MAX_LIQUIDATION_DISCOUNT);
        console.log("setMaxLiquidationDiscount(15%)");

        bv.setLiquidationCoolOffTime(1);
        console.log("setLiquidationCoolOffTime(1)");

        if (vbUSDCVault != address(0)) {
            bv.setLTV(vbUSDCVault, vbUSDC_BORROW_LTV, vbUSDC_LLTV, 0);
            console.log("setLTV(vbUSDCVault, 80% borrow, 85% liquidation)");
        }

        if (cSTVault != address(0)) {
            bv.setLTV(cSTVault, cST_BORROW_LTV, cST_LLTV, 0);
            console.log("setLTV(cSTVault, 0% borrow, 0% liquidation)");
        }

        // TODO: Use proper AmountCap-encoded values. For now, unlimited.
        bv.setCaps(type(uint16).max, type(uint16).max);
        console.log("setCaps(unlimited supply, unlimited borrow)");

        bv.setInterestFee(0);
        console.log("setInterestFee(0)");

        console.log("Cluster configuration complete.");
    }

    // ─── Phase 7: Deploy Liquidator ───────────────────────────────────────────

    function _phase7_deployLiquidator() internal {
        console.log("\n=== Phase 7: Deploy CorkProtectedLoopLiquidator ===");

        address _liquidatorAddr = vm.envOr("CORK_LIQUIDATOR", address(0));
        if (_liquidatorAddr == address(0)) {
            console.log("WARNING: CORK_LIQUIDATOR not set.");
            console.log("  Deploy CorkProtectedLoopLiquidator with args:");
            console.log("    evc:", EVC);
            console.log("    owner:", deployer);
            console.log("    corkPoolManager:", corkPoolManager);
            console.log("    poolId:", vm.toString(corkPoolId));
            console.log("    refVault (vbUSDCVault):", vbUSDCVault);
            console.log("    cstVault:", cSTVault);
            console.log("    vbUSDC:", vbUSDC);
            console.log("    cstToken:", cST);
            console.log("    sUsdeToken:", sUSDe);
            console.log("  IMPORTANT: After deployment, Cork team must call:");
            console.log("    WhitelistManager.addToMarketWhitelist(POOL_ID, liquidatorAddress)");
        }
        liquidator = _liquidatorAddr;

        console.log("CorkProtectedLoopLiquidator:", liquidator);
    }

    // ─── Summary and Frontend Instructions ────────────────────────────────────

    function _printSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("EulerRouter:", router);
        console.log("CorkOracleImpl:", corkOracleImpl);
        console.log("CSTZeroOracle:", cstZeroOracle);
        console.log("sUSDe Borrow Vault:", sUSDeBorrowVault);
        console.log("vbUSDC Collateral Vault:", vbUSDCVault);
        console.log("cST Collateral Vault:", cSTVault);
        console.log("ProtectedLoopHook:", hook);
        console.log("IRMLinearKink:", irm);
        console.log("CorkProtectedLoopLiquidator:", liquidator);
    }

    function _phase8_frontendInstructions() internal view {
        console.log("\n=== Phase 8: Frontend (Manual Steps) ===");
        console.log("1. Update cork-euler-labels/1/products.json:");
        console.log("   vaults: [vbUSDCVault, cSTVault, sUSDeBorrowVault]");
        console.log("2. Update cork-euler-labels/1/vaults.json with display names.");
        console.log("3. Push to GitHub (alphagrowth/cork-euler-labels).");
        console.log("4. Verify at https://cork.alphagrowth.fun");
        console.log("\nproducts.json snippet:");
        console.log('  "cork-protected-loop-rwa": {');
        console.log('    "vaults": ["', vbUSDCVault, '",');
        console.log('              "', cSTVault, '",');
        console.log('              "', sUSDeBorrowVault, '"]');
        console.log("  }");
    }
}
