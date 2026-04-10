// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

interface IEulerSwapV2 {
    struct StaticParams {
        address supplyVault0;
        address supplyVault1;
        address borrowVault0;
        address borrowVault1;
        address eulerAccount;
        address feeRecipient;
    }

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
}

interface IEulerSwapFactoryV2 {
    function deployPool(
        IEulerSwapV2.StaticParams memory sParams,
        IEulerSwapV2.DynamicParams memory dParams,
        IEulerSwapV2.InitialState memory initialState,
        bytes32 salt
    ) external returns (address);
}

contract DeployLiquidationPool_WORKING is Script, AddressesMainnet {

    // EXACT SALT FOR HOOK FLAGS
    bytes32 constant POOL_SALT = 0x0812fa5109d473373969374034bea0112bb0db6c07fd9059b73e1b61aed26dfd;
    
    function run() external returns (address poolAddress) {
        console.log("=== Deploying Working Liquidation Pool ===");
        console.log("Expected Pool: 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8");
        console.log("");
        
        IEulerSwapFactoryV2 factory = IEulerSwapFactoryV2(EULER_SWAP_FACTORY);

        IEulerSwapV2.StaticParams memory sParams = IEulerSwapV2.StaticParams({
            supplyVault0: INF_4W_VAULT,      // asset0 (liUSD-4w)
            supplyVault1: USDC_CREDIT_POOL,  // asset1 (USDC)
            borrowVault0: address(0),        // No borrowing of liUSD-4w needed
            borrowVault1: USDC_CREDIT_POOL,  // Borrow USDC for liquidator
            eulerAccount: WARREN_MULTISIG,
            feeRecipient: address(0)
        });

        IEulerSwapV2.DynamicParams memory dParams = IEulerSwapV2.DynamicParams({
            equilibriumReserve0: 50e18,      // liUSD-4w (asset0)
            equilibriumReserve1: 50e6,       // USDC (asset1)
            minReserve0: 0,
            minReserve1: 0,
            priceX: 1e18,
            priceY: 1e18,
            concentrationX: 0.4e18,
            concentrationY: 0.85e18,
            fee0: 0,
            fee1: 0,
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });

        IEulerSwapV2.InitialState memory initialState = IEulerSwapV2.InitialState({
            reserve0: 50e18,    // liUSD-4w (asset0)
            reserve1: 50e6     // USDC (asset1)
        });

        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));

        // Set operator authorization
        IEVC(EVC).setAccountOperator(WARREN_MULTISIG, 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8, true);
        console.log("EVC Operator set");

        // Deploy pool
        poolAddress = factory.deployPool(sParams, dParams, initialState, POOL_SALT);

        vm.stopBroadcast();

        console.log("");
        console.log("=== SUCCESS ===");
        console.log("Pool Address:", poolAddress);
        console.log("Borrow-to-fill liquidation pool deployed and activated!");
    }
}
