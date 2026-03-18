# New Market — Standard Operating Procedure

Step-by-step playbook for deploying a new Euler V2 partner market. Distilled from the Origin (simple pair), Cork (custom contracts), and Balancer (multi-pool) deployments.

**Context files:** This SOP covers the deployment workflow. For frontend architecture details (data flow, composables, theming, vault discovery, the labels layer), see `claude.md` — it is auto-loaded as a workspace rule by Cursor, so any AI agent in this repo already has that context. For per-partner contract details, see `<partner>-contracts/<partner>-claude.md` if one exists.

---

## Phase 0: Research & Market Design

Before writing any code, answer these questions:

### 0.1 Token Identification

- What is the **collateral token**? Get its address on the target chain.
- What is the **borrow token**? (WETH, USDC, etc.)
- Is the collateral token **ERC-4626**? (`convertToAssets` / `asset()` exist and return the borrow token or a path to it.) This determines oracle strategy.
- Are there **multiple collateral types** or just one?

### 0.2 Oracle Strategy Decision Tree

```
Is collateral ERC-4626?
├─ YES: Does convertToAssets eventually resolve to the borrow token?
│  ├─ YES → Use govSetResolvedVault (Origin pattern, zero custom contracts)
│  └─ NO  → Need a Chainlink/Pyth adapter for the gap (check existing adapters below)
└─ NO: Is there a Chainlink or Pyth feed for collateral/borrowAsset?
   ├─ YES → Use existing adapter from the oracle registry
   └─ NO  → Write a custom oracle adapter (Cork pattern)
```

### 0.3 Check Existing Oracle Adapters

Every chain has a CSV of deployed adapters:

```
reference/euler-interfaces/addresses/<chainId>/OracleAdaptersAddresses.csv
```

Search it for your collateral/borrow tokens before building anything. If an adapter exists, note its address — you can wire it directly in step 5.

### 0.4 Look Up Euler V2 Core Addresses

All addresses live in the `reference/euler-interfaces/` submodule:

```
reference/euler-interfaces/addresses/<chainId>/CoreAddresses.json        # EVC, eVaultFactory, Permit2
reference/euler-interfaces/addresses/<chainId>/PeripheryAddresses.json   # kinkIRMFactory, oracleRouterFactory, swapper, swapVerifier
reference/euler-interfaces/addresses/<chainId>/LensAddresses.json        # vaultLens, oracleLens
reference/euler-interfaces/addresses/<chainId>/EulerSwapAddresses.json   # EulerSwap factories
```

Update the submodule before starting: `cd reference/euler-interfaces && git pull origin master`.

---

## Euler V2 Core Address Quick Reference

Addresses used in deployment scripts. Canonical source: `reference/euler-interfaces/addresses/<chainId>/`.

### Ethereum Mainnet (1)

