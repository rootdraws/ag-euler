# BSC (Chain 56) — USDT + BNB Cross-Margin Cluster

Deployed 2026-04-15. 2-market cross-margin cluster. Both sides share a single `EulerRouter`.

## Markets

| # | Borrow | Collateral | Borrow LTV | Liq LTV |
|---|---|---|---|---|
| 1 | USDT | BNB | 75% | 80% |
| 2 | BNB  | USDT | 88% | 91% |

## Deployed Addresses

### This deployment

| Contract | Address |
|---|---|
| EulerRouter | `0x37EB39a240FA7A2D2E6b442638bE9CAbAaC92D33` |
| USDT KinkIRM (Base=0%, Kink(90%)=8%, Max=150%) | `0xd421645961B4D723097F51cd5d78dBAD36486DA4` |
| BNB KinkIRM (Base=0.5%, Kink(80%)=8%, Max=80%) | `0x882bb0651fa6454d1E938061bd2Db822d1Fb45f8` |
| USDT Borrow Vault | `0x0070e145f606E3EF2b358c15dc6DF882EE4F06C8` |
| BNB Borrow Vault | `0x82e642Bb61Ec9f2ba5364A386B03cc8d59661f76` |
| USDT Collateral Vault | `0xe4fe8f35afe3B0a0E19992514350A2d759160600` |
| BNB Collateral Vault | `0xe66B415eA3814FBB58A9313e054a2a1e6d44dBd0` |

Governor (all vaults + router): `0x501107fe590c8F9b81c00b81867fD19e0d9c0253` (AG dev wallet)
Fee receiver: same.

### Euler Platform (BSC, pre-existing)

| Contract | Address |
|---|---|
| EVC | `0xb2E5a73CeE08593d1a076a2AE7A6e02925a640ea` |
| eVaultFactory | `0x7F53E2755eB3c43824E162F7F6F087832B9C9Df6` |
| KinkIRM Factory | `0x40739156B75b477f5b4f2D671655492B535B59d2` |
| Oracle Router Factory | `0xbe83f65e5e898D482FfAEA251B62647c411576F1` |
| Swapper | `0xAE4043937906975E95F885d8113D331133266Ee4` |
| SwapVerifier | `0xA8a4f96EC451f39Eb95913459901f39F5E1C068B` |

### Oracle Adapters (pre-existing on BSC)

| Feed | Adapter |
|---|---|
| USDT/USD Chainlink | `0x7e262cD6226328AaF4eA5C993a952E18Dd633Bc8` |
| WBNB/USD Chainlink | `0xC8228b83F1d97a431A48bd9Bc3e971c8b418d889` |

## Tokens

| Token | Address | Decimals |
|---|---|---|
| USDT | `0x55d398326f99059fF775485246999027B3197955` | **18** (not 6!) |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | 18 |

## Deployment Notes

- RPC: `https://bsc-dataseed.bnbchain.org` (official Binance public) — **NodeReal and Dwellir were both unusable**: NodeReal public tier hit rate limits on step 5+, Dwellir is a pruned node that can't simulate recent state.
- Steps 4 and 5 each had one tx silently fail to broadcast due to RPC rate-limit on receipt polling. Recovered via direct `cast send` to complete the missing call. Verified all state on-chain before continuing.
- All 4 vaults activated via `setHookConfig(address(0), 0)` in step 6 (per CLAUDE.md gotcha #6).
- USDT is 18 decimals on BSC. Cap mantissa/exp encoded accordingly (USDT_CAP=12822 = 200 × 10^22).

## Run Command Template

```
source .env && forge script script/0N_Name.s.sol \
  --rpc-url $RPC_URL_BSC \
  --account dev --sender $DEPLOYER \
  --password-file ~/.foundry/keystores/dev.pw \
  --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
```

Password file `~/.foundry/keystores/dev.pw` contains the keystore password (chmod 600, outside any repo).
