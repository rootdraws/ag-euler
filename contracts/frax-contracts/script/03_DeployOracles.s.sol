// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

import {ICHIVaultOracleFactory} from "../ichi-oracle-kit/src/ICHIVaultOracleFactory.sol";
import {OraclePoke} from "../ichi-oracle-kit/src/keeper/OraclePoke.sol";
import {IICHIVaultMinimal} from "../ichi-oracle-kit/src/interfaces/IMinimal.sol";

/// @title 03_DeployOracles
/// @notice Step 3 of 7: Deploy the ICHI oracle infrastructure.
///   - ICHIVaultOracleFactory
///   - 5 oracle instances (one per ICHI vault)
///   - OraclePoke keeper
///   - Register all 5 underlying Algebra pools in the keeper
///
/// @dev Usage:
///   source .env
///   forge script script/03_DeployOracles.s.sol:DeployOracles \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Then add to .env:
///     ICHI_ORACLE_FACTORY=<addr>
///     ORACLE_BRZ=<addr>  ORACLE_TGBP=<addr>  ORACLE_USDC=<addr>
///     ORACLE_IDRX=<addr> ORACLE_KRWQ=<addr>
///     ORACLE_POKE=<addr>
contract DeployOracles is Script {
    uint32 constant TWAP_PERIOD     = 1800;  // 30 minutes
    uint32 constant MAX_STALENESS   = 7200;  // 2 hours
    uint32 constant POKE_THRESHOLD  = 1800;  // poke if stale > 30 min

    function run() external {
        vm.startBroadcast();

        // 1. Deploy factory
        ICHIVaultOracleFactory factory = new ICHIVaultOracleFactory();
        console.log("Factory:", address(factory));

        // 2. Deploy oracle for each ICHI vault
        address oracleBrz  = factory.deploy(Addresses.ICHI_BRZ,  TWAP_PERIOD, MAX_STALENESS);
        address oracleTgbp = factory.deploy(Addresses.ICHI_TGBP, TWAP_PERIOD, MAX_STALENESS);
        address oracleUsdc = factory.deploy(Addresses.ICHI_USDC, TWAP_PERIOD, MAX_STALENESS);
        address oracleIdrx = factory.deploy(Addresses.ICHI_IDRX, TWAP_PERIOD, MAX_STALENESS);
        address oracleKrwq = factory.deploy(Addresses.ICHI_KRWQ, TWAP_PERIOD, MAX_STALENESS);

        // 3. Deploy poke keeper
        OraclePoke poke = new OraclePoke();
        console.log("Poke:", address(poke));

        // 4. Register all 5 pools in the keeper
        address poolBrz  = IICHIVaultMinimal(Addresses.ICHI_BRZ).pool();
        address poolTgbp = IICHIVaultMinimal(Addresses.ICHI_TGBP).pool();
        address poolUsdc = IICHIVaultMinimal(Addresses.ICHI_USDC).pool();
        address poolIdrx = IICHIVaultMinimal(Addresses.ICHI_IDRX).pool();
        address poolKrwq = IICHIVaultMinimal(Addresses.ICHI_KRWQ).pool();

        poke.addPool(poolBrz,  POKE_THRESHOLD);
        poke.addPool(poolTgbp, POKE_THRESHOLD);
        poke.addPool(poolUsdc, POKE_THRESHOLD);
        poke.addPool(poolIdrx, POKE_THRESHOLD);
        poke.addPool(poolKrwq, POKE_THRESHOLD);

        vm.stopBroadcast();

        console.log("\n=== STEP 3 COMPLETE: Oracles Deployed ===");
        console.log("ORACLE_BRZ:  %s", oracleBrz);
        console.log("ORACLE_TGBP: %s", oracleTgbp);
        console.log("ORACLE_USDC: %s", oracleUsdc);
        console.log("ORACLE_IDRX: %s", oracleIdrx);
        console.log("ORACLE_KRWQ: %s", oracleKrwq);
        console.log("ORACLE_POKE: %s", address(poke));
        console.log("\nPools registered: %s", poke.poolCount());
        console.log("Run 04_DeployBorrowVault.s.sol next.");
    }
}
