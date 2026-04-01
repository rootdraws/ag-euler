# Balancer BPT Vault Deployment — AI Context

Deployment completed on Monad (chain 143). This file covers deployed contracts, the BalancerBptAdapter, the Loop Zap architecture, and hard-won lessons.

---

## Deployed Addresses

### Euler Vaults

| Contract | Address |
|---|---|
| KinkIRM (original, unused) | `0x2CB88c8E5558380077056ECb9DDbe1e00fdbC402` |
| AUSD KinkIRM (3.5% at 93% kink) | `0x2B23EC0C6851cC14162546a6860a865f1fc4aE58` |
| WMON KinkIRM (9% at 93% kink) | `0x36aF0910227ce45601511F8F15CCE9BBb0838473` |
| EulerRouter | `0x77C3b512d1d9E1f22EeCde73F645Da14f49CeC73` |
| AUSD Borrow Vault | `0x438cedcE647491B1d93a73d491eC19A50194c222` |
| WMON Borrow Vault | `0x75B6C392f778B8BCf9bdB676f8F128b4dD49aC19` |
| Pool1 Vault (wnAUSD/wnUSDC/wnUSDT0) | `0x5795130BFb9232C7500C6E57A96Fdd18bFA60436` |
| Pool2 Vault (sMON/wnWMON) | `0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5` |
| Pool3 Vault (shMON/wnWMON) | `0x6660195421557BC6803e875466F99A764ae49Ed7` |
| Pool4 Vault (wnLOAZND/AZND/wnAUSD) | `0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92` |

LP Oracles and ChainlinkOracle adapters in `.env`.

### BPT Token Addresses

| Pool | BPT Address |
|---|---|
| Pool 1 (Stableswap USDT0/AUSD/USDC) | `0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b` |
| Pool 2 (sMON/WMON Kintsu) | `0x3475Ea1c3451a9a10Aeb51bd8836312175B88BAc` |
| Pool 3 (shMON/WMON Fastlane) | `0x150360c0eFd098A6426060Ee0Cc4a0444c4b4b68` |
| Pool 4 (AZND/AUSD/LOAZND) | `0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3` |

### Balancer BPT Adapters

| Contract | Address | Pool |
|---|---|---|
| Pool 1 BPT Adapter | `0xC904aAB60824FC8225F6c8843897fFba14c8Bf98` | wnUSDT0/wnAUSD/wnUSDC |
| Pool 4 BPT Adapter | `0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832` | AZND/wnAUSD/wnLOAZND |

### Borrow Assets

| Asset | Address | Decimals |
|---|---|---|
| AUSD | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` | 6 |
| WMON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` | 18 |

### External Contracts (Monad)

| Contract | Address |
|---|---|
| Balancer V3 Router | `0x9dA18982a33FD0c7051B19F0d7C76F2d5E7e017c` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Euler Swapper | `0xB6D7194fD09F27890279caB08d565A6424fb525D` |
| Euler SwapVerifier | `0x65bF068c88e0f006f76b871396B4DB1150dd9EAD` |

---

## BalancerBptAdapter (`src/BalancerBptAdapter.sol`)

### Purpose

Performs single-sided Balancer V3 liquidity provision with optional ERC4626 wrapping. Used in two contexts:

1. **Loop Zap Tx 1 (Pool 4 only):** Called directly by the user's wallet to convert AUSD → BPT, sending BPT back to the user's wallet. The adapter pulls tokens from `msg.sender` via `transferFrom` and returns BPT to `msg.sender`.

2. **Multiply Tx 2 (Pools 1 & 4):** Called within an EVC batch via the Euler Swapper's `GenericHandler`. The Swapper is `msg.sender`; tokens flow from Swapper → adapter → Swapper.

### Why it exists