| Contract | Address |
|---|---|
| EVC | `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` |
| eVaultFactory | `0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| KinkIRM Factory | `0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9` |
| Oracle Router Factory | `0x70B3f6F61b7Bf237DF04589DdAA842121072326A` |
| Swapper | `0x2Bba09866b6F1025258542478C39720A09B728bF` |
| Swap Verifier | `0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7` |

### Base (8453)

| Contract | Address |
|---|---|
| EVC | `0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989` |
| eVaultFactory | `0x7F321498A801A191a93C840750ed637149dDf8D0` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| KinkIRM Factory | `0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E` |
| Oracle Router Factory | `0xA9287853987B107969f181Cce5e25e0D09c1c116` |
| Swapper | `0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df` |
| Swap Verifier | `0x30660764A7a05B84608812C8AFC0Cb4845439EEe` |

### Monad (143)

| Contract | Address |
|---|---|
| EVC | `0x7a9324E87C839CF808712e6C8e7d3Ae4096DD3E4` |
| eVaultFactory | `0xba4Dd672B9C4F02F13F6C31c0388E120c3c7ca00` |
| KinkIRM Factory | `0x05Cccb5d80a804a14bAA56f0FA6c6D3f07c1D55B` |
| Oracle Router Factory | `0x5c69a22c2c93A6950D29c37BEAE6a4C98bEB8c56` |
| Swapper | `0x3d1C8E7e5E87B11B0a6A57D4356bb6d5aF06d98E` |
| Swap Verifier | `0x7C79D6bc5aD3F2C0dDB3F09D29658EB77F57E37a` |

---

## Phase 1: Scaffold Contract Directory

### 1.0 Ensure reference repos are populated

The deployment scripts import Solidity from `../reference/` (euler-price-oracle, euler-vault-kit, etc.). If you cloned the repo fresh or the directories are empty, initialize them:

```bash
git submodule update --init --recursive
```

Verify: `ls reference/euler-price-oracle/src/` should show `.sol` files. If any reference repo is a manually cloned directory (not a submodule), `git pull` inside it instead.

### 1.1 Create the directory

```
mkdir <partner>-contracts
cd <partner>-contracts
forge init --no-commit --no-git
```

### 1.2 Copy from Origin (simplest template)

Origin (`origin-contracts/`) is the baseline for a simple collateral/borrow pair with ERC-4626 oracle resolution. Copy these files and adapt:

```
origin-contracts/
├── foundry.toml          ← Update rpc_endpoints for your chain
├── remappings.txt        ← Keep as-is (references ../reference/)
├── .env                  ← Template: RPC, PRIVATE_KEY, output addresses
└── script/
    ├── Addresses.sol     ← Replace with target chain's Euler core + token addresses
    ├── 01_DeployIRM.s.sol
    ├── 02_DeployRouter.s.sol
    ├── 03_DeployBorrowVault.s.sol
    ├── 04_DeployCollateralVault.s.sol
    ├── 05_WireOracle.s.sol
    ├── 06_ConfigureCluster.s.sol
    └── 07_SetFeeReceiver.s.sol
```

### 1.3 Install forge-std

```
cd <partner>-contracts
forge install foundry-rs/forge-std --no-commit
```

### 1.4 Configure foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 20_000
evm_version = "cancun"
allow_paths = ["../reference"]

fs_permissions = [{ access = "read-write", path = "./" }]

[rpc_endpoints]
<chain_name> = "${RPC_URL_<CHAIN>}"

# Block explorer verification — required for --verify to work.
# Each chain has a different API URL. Add the correct one for your chain.
[etherscan]
<chain_name> = { chain = "<chainId>", key = "${ETHERSCAN_API_KEY}", url = "<explorer_api_url>" }
```

**Explorer API URLs by chain:**

| Chain | URL |
|---|---|
| Ethereum (1) | `https://api.etherscan.io/api` |
| Base (8453) | `https://api.basescan.org/api` |
| Arbitrum (42161) | `https://api.arbiscan.io/api` |
| Monad (143) | `https://api.monadscan.com/api` (or skip `--verify` if unsupported) |

Get a free API key from the relevant block explorer site (e.g. basescan.org for Base).

### 1.5 Configure remappings.txt

```
forge-std/=lib/forge-std/src/
euler-price-oracle/=../reference/euler-price-oracle/src/
ethereum-vault-connector/=../reference/ethereum-vault-connector/src/
euler-vault-kit/=../reference/euler-vault-kit/src/
evk-periphery/=../reference/evk-periphery/src/
@openzeppelin/contracts/=../reference/euler-price-oracle/lib/openzeppelin-contracts/contracts/
```

### 1.6 Write Addresses.sol

Replace addresses for your target chain. Pull from the core address registry above.

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

library Addresses {
    // ─── Euler Core (from CoreAddresses.json) ───
    address constant EVC            = 0x...;
    address constant EVAULT_FACTORY = 0x...;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── Euler Periphery (from PeripheryAddresses.json) ───
    address constant KINK_IRM_FACTORY      = 0x...;
    address constant ORACLE_ROUTER_FACTORY = 0x...;
    address constant SWAPPER               = 0x...;
    address constant SWAP_VERIFIER         = 0x...;

    // ─── Tokens ───
    address constant BORROW_TOKEN     = 0x...; // e.g. WETH, USDC
    address constant COLLATERAL_TOKEN = 0x...; // e.g. sfrxETH, ARM token

    // ─── Oracles (if using Chainlink/Pyth adapters) ───
    // address constant CHAINLINK_XXX_YYY = 0x...;
}
```

### 1.7 Prepare .env

```bash
# <Partner> × Euler — Deployment Environment

