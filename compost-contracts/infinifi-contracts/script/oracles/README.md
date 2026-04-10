# InfiniFi LPT Oracle Adapters for Euler

Euler PriceOracle adapters for InfiniFi Locked Position Tokens (LPT).

## Overview

Each LPT represents a locked position in InfiniFi with a specific unlock duration (1-13 weeks). The oracle returns the USD price by:

1. Fetching the exchange rate from `LockingController.exchangeRate(bucket)` (LPT → iUSD)
2. Fetching the iUSD price from `Accounting.price(iUSD)` (iUSD → USD)
3. Combining: `price = exchangeRate * iUSDPrice / 1e18`

## Contracts

| Contract | Address |
|----------|---------|
| LockingController | `0x1d95cC100D6Cd9C7BbDbD7Cb328d99b3D6037fF7` |
| Accounting | `0x7A5C5dbA4fbD0e1e1A2eCDBe752fAe55f6E842B3` |
| iUSD | `0x48f9e38f3070AD8945DFEae3FA70987722E3D89c` |

## LPT Tokens

| Bucket | Token Address |
|--------|---------------|
| 1 week | `0x12b004719fb632f1E7c010c6F5D6009Fb4258442` |
| 2 week | `0xf1839BeCaF586814D022F16cDb3504ff8D8Ff361` |
| 3 week | `0xed2a360FfDC1eD4F8df0bd776a1FfbbE06444a0A` |
| 4 week | `0x66bCF6151D5558AfB47c38B20663589843156078` |
| 5 week | `0xf0c4A78fEbf4062aeD39A02BE8a4C72E9857d7d1` |
| 6 week | `0xb06Cc4548FebfF3D66a680F9c516381c79bC9707` |
| 7 week | `0x3A744A6b57984eb62AeB36eB6501d268372cF8bb` |
| 8 week | `0xf68b95b7e851170c0e5123a3249dD1Ca46215085` |
| 9 week | `0xBB5cA732fAfEd8870F9C0e5123a3249dD1Ca46215` |
| 10 week | `0xd15fbf48c6dDdADC9Ef0693B060d80aF51cC26d5` |
| 11 week | `0xed030a37Ec6EB308A416Dc64dD4b649A2BBE4FCd` |
| 12 week | `0x3D360aB96B942c1251Ab061178F731eFEbc2d644` |
| 13 week | `0xbd3f9814eB946E617f1d774A6762cDbec0bf087A` |

## Setup

```bash
# Install dependencies
forge install euler-xyz/euler-price-oracle
forge install foundry-rs/forge-std

# Build
forge build
```

## Deploy

```bash
# Set environment variables
export PRIVATE_KEY=<your_private_key>
export ETH_RPC_URL=<your_rpc_url>
export ETHERSCAN_API_KEY=<your_etherscan_key>

# Deploy all 13 oracles
forge script script/DeployInfiniFiOracles.s.sol:DeployInfiniFiOracles \
    --rpc-url $ETH_RPC_URL \
    --broadcast \
    --verify
```

## Price Mechanics

- **No heartbeat**: Prices are fully on-chain, computed fresh every block
- **Exchange rate updates when**:
  - Users deposit/withdraw from a bucket
  - `depositRewards()` is called (increases rate)
  - `applyLosses()` is called (decreases rate)
- **iUSD price**: Currently fixed at 1e18 ($1.00)

## Risk Considerations

- Exchange rate can decrease via `applyLosses()`
- `maxLossPercentage` is set to 0.999999e18 (99.9999% max loss before pause)
- Transfer restrictions on LPT tokens may complicate liquidations
