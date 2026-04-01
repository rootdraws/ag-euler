# Cork Protected Loop on Euler

## Source of Truth

- **Full spec, addresses, formulas, architecture:** `cork-contracts/cork-implementation.md`
- **Deployment status + remaining tasks:** `TODO.md`
- **Frontend pipeline + partner deployments:** `CLAUDE.md`

## Deployed Contracts (Ethereum Mainnet)

| Contract | Address |
|---|---|
| EulerRouter | `0x693B992a576F1260fbD9392389262c2d6D357C3c` |
| CorkOracleImpl | `0xF9d813db87F528bb5b5Ae28567702488f8Bd34FC` |
| CSTZeroOracle | `0x81FfF8C68e6ea10d782d738a3C71110F876C3C06` |
| sUSDe Borrow Vault | `0x53FDab35Fd3aA26577bAc29f098084fCBAbE502f` |
| vbUSDC Collateral Vault | `0xadF7aFDAdaA4cBb0aDAf47C7fD7a9789C0128C6b` |
| cST Collateral Vault | `0xd0f8aC1782d5B80f722bd6aCA4dEf8571A9ddA4c` |
| ProtectedLoopHook | `0x677c2b56E21dDD0851242e62024D8905907db72c` |
| IRMLinearKink | `0x09f8E395c9845A3B5007DB154920bB28727246a3` |
| CorkProtectedLoopLiquidator | `0x1e95cC20ad3917ee523c677faa7AB3467f885CFe` |

## Compilation & Deployment

All contracts live in `cork-contracts/` — a standalone Foundry project.

```bash
cd cork-contracts
forge build
```

Deployment uses 7 sequential scripts. Run in order, pasting each deployed address into `.env` before proceeding:

```bash
source .env && forge script script/01_DeployRouter.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
source .env && forge script script/02_DeployOracles.s.sol ...
source .env && forge script script/03_DeployVaults.s.sol ...
source .env && forge script script/04_WireRouter.s.sol ...
source .env && forge script script/05_DeployHookAndWire.s.sol ...
source .env && forge script script/06_ConfigureCluster.s.sol ...
source .env && forge script script/07_DeployLiquidator.s.sol ...
```

## Liquidation Bot

Shell scripts using `cast` (Foundry). Run on any Linux box (Digital Ocean, etc).

```bash
cd cork-contracts/script/bot
cp .env.example .env   # fill BOT_PRIVATE_KEY, RPC_URL
./setup.sh             # one-time: enables EVC controller, sets operator, approves sUSDe
./run.sh               # polling loop: discovers borrowers, checks health, liquidates
```

The bot sends an EVC batch per underwater position:
1. `liquidator.liquidate(bot, sUsdeVault, violator, vbUSDCVault, maxUint, 0)` — seizes cST (free) + vbUSDC, exercises in Cork, sends sUSDe to bot
2. `sUsdeVault.repay(maxUint, bot)` — repays pulled debt using sUSDe received

Bot wallet needs ETH for gas. Does NOT need pre-funded sUSDe — proceeds arrive atomically within the batch.

## File Index

| Contract | Path |
|---|---|
| CorkOracleImpl | `cork-contracts/src/oracle/CorkOracleImpl.sol` |
| CSTZeroOracle | `cork-contracts/src/oracle/CSTZeroOracle.sol` |
| ERC4626EVCCollateralCork | `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` |
| ProtectedLoopHook | `cork-contracts/src/hook/ProtectedLoopHook.sol` |
| CorkProtectedLoopLiquidator | `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol` |

| Bot Script | Path |
|---|---|
| Environment template | `cork-contracts/script/bot/.env.example` |
| One-time setup | `cork-contracts/script/bot/setup.sh` |
| Polling loop | `cork-contracts/script/bot/run.sh` |

Do not rewrite these. Read the existing files and `cork-contracts/cork-implementation.md` before touching anything.