# ─── RPC ───
RPC_URL_<CHAIN>=

# ─── Deployer ───
PRIVATE_KEY=
ETHERSCAN_API_KEY=

# ─── Outputs (filled by scripts as you deploy) ───
# Step 1
KINK_IRM=
# Step 2
EULER_ROUTER=
# Step 3
BORROW_VAULT=
# Step 4
COLLATERAL_VAULT=

# ─── Fee Receiver ───
FEE_RECEIVER=0x4f894Bfc9481110278C356adE1473eBe2127Fd3C
```

---

## Phase 2: Deploy Contracts (The 7-Script Pattern)

Run each script sequentially. Paste the output address into `.env` before running the next.

### Step 1: Deploy IRM

Deploys a KinkIRM via the factory with your chosen rate curve.

**Parameters to customize:**
- `IRM_BASE` — base rate at 0% utilization (in ray/sec)
- `IRM_SLOPE1` — slope below kink
- `IRM_SLOPE2` — slope above kink (punitive)
- `IRM_KINK` — target utilization as fraction of `type(uint32).max`

**Kink encoding:** `kinkPercent / 100 * type(uint32).max`. For 80% → `0.80 * 4294967295 = 3435973836`.

**Rate calculation helper:**
```bash
node reference/evk-periphery/script/utils/calculate-irm-linear-kink.js borrow <baseAPY> <kinkAPY> <maxAPY> <kinkUtil>
```

Example (Origin): Base=0.5%, Kink(80%)=2.5%, Max=50%.

**Run:**
```bash
source .env && forge script script/01_DeployIRM.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

**Output:** `KINK_IRM=0x...` → paste into `.env`

### Step 2: Deploy Oracle Router

Deploys an EulerRouter owned by the deployer. The router is the oracle address embedded in the borrow vault.

**Run:**
```bash
source .env && forge script script/02_DeployRouter.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

**Output:** `EULER_ROUTER=0x...` → paste into `.env`

### Step 3: Deploy Borrow Vault

Creates the borrow vault via `eVaultFactory.createProxy()`.

**Key concept — trailingData:**
```
trailingData = abi.encodePacked(borrowAsset, oracleRouter, unitOfAccount)  // 60 bytes
```

- `borrowAsset` — the token users deposit to lend / borrow
- `oracleRouter` — the EulerRouter from step 2
- `unitOfAccount` — the denominator for LTV calculations (often same as borrowAsset; use USD `address(840)` for multi-asset clusters)

**Run:**
```bash
source .env && forge script script/03_DeployBorrowVault.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

**Output:** `BORROW_VAULT=0x...` → paste into `.env`

### Step 4: Deploy Collateral Vault

Creates the collateral vault. Collateral vaults do NOT need an oracle or unit of account — those are set to `address(0)`.

```
trailingData = abi.encodePacked(collateralToken, address(0), address(0))
```

**Run:**
```bash
source .env && forge script script/04_DeployCollateralVault.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

**Output:** `COLLATERAL_VAULT=0x...` → paste into `.env`

### Step 5: Wire Oracle

Connect the oracle router to price the collateral in terms of the borrow asset.

**ERC-4626 path (Origin pattern):** If collateral implements ERC-4626 and `convertToAssets` chains down to the borrow token:

```solidity
router.govSetResolvedVault(collateralVault, true);   // EVault → underlying token
router.govSetResolvedVault(underlyingToken, true);    // token → borrow asset (if another hop)
```

Resolution terminates when the resolved asset matches the borrow vault's unit of account.

**Chainlink/Pyth adapter path:** If a price feed is needed:

```solidity
router.govSetConfig(collateralToken, borrowToken, oracleAdapterAddress);
```

**Custom oracle path (Cork pattern):** Deploy a custom oracle contract in `src/`, then wire it the same way as an adapter.

**Run:**
```bash
source .env && forge script script/05_WireOracle.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

### Step 6: Configure Cluster

Sets all risk parameters on the borrow vault.

**Parameters to customize:**

