# Warren Liquidator v4

No flash loan. Atomic debt pattern like Euler's liquidator.

## How it works

1. Enable controller (liability vault controls our account)
2. Enable collateral 
3. Liquidate (creates debt for us, gives us collateral shares)
4. Redeem shares → tokens go directly to Euler Swapper
5. Swapper multicall (swaps + repays our debt atomically)
6. Disable controller
7. Disable collateral

No capital needed. Debt is created and repaid in same atomic EVC batch.

## Key fix from v3

API call now uses `isRepay=true` with proper debt params so swapper handles repayment.

## Deploy

```bash
cd warren-deploy
cp -r liquidator-v4/* script/liquidator/

forge script script/liquidator/DeployWarrenLiquidator.s.sol:DeployWarrenLiquidator \
  --rpc-url $DEPLOYMENT_RPC_URL_1 \
  --broadcast
```

## Grant Role

```bash
cast send 0x5e306F12E7eBCC0F7d3e5639Dc8f003791D76515 \
  "grantRole(bytes4,address)" \
  0xc1342574 \
  <NEW_LIQUIDATOR_ADDRESS> \
  --private-key $DEPLOYER_KEY \
  --rpc-url $DEPLOYMENT_RPC_URL_1
```

## Update Keeper

1. Copy `liquidationKeeper.ts` to `UI-Droplet/src/services/`
2. Update `.env`:
```
LIQUIDATOR_ADDRESS=<NEW_ADDRESS>
```
3. Restart: `pm2 restart ui-droplet`
