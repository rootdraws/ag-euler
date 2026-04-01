# Balancer × Euler V2 Contracts (Monad)

Foundry project for deploying and configuring Euler V2 lending vaults backed by Balancer V3 BPT collateral on Monad (chain 143).

## What's here

- **Deployment scripts** (`script/01-07`): Deploy IRM, oracle router, borrow vaults, collateral vaults, LP oracles, cluster config, and enable operations.
- **BalancerBptAdapter** (`src/BalancerBptAdapter.sol`): Custom adapter for single-sided Balancer V3 liquidity provision with ERC4626 wrapping. Used by the Euler Swapper for multiply/leverage AND called directly by users in the Loop Zap flow.
- **Adapter deploy scripts** (`script/08, 09`): Deploy per-pool adapters for Pool 1 and Pool 4.
- **Test scripts** (`script/Test*.s.sol`): Fork tests for adapter, zap in/out, and EVC batch flows.

## Deployed addresses

| Contract | Address |
|---|---|
| AUSD KinkIRM (3.5% at 93% kink) | `0x2B23EC0C6851cC14162546a6860a865f1fc4aE58` |
| WMON KinkIRM (9% at 93% kink) | `0x36aF0910227ce45601511F8F15CCE9BBb0838473` |
| EulerRouter | `0x77C3b512d1d9E1f22EeCde73F645Da14f49CeC73` |
| AUSD Borrow Vault | `0x438cedcE647491B1d93a73d491eC19A50194c222` |
| WMON Borrow Vault | `0x75B6C392f778B8BCf9bdB676f8F128b4dD49aC19` |
| Pool 1 Vault (wnAUSD/wnUSDC/wnUSDT0) | `0x5795130BFb9232C7500C6E57A96Fdd18bFA60436` |
| Pool 2 Vault (sMON/wnWMON) | `0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5` |
| Pool 3 Vault (shMON/wnWMON) | `0x6660195421557BC6803e875466F99A764ae49Ed7` |
| Pool 4 Vault (wnLOAZND/AZND/wnAUSD) | `0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92` |
| Pool 1 BPT Adapter | `0xC904aAB60824FC8225F6c8843897fFba14c8Bf98` |
| Pool 4 BPT Adapter | `0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832` |

### BPT tokens

| Pool | BPT Address |
|---|---|
| Pool 1 (Stableswap USDT0/AUSD/USDC) | `0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b` |
| Pool 2 (sMON/WMON Kintsu) | `0x3475Ea1c3451a9a10Aeb51bd8836312175B88BAc` |
| Pool 3 (shMON/WMON Fastlane) | `0x150360c0eFd098A6426060Ee0Cc4a0444c4b4b68` |
| Pool 4 (AZND/AUSD/LOAZND) | `0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3` |

### External contracts

| Contract | Address |
|---|---|
| Balancer V3 Router | `0x9dA18982a33FD0c7051B19F0d7C76F2d5E7e017c` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Euler Swapper | `0xB6D7194fD09F27890279caB08d565A6424fb525D` |
| Euler SwapVerifier | `0x65bF068c88e0f006f76b871396B4DB1150dd9EAD` |
| AUSD | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` (6 decimals) |
| WMON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` (18 decimals) |

Full address list in `.env`.

## How the adapter works

Balancer V3 pools on Monad use ERC4626-wrapped tokens (wnAUSD, wnUSDT0, etc.). Enso Finance can't route into these pools for the forward direction. The `BalancerBptAdapter` handles:

1. Pull underlying token (e.g. AUSD) from caller (`msg.sender`)
2. Wrap via ERC4626 deposit (AUSD → wnAUSD) if needed
3. Permit2-approve wrapped token to Balancer Router
4. Call `addLiquidityUnbalanced` for single-sided entry
5. Return BPT to `msg.sender`

The adapter is used in two ways:
- **Within EVC batch**: Invoked via Euler Swapper's `GenericHandler` for multiply positions. `msg.sender` = Swapper.
- **Direct user call**: Called directly by user wallets in the Loop Zap flow (Pool 4 only). `msg.sender` = user EOA.

One adapter per pool, configured at deploy time, stateless.

## Loop Zap architecture

The Loop Zap uses a **two-transaction design** because Monad's SwapVerifier lacks `transferFromSender` (see `balancer-claude.md` lesson #19).

1. **Tx 1 (Zap In):** Convert AUSD/WMON → BPT into user's wallet. Pools 1-3 use Enso, Pool 4 uses the adapter directly.
2. **Tx 2 (Multiply):** Deposit BPT collateral and open leveraged position via `buildMultiplyPlan()` EVC batch.

**Status:** Tx 1 works. Tx 2 is failing — root cause undiagnosed. See `balancer-claude.md` for details.

## Quick start

```bash
# Install deps
forge install

# Build
forge build

# Deploy (example: Pool 4 adapter)
source .env && forge script script/08_DeployBptAdapter.s.sol \
  --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
  --broadcast --gas-estimate-multiplier 400

# Fork test
source .env && forge script script/TestLoopZap.s.sol \
  --rpc-url $RPC_URL_MONAD --gas-estimate-multiplier 400 -vvvv
```

Always use `--gas-estimate-multiplier 400` on Monad — default gas estimates are 3-4x too low.

## Script inventory

| Script | Purpose |
|---|---|
| `01_DeployIRM.s.sol` | KinkIRM deployment |
| `02_DeployRouter.s.sol` | EulerRouter deployment |
| `03_DeployBorrowVaults.s.sol` | AUSD and WMON borrow vault creation |
| `04_DeployCollateralVaults.s.sol` | BPT collateral vault creation (4 pools) |
| `05_DeployOracles.s.sol` | LP oracle and Chainlink adapter setup |
| `06_ConfigureCluster.s.sol` | LTV, oracle config, governor settings |
| `07_EnableOperations.s.sol` | Enable vault operations via `setHookConfig` |
| `08_DeployBptAdapter.s.sol` | Pool 4 BPT adapter |
| `09_DeployBptAdapterPool1.s.sol` | Pool 1 BPT adapter |
| `10_UpdateIRM.s.sol` | Deploy split IRMs (AUSD 3.5%, WMON 9%) and update borrow vaults |
| `TestLoopZap.s.sol` | EVC batch fork test (diagnosed missing `transferFromSender`) |
| `TestAdapter.s.sol` | Adapter integration test |
| `TestAdapterZapOut*.s.sol` | ZapOut tests (discovered pool hook rejection) |
| `TestZapOut3.s.sol` | Enso-based zapOut test |

## AI context

See `balancer-claude.md` for full deployment learnings, adapter architecture details, and the Loop Zap two-transaction design rationale.