Enso Finance cannot route into Pool 1 or Pool 4 for the forward direction (underlying → BPT) because these pools use ERC4626-wrapped tokens (wnAUSD, wnUSDT0, etc.) that have no direct DEX liquidity. The adapter bridges this gap by handling wrapping + single-sided Balancer deposit in one call.

### Architecture (Multiply context — within EVC batch)

```
EVC Batch (atomic):
  1. Euler borrow vault → borrow AUSD → send to Swapper
  2. Swapper.multicall([
       swap(GenericHandler → adapter.zapIn) → AUSD becomes BPT in Swapper,
       deposit(BPT, collateralVault, account) → BPT into Euler vault
     ])
  3. SwapVerifier.verifyAmountMinAndSkim → ensures enough BPT was deposited
```

The Swapper inherits GenericHandler (not delegatecall — direct inheritance). When GenericHandler calls `target.call(payload)`, `msg.sender` in the adapter is the **Swapper address**. The adapter pulls tokens from the Swapper and sends output back to the Swapper.

### Architecture (Loop Zap Tx 1 context — Pool 4 only)

```
User wallet (EOA):
  1. User approves AUSD to adapter address (standard ERC20 approve)
  2. User calls adapter.zapIn(tokenIndex, amount, minBptOut)
  3. Adapter pulls AUSD from user, wraps, deposits into Balancer
  4. BPT is transferred back to user's wallet
```

### Routing matrix

| Direction | Pool 1 | Pool 2 | Pool 3 | Pool 4 |
|---|---|---|---|---|
| **Loop Zap Tx 1** (user token → BPT to wallet) | Enso | Enso | Enso | Adapter |
| **Multiply Tx 2** (borrow → BPT within EVC batch) | Adapter | Enso | Enso | Adapter |
| **Repay** (BPT → borrow asset) | Enso | Enso | Enso | Enso |

Enso can route BPT → underlying for all 4 pools (reverse direction). The adapter's `zapOut` function exists but is **not used in production** because Balancer V3 pool hooks block `removeLiquiditySingleTokenExactIn` (reverts with `AfterRemoveLiquidityHookFailed`).

### Key implementation details

1. **Permit2 for addLiquidity**: Balancer V3 Router uses Permit2 for pulling tokens during `addLiquidity`, not standard ERC20 approve. The constructor pre-approves all pool tokens to Permit2 (`IERC20.approve(PERMIT2, max)`). Before each addLiquidity call, `IPermit2.approve(token, router, maxAmount, maxExpiration)` is called.

2. **Direct approve for removeLiquidity**: Balancer V3 Router uses standard ERC20 approve (not Permit2) for pulling BPT during `removeLiquidity`.

3. **Return type mismatch**: The Balancer V3 Router's `addLiquidityUnbalanced` returns `(uint256 bptAmountOut)`, NOT `(uint256[] memory)`. Using the wrong return type causes a silent ABI decode failure.

4. **One adapter per pool**: Each adapter is configured at deploy time with the pool address, router, and per-token config (poolToken, underlying, needsWrap). Stateless between calls.

### Deploying a new adapter

```bash
# Edit the deploy script with the correct pool/token addresses
# Then:
source .env && forge script script/08_DeployBptAdapter.s.sol \
  --rpc-url $RPC_URL_MONAD --private-key $PRIVATE_KEY \
  --broadcast --gas-estimate-multiplier 400
```

### Frontend config

The frontend reads adapter config from `NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG` — a JSON map of collateral vault address → `{adapter, tokenIndex}`:

```
NUXT_PUBLIC_CONFIG_BPT_ADAPTER_CONFIG={"0xVaultAddr":{"adapter":"0xAdapterAddr","tokenIndex":1}}
```

---

## Loop Zap — Two-Transaction Architecture

### Why two transactions

The Monad deployment of Euler's `SwapVerifier` (`0x65bF068c88e0f006f76b871396B4DB1150dd9EAD`) is **stripped-down**. It only has two functions:

