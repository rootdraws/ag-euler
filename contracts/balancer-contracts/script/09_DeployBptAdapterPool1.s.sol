// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BalancerBptAdapter} from "../src/BalancerBptAdapter.sol";

/// @title 09_DeployBptAdapterPool1
/// @notice Deploy BalancerBptAdapter for Pool 1 (wnUSDT0/wnAUSD/wnUSDC).
///
///         Pool 1 tokens (in on-chain order):
///           [0] wnUSDT0    = 0x4e8aaecCE10ad9394e96fE5f2bd4e587A7B04298  (wraps USDT0)
///           [1] wnAUSD     = 0x82c370ba90E38ef6Acd8b1b078d34fD86FC6bAC9  (wraps AUSD)
///           [2] wnUSDC     = 0x8d5c2Df3Eef09088Fcccf3376D8EcD0Dd505f642  (wraps USDC)
///
/// @dev Run:
///      source .env && forge script script/09_DeployBptAdapterPool1.s.sol \
///        --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
///        --broadcast --gas-estimate-multiplier 400
contract DeployBptAdapterPool1 is Script {
    address constant BALANCER_ROUTER = 0x9dA18982a33FD0c7051B19F0d7C76F2d5E7e017c;
    address constant POOL1_BPT = 0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b;

    // Pool tokens
    address constant WN_USDT0 = 0x4e8aaecCE10ad9394e96fE5f2bd4e587A7B04298;
    address constant WN_AUSD  = 0x82c370ba90E38ef6Acd8b1b078d34fD86FC6bAC9;
    address constant WN_USDC  = 0x8d5c2Df3Eef09088Fcccf3376D8EcD0Dd505f642;

    // Underlying tokens
    address constant USDT0 = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
    address constant AUSD  = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC  = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    function run() external {
        BalancerBptAdapter.TokenConfig[] memory configs = new BalancerBptAdapter.TokenConfig[](3);

        configs[0] = BalancerBptAdapter.TokenConfig({
            poolToken: WN_USDT0,
            underlying: USDT0,
            needsWrap: true
        });

        configs[1] = BalancerBptAdapter.TokenConfig({
            poolToken: WN_AUSD,
            underlying: AUSD,
            needsWrap: true
        });

        configs[2] = BalancerBptAdapter.TokenConfig({
            poolToken: WN_USDC,
            underlying: USDC,
            needsWrap: true
        });

        vm.startBroadcast();
        BalancerBptAdapter adapter = new BalancerBptAdapter(BALANCER_ROUTER, POOL1_BPT, configs);
        vm.stopBroadcast();

        console.log("\n=== STEP 9 COMPLETE: Pool 1 BPT Adapter ===");
        console.log("POOL1_BPT_ADAPTER=%s", address(adapter));
        console.log("  [0] USDT0 -> wnUSDT0 -> Pool1 BPT");
        console.log("  [1] AUSD  -> wnAUSD  -> Pool1 BPT");
        console.log("  [2] USDC  -> wnUSDC  -> Pool1 BPT");
        console.log("\nFor multiply via AUSD borrow: use tokenIndex=1");
    }
}
