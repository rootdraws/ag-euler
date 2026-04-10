// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

interface IEulerSwapV2 {
    struct DynamicParams {
        uint112 equilibriumReserve0;
        uint112 equilibriumReserve1;
        uint112 minReserve0;
        uint112 minReserve1;
        uint80 priceX;
        uint80 priceY;
        uint64 concentrationX;
        uint64 concentrationY;
        uint64 fee0;
        uint64 fee1;
        uint40 expiration;
        uint8 swapHookedOperations;
        address swapHook;
    }

    struct InitialState {
        uint112 reserve0;
        uint112 reserve1;
    }

    function getDynamicParams() external view returns (DynamicParams memory);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 status);
    function reconfigure(DynamicParams calldata dParams, InitialState calldata initialState) external;
}

/// @title ReconfigureLiquidationPool
/// @notice Reconfigure pool parameters to fix quote failures using ground truth patterns
contract ReconfigureLiquidationPool is Script, AddressesMainnet {
    
    address constant POOL = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8;
    
    function run() external {
        console.log("=== Reconfiguring Liquidation Pool ===");
        console.log("Pool:", POOL);
        console.log("");
        
        IEulerSwapV2 pool = IEulerSwapV2(POOL);
        
        // Get current state
        (uint112 currentReserve0, uint112 currentReserve1, uint32 status) = pool.getReserves();
        console.log("Current state:");
        console.log("  Status:", status);
        console.log("  Reserve 0:", currentReserve0);
        console.log("  Reserve 1:", currentReserve1);
        console.log("");
        
        // GROUND TRUTH: AltDecimals.t.sol working configuration for 18/6 decimal mix
        IEulerSwapV2.DynamicParams memory dParams = IEulerSwapV2.DynamicParams({
            equilibriumReserve0: 10_000_000e18, // 10M liUSD-4w (matches vault capacity)
            equilibriumReserve1: 11_600_000e6, // 11.6M USDC (10M × 1.16 rate)
            minReserve0: 0,
            minReserve1: 0,
            priceX: 1.16e6,                    // 1.16 USDC value (ground truth pattern)
            priceY: 1e18,                      // liUSD reference (ground truth pattern)
            concentrationX: 1e18,              // Constant-sum curve (no slippage)
            concentrationY: 1e18,              // Constant-sum curve (no slippage)
            fee0: 0,
            fee1: 0,
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });
        
        // Use equilibrium-compatible initial state
        IEulerSwapV2.InitialState memory initialState = IEulerSwapV2.InitialState({
            reserve0: 10_000_000e18, // 10M liUSD-4w (match vault capacity)
            reserve1: 11_600_000e6   // 11.6M USDC (match vault capacity)
        });
        
        console.log("New configuration (AltDecimals pattern):");
        console.log("  equilibriumReserve0:", dParams.equilibriumReserve0);
        console.log("  equilibriumReserve1:", dParams.equilibriumReserve1);
        console.log("  priceX:", dParams.priceX, "(USDC scale)");
        console.log("  priceY:", dParams.priceY, "(liUSD scale)");
        console.log("  concentrationX:", dParams.concentrationX);
        console.log("  concentrationY:", dParams.concentrationY);
        console.log("");
        
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        
        // Reconfigure using EVC call pattern from ground truth
        console.log("Reconfiguring pool...");
        IEVC(EVC).call(
            POOL,
            WARREN_MULTISIG,
            0,
            abi.encodeCall(IEulerSwapV2.reconfigure, (dParams, initialState))
        );
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Reconfiguration Complete ===");
        console.log("Pool reconfigured with decimal-aware parameters");
        console.log("Ready for quote testing!");
    }
}