- `verifyAmountMinAndSkim` (`0x51ab605c`)
- `verifyDebtMax` (`0x0aa4c91d`)

It is **missing `transferFromSender`** (`0xbe6f2b2f`), which is required to pull user tokens into the EVC batch atomically. This was confirmed via bytecode analysis with `cast code` and `cast 4byte-decode`. The SwapVerifier is immutable — it cannot be upgraded.

A single-batch design (user token → BPT → collateral → borrow → loop, all in one EVC batch) fails at the `transferFromSender` step with `EVC_EmptyError()`.

### Two-transaction design

**Tx 1 — Zap In:** Convert user's raw tokens (AUSD or WMON) into BPT, depositing BPT into the user's wallet.

| Pool | Method |
|---|---|
| Pool 1, 2, 3 | Enso `/route` API (`fromAddress=user`, `receiver=user`) |
| Pool 4 | Direct call to `BalancerBptAdapter.zapIn()` |

Requires prior ERC20 approve: to Enso Router for pools 1-3, to the adapter address for pool 4.

**Tx 2 — Multiply:** Use existing `buildMultiplyPlan()` (in `useEulerOperations/vault.ts`) to deposit BPT as collateral and open a leveraged position. This operates vault-to-vault within the EVC batch and does NOT need `transferFromSender`.

### Current status (as of March 2026)

- **Tx 1 (Zap In): WORKING.** Tested on-chain — user receives BPT in wallet.
- **Tx 2 (Multiply): FAILING.** The multiply transaction reverts after a successful zap in. Root cause is not yet diagnosed. Likely candidates:
  - Missing BPT approval from user wallet to the collateral vault before `buildMultiplyPlan` calls `vault.deposit`
  - Quote generation mismatch (the `multiplyQuote` in `useLoopZap.ts` may not match the actual BPT amount received)
  - Sub-account resolution issue between Tx 1 and Tx 2

---

## Contract Verification (Completed March 2026)

All contracts verified on MonadScan via Etherscan V2 API. See lesson #23 for the verification workflow.

### Source-verified contracts

| Contract | Address |
|---|---|
| EVault Implementation | `0xef17750D3a162E28a302E266c474ff8989d60ECD` |
| EulerRouter | `0x77C3b512d1d9E1f22EeCde73F645Da14f49CeC73` |
| ChainlinkOracle (Pool 1) | `0x447B8A9F8438Fd85058c5d38a4c3Ac74A1ce1C82` |
| ChainlinkOracle (Pool 2) | `0xD84D227b2965a011561FDD6C2782bA74d4551c51` |
| ChainlinkOracle (Pool 3) | `0x3e22B269BAE7C670676df9314F15CE65aDAeBb80` |
| ChainlinkOracle (Pool 4) | `0x4E06DcA43132f457B91B8b624aE562Af0dE2d305` |
| BPT Adapter Pool 1 | `0xC904aAB60824FC8225F6c8843897fFba14c8Bf98` |
| BPT Adapter Pool 4 | `0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832` |

### Source-verified vault proxies (BeaconProxy)

All 6 vault proxies source-verified as `BeaconProxy` (from `euler-vault-kit/src/GenericFactory/BeaconProxy.sol`). MonadScan auto-detects the proxy pattern and links to the EVault implementation, showing Read/Write as Proxy on each contract's tab.

