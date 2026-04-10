// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AddressesMainnet} from "../clusters/AddressesMainnet.sol";

contract RevokeCurrentOldPool is Script, AddressesMainnet {
    
    address constant OLD_POOL = 0xF7E79AAfaf5d6EFD2907B31023DD3e7e6594A8a8;
    
    function run() external {
        console.log("=== Revoking Current Old Pool ===");
        console.log("Old Pool:", OLD_POOL);
        
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        
        IEVC(EVC).setAccountOperator(WARREN_MULTISIG, OLD_POOL, false);
        console.log("Old pool operator revoked");
        
        vm.stopBroadcast();
    }
}