| Parameter | Origin Default | Description |
|---|---|---|
| Borrow LTV | 90% (0.90e4) | Max borrow power |
| Liquidation LTV | 93% (0.93e4) | Liquidation trigger (must be > borrow LTV) |
| Max Liq Discount | 5% (0.05e4) | Liquidator bonus |
| Liq Cool-Off | 1 second | Delay between liquidations |
| Interest Fee | 10% (0.10e4) | Protocol revenue share on interest |
| Supply Cap | 0 (uncapped) | Max deposits — tighten post-launch |
| Borrow Cap | 0 (uncapped) | Max borrows — tighten post-launch |

**LTV guidelines:**
- Highly correlated pairs (e.g. sfrxETH/WETH): 90-92% borrow, 93-95% liquidation
- Moderately correlated (e.g. stablecoin/stablecoin): 85-90% borrow, 88-93% liquidation
- Low correlation or volatile: 70-80% borrow, 75-85% liquidation

**Run:**
```bash
source .env && forge script script/06_ConfigureCluster.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY --broadcast
```

### Step 7: Set Fee Receiver

Sets the address that accrues the interest fee share.

**AG fee receiver:** `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`

**Run:**
```bash
source .env && forge script script/07_SetFeeReceiver.s.sol \
  --rpc-url $RPC_URL_<CHAIN> --private-key $PRIVATE_KEY --broadcast
```

---

## Phase 3: Labels Repo

The labels repo controls which vaults appear in the frontend. **If a vault isn't in `products.json`, it's invisible.**

### 3.1 Create the GitHub Repo

Naming convention: `rootdraws/ag-euler-<partner>-labels`

### 3.2 Directory Structure

```
ag-euler-<partner>-labels/
├── <chainId>/
│   ├── products.json
│   ├── vaults.json
│   ├── entities.json
│   ├── points.json
│   └── opportunities.json
└── logo/
    ├── <partner>.svg
    ├── alphagrowth.svg
    └── euler.svg
```

### 3.3 File Templates

**products.json** — Defines vault clusters. Every vault address here becomes visible.

```json
{
  "<partner>-<market-name>": {
    "name": "<Partner> / <BorrowAsset>",
    "description": "Borrow <BorrowAsset> against <CollateralToken> on <Chain>. Curated by Alpha Growth.",
    "entity": ["alphagrowth", "<partner>", "euler"],
    "url": "https://<partner-website>",
    "vaults": [
      "0x<COLLATERAL_VAULT_CHECKSUM>",
      "0x<BORROW_VAULT_CHECKSUM>"
    ]
  }
}
```

**vaults.json** — Per-vault display metadata.

```json
{
  "0x<COLLATERAL_VAULT_CHECKSUM>": {
    "name": "<Token> Collateral",
    "description": "<Token> collateral vault",
    "entity": "<partner>"
  },
  "0x<BORROW_VAULT_CHECKSUM>": {
    "name": "<BorrowAsset> Lending",
    "description": "<BorrowAsset> lending vault for <Partner> market",
    "entity": "alphagrowth"
  }
}
```

**entities.json** — Organization metadata and logos.

```json
{
  "alphagrowth": {
    "name": "Alpha Growth",
    "logo": "alphagrowth.svg",
    "description": "DeFi risk curation and vault management",
    "url": "https://alphagrowth.fun",
    "addresses": {},
    "social": { "twitter": "", "discord": "", "telegram": "", "github": "" }
  },
  "<partner>": {
    "name": "<Partner Name>",
    "logo": "<partner>.svg",
    "website": "https://<partner-website>",
    "addresses": []
  },
  "euler": {
    "name": "Euler Finance",
    "logo": "euler.svg",
    "description": "Modular lending protocol",
    "url": "https://euler.finance",
    "addresses": {},
    "social": { "twitter": "eulerfinance", "discord": "https://discord.euler.finance/", "github": "euler-xyz" }
  }
}
```

**points.json** — Incentive programs (empty if none).

```json
[]
```

**opportunities.json** — Cozy Finance safety modules (empty if not applicable).

```json
{}
```

### 3.4 Logo Assets