Verified using `forge verify-contract` with `--verifier-url` (see lesson #23). Constructor args encode `abi.encodePacked(bytes4(0), asset, oracle, unitOfAccount)` as an ABI-encoded `bytes` parameter.

| Vault | Address |
|---|---|
| AUSD Borrow Vault | `0x438cedcE647491B1d93a73d491eC19A50194c222` |
| WMON Borrow Vault | `0x75B6C392f778B8BCf9bdB676f8F128b4dD49aC19` |
| Pool 1 Vault | `0x5795130BFb9232C7500C6E57A96Fdd18bFA60436` |
| Pool 2 Vault | `0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5` |
| Pool 3 Vault | `0x6660195421557BC6803e875466F99A764ae49Ed7` |
| Pool 4 Vault | `0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92` |

### Already verified by Euler team

| Contract | Address |
|---|---|
| GenericFactory (EVault Factory) | `0xba4Dd672062dE8FeeDb665DD4410658864483f1E` |

### Not verified (factory-deployed singletons, source not in our repo)

KinkIRM x3 (`0x2CB88c8E...`, `0x2B23EC08...`, `0x36aF0910...`) — deployed by KinkIRMFactory.
LP Oracles x4 (`0x16E9E2fF...`, `0x388A1149...`, `0x2AF160Be...`, `0x6A4B6AF2...`) — deployed by StableLPOracleFactory.

### Key files

| File | Purpose |
|---|---|
| `euler-lite-balancer/composables/useLoopZap.ts` | Two-phase orchestrator: `executeZapIn()` → `executeMultiply()` |
| `euler-lite-balancer/composables/useEulerOperations/vault.ts` | `buildMultiplyPlan()` — builds EVC batch for leverage position |
| `euler-lite-balancer/composables/useEnsoRoute.ts` | Enso route fetching, adapter quote/encode helpers |
| `euler-lite-balancer/composables/borrow/useMultiplyForm.ts` | Standard multiply form (works for direct BPT deposits) |
| `euler-lite-balancer/pages/loop-zap/index.vue` | UI with two-step progress indicator |

---

## Deployment Scripts

| Script | Purpose |
|---|---|
| `01_DeployIRM.s.sol` | KinkIRM deployment |
| `02_DeployRouter.s.sol` | EulerRouter deployment |
| `03_DeployBorrowVaults.s.sol` | AUSD and WMON borrow vault creation |
| `04_DeployCollateralVaults.s.sol` | BPT collateral vault creation (4 vaults) |
| `05_DeployOracles.s.sol` | LP oracle and Chainlink adapter setup |
| `06_ConfigureCluster.s.sol` | LTV, oracle config, governor config |
| `07_EnableOperations.s.sol` | `setHookConfig(address(0), 0)` on each vault |
| `08_DeployBptAdapter.s.sol` | Pool 4 BPT adapter deployment |
| `09_DeployBptAdapterPool1.s.sol` | Pool 1 BPT adapter deployment |
| `10_UpdateIRM.s.sol` | Deploy split IRMs (AUSD 3.5%, WMON 9%) and update borrow vaults |
| `TestLoopZap.s.sol` | Fork test for the single-batch EVC flow (used to diagnose `transferFromSender` missing) |
| `TestAdapter.s.sol` | Adapter integration test |
| `TestAdapterZapOut.s.sol` / `TestAdapterZapOut2.s.sol` | ZapOut test scripts (discovered hook rejection) |
| `TestZapOut3.s.sol` | Enso-based zapOut test |

---

## Hard-Won Lessons

### 1. `[etherscan]` in foundry.toml breaks `forge script` on unknown chains

The `[etherscan]` block with `chain = "143"` causes `Error: Chain 143 not supported` even for dry runs with no `--verify` flag. Remove the entire `[etherscan]` section.

### 2. EVault `createProxy` trailingData must be exactly 60 bytes

`GenericFactory.createProxy(implementation, upgradeable, trailingData)` prepends `bytes4(0)` to trailingData, making it 64 bytes (`PROXY_METADATA_LENGTH`). The vault's `initialize()` checks `msg.data.length == 4 + 32 + 64` and reverts with `E_ProxyMetadata()` if wrong.

Correct format: `abi.encodePacked(asset, oracle, unitOfAccount)` = 3 x 20 bytes = 60 bytes.

For **borrow vaults**: pass real oracle (EulerRouter) and unitOfAccount.
For **collateral vaults**: pass `address(0)` for both oracle and unitOfAccount — they're unused.

### 3. `forge script` gas estimates are ~3-4x too low on Monad

Always use `--gas-estimate-multiplier 400` for all `forge script --broadcast` calls on Monad.

### 4. Never mix deploy + config in the same forge script on Monad

Deploy in one script, configure in the next. Read addresses from `.env` via `vm.envAddress()`.

### 5. `setLTV` takes `uint32 rampDuration`, not `uint16`

```solidity
function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
```

### 6. Oracle for collateral vaults is set on the BORROW vault

The EulerRouter lives on the borrow vault. When Euler prices collateral, it uses the borrow vault's configured oracle.

### 7. IRM factory: use KinkIRM, not KinkyIRM

`kinkIRMFactory` (`0x05Cc...`): 4-param standard 2-slope linear. This is what the calculator outputs.

### 8. `ethereum-vault-connector` remapping must point to `src/`

Add to `remappings.txt`:
```
ethereum-vault-connector/=lib/euler-price-oracle/lib/ethereum-vault-connector/src/
```

### 9. Solidity requires EIP-55 checksummed addresses

### 10. `cast send` works when `forge script --broadcast` fails on Monad

### 11. Monad EVault factory initializes vaults with operations disabled

Call `setHookConfig(address(0), 0)` on each vault after deployment.

### 12. Frontend CSP blocks chain default RPCs

Route wagmi through the app's server proxy (`/api/rpc/<chainId>`).

### 13. TOS signing must be explicitly bypassed when unset

Add early return in `prepareTos()` when `enableTermsOfUseSignature` is false.

### 14. EulerRouter requires `govSetResolvedVault` for collateral vaults

```bash
for VAULT in $POOL1_VAULT $POOL2_VAULT $POOL3_VAULT $POOL4_VAULT; do
  cast send $EULER_ROUTER "govSetResolvedVault(address,bool)" $VAULT true \
    --private-key $PRIVATE_KEY --rpc-url $RPC_URL_MONAD
done
```

### 15. Balancer V3 Router uses Permit2 for addLiquidity, ERC20 approve for removeLiquidity

Two different approval patterns for the same contract. For deposits: ERC20 approve token → Permit2, then `Permit2.approve(token, router, amount, expiration)`. For BPT removal: direct `BPT.approve(router, amount)`.

### 16. Balancer V3 `addLiquidityUnbalanced` returns `uint256`, not `uint256[]`

The Solidity interface must match exactly or ABI decoding fails silently. The Router returns a single `uint256 bptAmountOut`. Declaring the return as `uint256[] memory` causes the adapter to revert with empty data after the Router call succeeds.

### 17. Pool hooks can block `removeLiquiditySingleTokenExactIn`

Balancer V3 pools can have hooks that reject certain operations. Our pools' `onAfterRemoveLiquidity` hook returns `false` for single-sided removals, causing `AfterRemoveLiquidityHookFailed()`. This affects ALL callers, not just the adapter. Use Enso for the reverse direction — it routes through alternative paths (AMMs, proportional remove, etc.).

### 18. Adapter iterations: expect multiple deploys

The adapter went through 5 versions during testing due to Permit2 discovery, ABI mismatch, and hook rejection. Each deploy is cheap (<$0.01 on Monad). Don't over-engineer — deploy, test with `cast`, iterate.

### 19. Monad SwapVerifier lacks `transferFromSender`

The deployed SwapVerifier (`0x65bF068c88e0f006f76b871396B4DB1150dd9EAD`) is a stripped-down version with only `verifyAmountMinAndSkim` and `verifyDebtMax`. It does NOT have `transferFromSender`, which the standard EVK periphery includes via `TransferFromSender.sol` + `SafeERC20Permit2Lib`. Any single-batch flow that needs to pull user tokens into the Swapper within an EVC batch will fail with `EVC_EmptyError()` (124 gas). This is immutable — work around it with a two-transaction design.

### 20. Enso API slippage is in basis points, not percentage

`slippage=50` means 0.5%. Sending `slippage=0.5` returns HTTP 400.

### 21. AUSD has 6 decimals, not 18

AUSD (`0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`) uses 6 decimals. Treating it as 18-decimal causes display values to be off by 10^12. Always check the token's actual `decimals()` before hardcoding.

### 22. Enso routes need explicit ERC20 approvals

When using Enso `/route` with `fromAddress=userWallet`, the user must have approved the input token to Enso's Router contract before the transaction. The frontend must check allowance and prompt for approval if insufficient. Same applies to the adapter — user must approve to the adapter address.

### 23. MonadScan verification requires Etherscan V2 API, not Sourcify

MonadScan is Etherscan-based. Sourcify verification (`--verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/`) only shows on **MonadVision**, not MonadScan.

**Preferred method: `forge verify-contract` with `--verifier-url`**

`forge verify-contract --chain 143` fails because Foundry doesn't know chain 143. Instead, use `--verifier-url` to point directly at the Etherscan V2 endpoint:

```bash
forge verify-contract \
  --num-of-optimizations 20000 \
  --watch \
  --constructor-args 0x<hex-encoded-constructor-args> \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=143" \
  --etherscan-api-key $MONADSCAN_API_KEY \
  --compiler-version 0.8.24+commit.e11b9ed9 \
  --evm-version cancun \
  <contract-address> \
  <path:ContractName>
```

The `MONADSCAN_API_KEY` from `.env` is a standard etherscan.io key — the V2 endpoint routes to MonadScan via the `chainid=143` query parameter.

**Important:** `forge verify-contract` resolves sources relative to the project's `foundry.toml` `src` directory. If the contract source lives in a dependency (e.g. `lib/euler-vault-kit/`), run the command from inside that dependency's directory and use the relative path (e.g. `src/GenericFactory/BeaconProxy.sol:BeaconProxy`). Running from the parent project with `lib/...` paths fails with "cannot resolve file".

**Fallback: curl with Standard JSON Input**

If `forge verify-contract` doesn't work (e.g. complex remappings), generate the JSON input and submit directly:

```bash
forge verify-contract <address> <path:Contract> --show-standard-json-input > /tmp/input.json

curl -X POST "https://api.etherscan.io/v2/api?chainid=143" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "module=contract" \
  --data-urlencode "action=verifysourcecode" \
  --data-urlencode "contractaddress=<address>" \
  --data-urlencode "sourceCode@/tmp/input.json" \
  --data-urlencode "codeformat=solidity-standard-json-input" \
  --data-urlencode "contractname=<path:Contract>" \
  --data-urlencode "compilerversion=v0.8.24+commit.e11b9ed9" \
  --data-urlencode "optimizationUsed=1" \
  --data-urlencode "runs=20000" \
  --data-urlencode "constructorArguements=<hex-no-0x-prefix>" \
  --data-urlencode "evmversion=cancun" \
  --data-urlencode "apikey=$MONADSCAN_API_KEY"
```

**EVault BeaconProxy verification:** The vault proxies ARE source-verifiable — they use `BeaconProxy.sol` from `euler-vault-kit/src/GenericFactory/`. Constructor args encode `abi.encodePacked(bytes4(0), asset, oracle, unitOfAccount)` wrapped in ABI `bytes` encoding (32-byte offset + 32-byte length + 64 bytes padded data). Compute with:

```bash
cast abi-encode "constructor(bytes)" \
  $(cast abi-encode --packed "(bytes4,bytes)" 00000000 \
    $(cast abi-encode --packed "(address,address,address)" <ASSET> <ORACLE> <UNIT_OF_ACCOUNT>))
```

Read the three values from any vault: `cast call <VAULT> "asset()(address)" --rpc-url https://rpc.monad.xyz` (and `oracle()`, `unitOfAccount()`).
