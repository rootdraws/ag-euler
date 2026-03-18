# Origin ARM x Euler — Deployment Scripts

Foundry scripts to deploy the Origin ARM/WETH lending market on Euler V2 (Ethereum mainnet).

## What Gets Deployed

| Contract | Purpose |
|---|---|
| KinkIRM | Interest rate model: 0.5% base, 2.5% at 80% util, 50% max |
| EulerRouter | Oracle router — resolves ARM→WETH via `convertToAssets` |
| WETH Borrow Vault | Lending vault where WETH suppliers deposit and borrowers draw |
| ARM Collateral Vault | Collateral vault accepting ARM-WETH-stETH LP tokens |

Unit of account is WETH. The ARM exchange rate oracle uses the EulerRouter's built-in ERC-4626 resolution — no custom oracle adapter needed.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Reference repos cloned in `../reference/` (euler-price-oracle, euler-vault-kit, evk-periphery, ethereum-vault-connector)
- Ethereum mainnet RPC URL
- Funded deployer wallet
- Etherscan API key (for verification)

## Setup

```bash
cp .env.example .env
# Fill in RPC_URL_MAINNET, PRIVATE_KEY, ETHERSCAN_API_KEY
```

## Deployment Steps

Run each script sequentially. Each step logs the deployed address — paste it into `.env` before running the next step.

### Step 1: Deploy KinkIRM

```bash
source .env && forge script script/01_DeployIRM.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Outputs: `KINK_IRM=0x...` — paste into `.env`.

### Step 2: Deploy EulerRouter

```bash
source .env && forge script script/02_DeployRouter.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Outputs: `EULER_ROUTER=0x...` — paste into `.env`.

### Step 3: Deploy WETH Borrow Vault

```bash
source .env && forge script script/03_DeployBorrowVault.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Outputs: `WETH_BORROW_VAULT=0x...` — paste into `.env`.

### Step 4: Deploy ARM Collateral Vault

```bash
source .env && forge script script/04_DeployCollateralVault.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Outputs: `ARM_COLLATERAL_VAULT=0x...` — paste into `.env`.

### Step 5: Wire Oracle

```bash
source .env && forge script script/05_WireOracle.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

No new addresses. Configures `govSetResolvedVault(ARM, true)` on the EulerRouter.

### Step 6: Configure Cluster

```bash
source .env && forge script script/06_ConfigureCluster.s.sol \
  --rpc-url $RPC_URL_MAINNET --private-key $PRIVATE_KEY --broadcast
```

Sets IRM, LTV (90%/93%), liquidation discount (5%), interest fee (10%), and enables ARM as collateral on the WETH borrow vault. Optionally sets fee receiver if `FEE_RECEIVER` is in `.env`.

## Post-Deployment

1. **Labels repo** — Update `origin-labels/1/products.json` with real vault addresses. Push to `rootdraws/ag-euler-origin-labels`.

2. **Frontend config** — Set `NUXT_PUBLIC_CONFIG_ARM_ADAPTER_CONFIG` in `euler-lite-origin/.env`:
   ```
   NUXT_PUBLIC_CONFIG_ARM_ADAPTER_CONFIG='{"0xARM_COLLATERAL_VAULT":{"armContract":"0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6","asset":"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"}}'
   ```

3. **EulerSwap pool** — Origin deploys via [Maglev](https://docs.euler.finance/creator-tools/maglev/) using `eulerSwapV2Factory` at `0xD05213331221fAB8a3C387F2affBb605Bb04DF5F`.

4. **Tighten caps** — Call `setCaps(supplyCap, borrowCap)` on the borrow vault with appropriate AmountCap-encoded values.

5. **ARM CapManager** — If deposit caps are active, Origin must whitelist the Euler Swapper (`0x2Bba09866b6F1025258542478C39720A09B728bF`).

## Key Addresses (Pre-existing on Mainnet)

| Contract | Address |
|---|---|
| EVC | `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` |
| eVaultFactory | `0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e` |
| KinkIRM Factory | `0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9` |
| Swapper | `0x2Bba09866b6F1025258542478C39720A09B728bF` |
| SwapVerifier | `0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7` |
| ARM-WETH-stETH | `0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |

## Risk Parameters

| Parameter | Value | Rationale |
|---|---|---|
| Borrow LTV | 90% | ARM/WETH tightly correlated, exchange rate monotonically increasing |
| Liquidation LTV | 93% | 3% buffer before liquidation |
| Max multiplier | ~9.5x | `1/(1-0.90) - safety margin` |
| IRM base rate | 0.5% APY | Floor rate when utilization is near zero |
| IRM kink rate | 2.5% APY at 80% util | Target equilibrium — well below ARM's ~4.79% yield |
| IRM max rate | 50% APY at 100% util | Steep penalty above kink to discourage over-borrowing |
| Interest fee | 10% | Protocol revenue share on interest |
| Liquidation discount | 5% max | Incentive for liquidators |