Copy `alphagrowth.svg` and `euler.svg` from an existing labels repo (e.g. `cork-labels/logo/`). Add the partner's logo as SVG or PNG.

---

## Phase 4: Frontend Deployment

### 4.1 Shared vs Fork Decision

| Scenario | Use |
|---|---|
| Standard lending/borrowing UI | Shared `ag-euler-lite` — configure with env vars only |
| Custom multiply flow, adapters, or pages | Fork into `euler-lite-<partner>` |
| Deeply custom UX (dual-collateral, etc.) | Fork into `euler-lite-<partner>` |

Existing forks: `euler-lite-cork`, `euler-lite-balancer`, `euler-lite-origin`.

### 4.2 Required Environment Variables

Set these in Vercel (or `.env` for local dev):

```bash
# ─── Labels ───
NUXT_PUBLIC_CONFIG_LABELS_REPO="rootdraws/ag-euler-<partner>-labels"
NUXT_PUBLIC_CONFIG_LABELS_REPO_BRANCH="main"

# ─── Branding ───
NUXT_PUBLIC_CONFIG_APP_TITLE="<Partner> × Euler"
NUXT_PUBLIC_CONFIG_APP_DESCRIPTION="<Description of the market>"

# ─── Chain RPC (server-side, enables the chain) ───
RPC_URL_HTTP_<chainId>="https://<your-rpc-url>"

# ─── Subgraph (must match the chain ID above) ───
NUXT_PUBLIC_SUBGRAPH_URI_<chainId>="<subgraph-url>"

# ─── Wallet Connect ───
NUXT_PUBLIC_APP_KIT_PROJECT_ID="<your-reown-project-id>"
NUXT_PUBLIC_APP_URL="https://<partner>.alphagrowth.fun"

# ─── Feature Flags ───
NUXT_PUBLIC_CONFIG_ENABLE_LEND_PAGE="true"
NUXT_PUBLIC_CONFIG_ENABLE_EARN_PAGE="false"
NUXT_PUBLIC_CONFIG_ENABLE_EXPLORE_PAGE="false"
NUXT_PUBLIC_CONFIG_ENABLE_ENTITY_BRANDING="true"
NUXT_PUBLIC_CONFIG_ENABLE_VAULT_TYPE="true"

# ─── Social Links ───
NUXT_PUBLIC_CONFIG_X_URL="https://x.com/<partner>"
NUXT_PUBLIC_CONFIG_DISCORD_URL=""
NUXT_PUBLIC_CONFIG_TELEGRAM_URL=""
NUXT_PUBLIC_CONFIG_DOCS_URL="https://docs.euler.finance/"
```

### 4.3 Known Subgraph URIs

Copy-paste ready. These are the full URIs for `NUXT_PUBLIC_SUBGRAPH_URI_<chainId>`.

| Chain | ID | URI |
|---|---|---|
| Ethereum | 1 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-mainnet/latest/gn` |
| Base | 8453 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-base/latest/gn` |
| Arbitrum | 42161 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-arbitrum/latest/gn` |
| Monad | 143 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-monad/latest/gn` |
| Sonic | 146 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-sonic/latest/gn` |
| Unichain | 130 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-unichain/latest/gn` |
| Avalanche | 43114 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-avalanche/latest/gn` |
| BSC | 56 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-bsc/latest/gn` |
| Berachain | 80094 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-berachain/latest/gn` |
| Swell | 1923 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-swell/latest/gn` |
| Bob | 60808 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-bob/latest/gn` |
| Linea | 59144 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-linea/latest/gn` |
| TAC | 239 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-tac/latest/gn` |
| Plasma | 9745 | `https://api.goldsky.com/api/public/project_cm4iagnemt1wp01xn4gh1agft/subgraphs/euler-simple-plasma/latest/gn` |

### 4.4 Vercel Project Setup

1. Create a Vercel project linked to the frontend repo (shared or fork)
2. Set all env vars from 4.2 above
3. Custom domain: `<partner>.alphagrowth.fun`
4. Deploy

### 4.5 Optional: Intrinsic APY Sources

If the collateral token has a DeFi Llama or Merkl yield source, add it to `entities/custom.ts` in the frontend:

