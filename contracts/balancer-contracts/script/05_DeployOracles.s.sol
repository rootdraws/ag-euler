// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";

interface IBalancerVault {
    function getPoolTokens(address pool) external view returns (address[] memory);
}

interface IStableLPOracleFactory {
    function create(
        address pool,
        bool shouldUseBlockTimeForOldestFeedUpdate,
        bool shouldRevertIfVaultUnlocked,
        address[] memory feeds
    ) external returns (address oracle);
}

/// @title 05_DeployOracles
/// @notice Step 5 of 6: Deploy 4 StableLPOracles + 4 ChainlinkOracle adapters, wire EulerRouter.
///
/// @dev Prerequisites (must be set in .env):
///      EULER_ROUTER
///
/// @dev Oracle chain per pool:
///      Balancer StableLPOracle (AggregatorV3Interface, 18-dec BPT price)
///          -> ChainlinkOracle adapter (Euler IPriceOracle)
///              -> EulerRouter.govSetConfig(BPT, borrowAsset, chainlinkAdapter)
///
/// @dev All pools use ConstantPriceFeed (1.0) for every token because:
///      - All 4 pools are boosted pools with rate providers on all tokens
///      - Balancer live balances already apply rate conversion to the unit-of-account
///      - Pool1/4 output = BPT priced in AUSD; Pool2/3 output = BPT priced in WMON
///
/// @dev shouldRevertIfVaultUnlocked = true  -- blocks flash loan manipulation
///      shouldUseBlockTimeForOldestFeedUpdate = true -- updatedAt = block.timestamp always
///      ChainlinkOracle maxStaleness = 72 hours (max allowed; staleness never triggers in practice)
///
/// @dev Run:
///      source .env && forge script script/05_DeployOracles.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --verify
///
/// @dev After running: no new .env entries needed. Run 06_ConfigureCluster.s.sol next.
contract DeployOracles is Script {
    // Balancer v3 on Monad
    address constant BAL_VAULT                = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant STABLE_LP_ORACLE_FACTORY = 0xbC169a08cBdCDB218d91Cd945D29B59F78c96B77;
    address constant CONSTANT_PRICE_FEED      = 0x5DbAd78818D4c8958EfF2d5b95b28385A22113Cd;

    // BPT addresses
    address constant POOL1_BPT = 0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b; // wnAUSD/wnUSDC/wnUSDT0
    address constant POOL2_BPT = 0x3475Ea1c3451a9a10Aeb51bd8836312175B88BAc; // Kintsu sMON/wnWMON
    address constant POOL3_BPT = 0x150360c0eFd098A6426060Ee0Cc4a0444c4b4b68; // Fastlane shMON/wnWMON
    address constant POOL4_BPT = 0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3; // wnLOAZND/AZND/wnAUSD

    // Borrow assets (unit of account for each pool pair)
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // ChainlinkOracle: max 72 hours (enforced bound). updatedAt = block.timestamp so never stale.
    uint256 constant MAX_STALENESS = 72 hours;

    function run() external {
        address router = vm.envAddress("EULER_ROUTER");
        EulerRouter r  = EulerRouter(router);

        vm.startBroadcast();

        // Deploy StableLPOracles
        address lpOracle1 = _deployLPOracle(POOL1_BPT);
        address lpOracle2 = _deployLPOracle(POOL2_BPT);
        address lpOracle3 = _deployLPOracle(POOL3_BPT);
        address lpOracle4 = _deployLPOracle(POOL4_BPT);

        // Deploy ChainlinkOracle adapters (base=BPT, quote=borrowAsset, feed=StableLPOracle)
        address chainlink1 = address(new ChainlinkOracle(POOL1_BPT, AUSD, lpOracle1, MAX_STALENESS));
        address chainlink2 = address(new ChainlinkOracle(POOL2_BPT, WMON, lpOracle2, MAX_STALENESS));
        address chainlink3 = address(new ChainlinkOracle(POOL3_BPT, WMON, lpOracle3, MAX_STALENESS));
        address chainlink4 = address(new ChainlinkOracle(POOL4_BPT, AUSD, lpOracle4, MAX_STALENESS));

        // Wire EulerRouter: BPT -> borrowAsset -> ChainlinkOracle adapter
        r.govSetConfig(POOL1_BPT, AUSD, chainlink1);
        r.govSetConfig(POOL2_BPT, WMON, chainlink2);
        r.govSetConfig(POOL3_BPT, WMON, chainlink3);
        r.govSetConfig(POOL4_BPT, AUSD, chainlink4);

        vm.stopBroadcast();

        console.log("\n=== STEP 5 COMPLETE: Oracles ===");
        console.log("LP_ORACLE_1=%s", lpOracle1);
        console.log("LP_ORACLE_2=%s", lpOracle2);
        console.log("LP_ORACLE_3=%s", lpOracle3);
        console.log("LP_ORACLE_4=%s", lpOracle4);
        console.log("CHAINLINK_1=%s", chainlink1);
        console.log("CHAINLINK_2=%s", chainlink2);
        console.log("CHAINLINK_3=%s", chainlink3);
        console.log("CHAINLINK_4=%s", chainlink4);
        console.log("EulerRouter wired: govSetConfig x4");
        console.log("\nRun 06_ConfigureCluster.s.sol next.");
    }

    /// @dev Builds a feeds[] array of ConstantPriceFeed for every token in the pool
    ///      and calls StableLPOracleFactory.create().
    function _deployLPOracle(address pool) internal returns (address oracle) {
        address[] memory tokens = IBalancerVault(BAL_VAULT).getPoolTokens(pool);
        address[] memory feeds  = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            feeds[i] = CONSTANT_PRICE_FEED;
        }
        oracle = IStableLPOracleFactory(STABLE_LP_ORACLE_FACTORY).create(
            pool,
            true,  // shouldUseBlockTimeForOldestFeedUpdate
            true,  // shouldRevertIfVaultUnlocked
            feeds
        );
    }
}
