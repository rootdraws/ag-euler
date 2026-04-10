// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

abstract contract AddressesMainnet {
    
    // Tokens
    address internal constant USD = address(840);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    // InfiniFi LPT Tokens (all 13 weekly buckets)
    address internal constant INF_1W = 0x12b004719fb632f1E7c010c6F5D6009Fb4258442;
    address internal constant INF_2W = 0xf1839BeCaF586814D022F16cDb3504ff8D8Ff361;
    address internal constant INF_3W = 0xed2a360FfDC1eD4F8df0bd776a1FfbbE06444a0A;
    address internal constant INF_4W = 0x66bCF6151D5558AfB47c38B20663589843156078;
    address internal constant INF_5W = 0xf0c4A78fEbf4062aeD39A02BE8a4C72E9857d7d1;
    address internal constant INF_6W = 0xb06Cc4548FebfF3D66a680F9c516381c79bC9707;
    address internal constant INF_7W = 0x3A744A6b57984eb62AeB36eB6501d268372cF8bb;
    address internal constant INF_8W = 0xf68b95b7e851170c0e5123a3249dD1Ca46215085;
    address internal constant INF_9W = 0xBB5cA732fAfEd8870F9C0e8406Ad707939c912E1;
    address internal constant INF_10W = 0xd15fbf48c6dDdADC9Ef0693B060d80aF51cC26d5;
    address internal constant INF_11W = 0xed030a37Ec6EB308A416Dc64dD4b649A2BBE4FCd;
    address internal constant INF_12W = 0x3D360aB96B942c1251Ab061178F731eFEbc2d644;
    address internal constant INF_13W = 0xbd3f9814eB946E617f1d774A6762cDbec0bf087A;
    
    // Warren Governance Addresses
    address internal constant WARREN_MULTISIG = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448;
    address internal constant WARREN_TREASURY = 0x5304ebB378186b081B99dbb8B6D17d9005eA0448;
    
    // Oracle Infrastructure
    
    address internal constant USDC_ORACLE = 0x3F777e2bc2212A3FE659514d09DaC7aD751C02A5; // USDCChainlinkOracle adapter
    
    // InfiniFi LPT Oracles (deployed 12/20/2025)
    address internal constant INF_1W_ORACLE = 0xEA8c4CfbEd89B7A44158999659f7dc7394488d45;
    address internal constant INF_2W_ORACLE = 0xfAbd0849d16A3ff43Dc74B2618AdFA57ffDfFdF1;
    address internal constant INF_3W_ORACLE = 0xAcd87207E5cbbbD2064225490875690239235Ec1;
    address internal constant INF_4W_ORACLE = 0xd23c153d7bece6012471c294DF5a85AFbe52b6C2;
    address internal constant INF_5W_ORACLE = 0xA68CF9125C33b7e8238ff7481211D8f443dD1f5F;
    address internal constant INF_6W_ORACLE = 0x405543ea3Fc23e842422989136e9354A000cDeFf;
    address internal constant INF_7W_ORACLE = 0x1eDDfd9c71Dd3D595461f3cc72a35D087EBA730A;
    address internal constant INF_8W_ORACLE = 0xedcd4bdb70d8F4920EE640918158dac8939ece04;
    address internal constant INF_9W_ORACLE = 0x7ABA5e95B81491783fF1FAe41aAfB6a51BDB30Fc;
    address internal constant INF_10W_ORACLE = 0xf06BFA3e6eB6ab7B1E9BbE4ECFF03B68AE10300e;
    address internal constant INF_11W_ORACLE = 0xF370ECF269F113B1bAD1323c1CA907646eaf2b65;
    address internal constant INF_12W_ORACLE = 0x7fc112DABa300E2f28d1Ce529A3D2282C1FDEc0c;
    address internal constant INF_13W_ORACLE = 0x6d4684B5e4A6F7e9611D2a03A3BD56ab100b37eD;
    
    // Deployed Interest Rate Models  
    address internal constant INF_IRM = 0xB71DA37621076D6D6b5281824e7Af8ac183d6838; // Loop-Optimized Kinky IRM (1% → 5.5% @ 80% → 100%)
    
    // Hook Targets
    address internal constant LIQUIDATOR_HOOK = 0x1D34a4f69b7CB81ee77CD3b1D3944513352941d5; // Warren HookTargetAccessControl (deployed 12/20/2025, admin: Warren Multisig)
    
    // Warren Liquidator (Balancer flash loan - deployed 12/14/2025 - uses Euler production Swapper)
    address internal constant WARREN_LIQUIDATOR = 0x2b4be42ffE67aF9FeFb020Ff0891332C1DB1440e;
    address internal constant EULER_SWAPPER = 0x2Bba09866b6F1025258542478C39720A09B728bF; // Euler production Swapper
    address internal constant MINIMAL_ROUTER = 0x6F54D2d2e1f86c2cad653eCE2C4A7De87809bb4D; // Liquidator Router for Eulerswap Pools.

    // Euler V2 Core Infrastructure on Mainnet
    address internal constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address internal constant EVAULT_FACTORY = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address internal constant PROTOCOL_CONFIG = 0x4cD6BF1D183264c02Be7748Cb5cd3A47d013351b;
    
    // Euler V2 Periphery Infrastructure on Mainnet
    address internal constant ORACLE_ROUTER_FACTORY = 0x70B3f6F61b7Bf237DF04589DdAA842121072326A;
    address internal constant KINK_IRM_FACTORY = 0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9;
    address internal constant KINKY_IRM_FACTORY = 0x010102daAB6133d4f8cEB4C8842a70B9899Fc102;
    address internal constant ORACLE_ADAPTER_REGISTRY = 0xA084A7F49723E3cc5722E052CF7fce910E7C5Fe6;
    
    // Euler V2 Lens Contracts on Mainnet
    address internal constant ORACLE_LENS = 0x0C47736aaBEE757AB8C8F60776741e39DBf3F183;
    
    // Warren Deployed Vaults (deployed 12/20/2025 - block 24058002)
    address internal constant INF_1W_VAULT = 0xE232C49e0B43E5f50Ca6797d6AE761e0976fd644; // liUSD-1w vault
    address internal constant INF_4W_VAULT = 0xb04ad3337dc567a68a6f4D571944229320Ad1740; // liUSD-4w vault
    address internal constant INF_8W_VAULT = 0x5a2d1F5Fe6Eb8514570CA0aB3d0C6b244a511B15; // liUSD-8w vault
    address internal constant USDC_VAULT = 0x4cBcfD04Ad466aa4999Fe607fc1864B1b8A400E4; // USDC Loop vault
    address internal constant USDC_CREDIT_POOL = 0xDc6D457b6cf5dfaD338a7982608e3306FD9474c7; // USDC Credit Pool vault (deployed 12/25/2025)
    address internal constant WARREN_EULER_EARN = 0x2f3558213c050731b3ae632811eFc1562d3F91CC; // Infinifi USDC Earn vault (deployed 12/26/2025 - no timelock)

    // EulerSwap Infrastructure
    address internal constant EULER_SWAP_FACTORY = 0xD05213331221fAB8a3C387F2affBb605Bb04DF5F;
    address internal constant USDC_CREDIT_POOL_lIUSD_4W_EULERSWAP_POOL = 0x6FCFdf043FAef634e0Ae7dC7573cF308fDBB28A8; // USDC Credit Pool <> liUSD-4W EulerSwap pool

    // InfiniFi Core (for oracle pricing)
    address internal constant LOCKING_CONTROLLER = 0x1d95cC100D6Cd9C7BbDbD7Cb328d99b3D6037fF7; 
    address internal constant ACCOUNTING = 0x7A5C5dbA4fbD0e1e1A2eCDBe752fAe55f6E842B3;
    address internal constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c; 
}