```typescript
intrinsicApySources: [
  {
    provider: 'defillama',
    chainId: <chainId>,
    address: '<collateral_token_address>',
    poolId: '<defillama_pool_uuid>'
  }
]
```

---

## Phase 5: Post-Deployment Checklist

### Verification

- [ ] Vaults appear in frontend (check `products.json` is fetched correctly)
- [ ] Entity logos render (check `entities.json` + `logo/` directory)
- [ ] Vault names and descriptions display correctly (`vaults.json`)
- [ ] Lending flow works (deposit borrow asset)
- [ ] Borrowing flow works (deposit collateral, borrow)
- [ ] Multiply flow works (if applicable)
- [ ] Oracle prices resolve correctly on-chain

### Hardening

- [ ] Tighten supply/borrow caps via `setCaps()` — do NOT leave uncapped in production
- [ ] Test liquidation end-to-end (create underwater position, confirm liquidation succeeds)
- [ ] Confirm fee receiver is set and accruing
- [ ] If collateral token has per-address caps (like Origin ARM's CapManager), ensure the Swapper contract is whitelisted

### Documentation

- [ ] Add a new section to `TODO.md` for this partner (follow the format of existing Cork/Origin/Balancer sections: status, deployed addresses table, what's working, remaining TODOs)
- [ ] Document all deployed addresses in the partner's `.env`
- [ ] If a new `<partner>-claude.md` is warranted (custom contracts, non-obvious architecture), create it

### Governance

- [ ] Transfer borrow vault governor from deployer EOA to multisig via `setGovernorAdmin()`
- [ ] Transfer oracle router governance via `transferGovernance()`

---

## When Do You Need Custom Contracts?

For most ERC-4626 collateral/borrow pairs, the Origin 7-script pattern works with zero custom Solidity. You need custom contracts when:

| Situation | Example | Reference |
|---|---|---|
| Custom oracle pricing logic | Cork: vbUSDC priced via pool NAV/swap rate formula | `cork-contracts/src/oracle/` |
| Borrow hook (extra validation) | Cork: enforces dual-collateral pairing (vbUSDC + cST) | `cork-contracts/src/hook/` |
| Custom collateral vault logic | Cork: paired deposit/withdraw invariants | `cork-contracts/src/vault/` |
| Custom liquidation path | Cork: seize + exercise via external protocol | `cork-contracts/src/liquidator/` |
| Swap adapter for multiply | Balancer: BPT adapter for single-sided LP | `balancer-contracts/src/` |

If any of these apply, create `src/` in your contracts directory and add the custom Solidity. The deployment scripts will need additional steps to deploy and wire these contracts.

---

## Quick Reference: Run Commands

All scripts follow the same pattern. Replace `<N>` with step number, `<CHAIN>` with your chain name:

```bash
# Load env
source .env

# Deploy (with verification)
forge script script/0<N>_<ScriptName>.s.sol \
  --rpc-url $RPC_URL_<CHAIN> \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Deploy (without verification, e.g. chains without block explorer API)
forge script script/0<N>_<ScriptName>.s.sol \
  --rpc-url $RPC_URL_<CHAIN> \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

## File Index

| What | Where |
|---|---|
| Origin contracts (simplest template) | `origin-contracts/script/` |
| Cork contracts (custom oracle/hook) | `cork-contracts/script/` + `cork-contracts/src/` |
| Balancer contracts (multi-pool + adapter) | `balancer-contracts/script/` + `balancer-contracts/src/` |
| Origin labels (simplest template) | `origin-labels/1/` |
| Cork labels (full entity metadata) | `cork-labels/1/` |
| Balancer labels (multi-product) | `balancer-labels/143/` |
| Euler V2 addresses per chain | `reference/euler-interfaces/addresses/<chainId>/` |
| Oracle adapters per chain | `reference/euler-interfaces/addresses/<chainId>/OracleAdaptersAddresses.csv` |
| Euler reference repos | `reference/` (EVC, EVK, price oracle, etc.) |
| IRM calculator | `reference/evk-periphery/script/utils/calculate-irm-linear-kink.js` |
| Project task tracker | `TODO.md` |
| Frontend architecture | `claude.md` |
