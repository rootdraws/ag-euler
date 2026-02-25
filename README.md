# Cork Protected Loop on Euler

## Source of Truth

- **Full spec, addresses, formulas, architecture:** `implementation.md`
- **Deployment runbook + remaining gaps:** `TODO.md`
- **Frontend pipeline + partner deployments:** `CLAUDE.md`

## Compilation

All contracts live in `cork-contracts/` — a standalone Foundry project.

```bash
cd cork-contracts
forge build
source .env && forge script script/CorkProtectedLoop.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## File Index

| Contract | Path |
|---|---|
| CorkOracleImpl | `cork-contracts/src/oracle/CorkOracleImpl.sol` |
| CSTZeroOracle | `cork-contracts/src/oracle/CSTZeroOracle.sol` |
| ERC4626EVCCollateralCork | `cork-contracts/src/vault/ERC4626EVCCollateralCork.sol` |
| ProtectedLoopHook | `cork-contracts/src/hook/ProtectedLoopHook.sol` |
| CorkProtectedLoopLiquidator | `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol` |
| CorkProtectedLoop.s.sol | `cork-contracts/script/CorkProtectedLoop.s.sol` |

Do not rewrite these. Read the existing files and `implementation.md` before touching anything.
