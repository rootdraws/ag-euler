// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {InfiniFiLPTOracle} from "./InfiniFiLPTOracle.sol";

/// @title DeployInfiniFiOracles
/// @notice Deploys Euler oracle adapters for all 13 InfiniFi LPT buckets
contract DeployInfiniFiOracles is Script {
    // InfiniFi Core Contracts
    address constant LOCKING_CONTROLLER = 0x1d95cC100D6Cd9C7BbDbD7Cb328d99b3D6037fF7;
    address constant ACCOUNTING = 0x7A5C5dbA4fbD0e1e1A2eCDBe752fAe55f6E842B3;
    address constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    // USD unit of account for Euler (using address(840) for ISO 4217 USD)
    address constant USD = address(840);

    // LPT Token Addresses by bucket
    address constant LPT_1W  = 0x12b004719fb632f1E7c010c6F5D6009Fb4258442;
    address constant LPT_2W  = 0xf1839BeCaF586814D022F16cDb3504ff8D8Ff361;
    address constant LPT_3W  = 0xed2a360FfDC1eD4F8df0bd776a1FfbbE06444a0A;
    address constant LPT_4W  = 0x66bCF6151D5558AfB47c38B20663589843156078;
    address constant LPT_5W  = 0xf0c4A78fEbf4062aeD39A02BE8a4C72E9857d7d1;
    address constant LPT_6W  = 0xb06Cc4548FebfF3D66a680F9c516381c79bC9707;
    address constant LPT_7W  = 0x3A744A6b57984eb62AeB36eB6501d268372cF8bb;
    address constant LPT_8W  = 0xf68b95b7e851170c0e5123a3249dD1Ca46215085;
    address constant LPT_9W  = 0xBB5cA732fAfEd8870F9C0e8406Ad707939c912E1;
    address constant LPT_10W = 0xd15fbf48c6dDdADC9Ef0693B060d80aF51cC26d5;
    address constant LPT_11W = 0xed030a37Ec6EB308A416Dc64dD4b649A2BBE4FCd;
    address constant LPT_12W = 0x3D360aB96B942c1251Ab061178F731eFEbc2d644;
    address constant LPT_13W = 0xbd3f9814eB946E617f1d774A6762cDbec0bf087A;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy all 13 oracles
        address[13] memory lptTokens = [
            LPT_1W, LPT_2W, LPT_3W, LPT_4W, LPT_5W, LPT_6W, LPT_7W,
            LPT_8W, LPT_9W, LPT_10W, LPT_11W, LPT_12W, LPT_13W
        ];

        for (uint32 i = 0; i < 13; i++) {
            uint32 bucket = i + 1;
            InfiniFiLPTOracle oracle = new InfiniFiLPTOracle(
                lptTokens[i],
                USD,
                IUSD,
                LOCKING_CONTROLLER,
                ACCOUNTING,
                bucket
            );
            console.log("LPT_%dW Oracle deployed at:", bucket);
            console.log(address(oracle));
        }

        vm.stopBroadcast();
    }
}
