# Data Flow & Integration

> **Note:** This document was originally written for a TON/TAC version of the codebase. The app has since been refactored to use standard EVM wallets (Wagmi/Reown) and direct EVM RPC calls. Legacy TON/TAC code examples in the "Operations" section below are preserved for reference but no longer reflect the current codebase. See the [Development Guide](./development-guide.md) for current configuration.

This document provides an overview of how data flows through the Euler Lite system, including data sources, transformations, storage, and the complete data lifecycle from external services to user interface.

## Overview

The Euler Lite application integrates with multiple external systems to provide a comprehensive DeFi experience:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Euler Lite Application                       │
├─────────────────────────────────────────────────────────────────┤
│                    Integration Layer                            │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Wagmi/Viem  │ │ Euler       │ │ Rewards     │                │
│  │ (EVM RPC)   │ │ Finance     │ │ (Merkl +    │                │
│  │             │ │             │ │  Brevis)    │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
├─────────────────────────────────────────────────────────────────┤
│                    External Services                            │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ EVM RPC     │ │ Euler       │ │ Goldsky     │                │
│  │ (multi-     │ │ Protocol    │ │ Subgraph    │                │
│  │  chain)     │ │             │ │             │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Merkl API   │ │ Brevis API  │ │ DeFi Llama  │                │
│  │ (rewards)   │ │ (ZK proofs) │ │ (yields)    │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    External Data Sources                        │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Euler       │ │ EVM RPC     │ │ Rewards     │                │
│  │ Finance     │ │ (Wagmi)     │ │ APIs        │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    Data Integration Layer                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vault Lens  │ │ EVC Batch   │ │ Merkl/Brevis│                │
│  │ Multicall   │ │ Simulation  │ │ Clients     │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    Application State Layer                      │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vaults      │ │ Account     │ │ Wallet      │                │
│  │ State       │ │ State       │ │ State       │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    User Interface Layer                         │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Pages       │ │ Components  │ │ UI State    │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

### Table of Contents

- [Euler Finance](#euler-finance)
- [Rewards System](#rewards-system)
- [Intrinsic APY](#intrinsic-apy)
- [Goldsky Subgraph](#goldsky-subgraph)
- [Chain Switching](#chain-switching)
- [Legacy Operations (TON/TAC)](#legacy-operations-tontac)

# Data Flows

### Euler Finance

- [Back to the top](#table-of-contents)

#### Operations:

- [Smart account initialization](#smart-account-initialization)
- [Vaults fetching](#vaults-fetching)
- [Borrow pairs fetching](#borrow-pairs-fetching)
- [Account positions and balances](#account-positions-and-balances)
- [Price information](#price-information)
- [Supply, borrow, repay, withdraw, borrow more, supply more operations](#supply-borrow-repay-withdraw-borrow-more-supply-more-operations)

#### Data flow:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Euler Finance Protocol                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vaults      │ │ Borrow      │ │ Interest    │                │
│  │ Registry    │ │ Pairs       │ │ Rate Models │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│              Euler Protocol Integration                         │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vaults      │ │ Account     │ │ Price       │                │
│  │ Fetching    │ │ Positions   │ │ Feeds       │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    Application Composables                      │
│  ┌─────────────┐ ┌───────────────┐ ┌───────────────────┐        │
│  │ useVaults   │ │ useEulerAcct  │ │ useEulerOperations│        │
│  │             │ │               │ │                   │        │
│  └─────────────┘ └───────────────┘ └───────────────────┘        │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    State Management                             │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vaults      │ │ Account     │ │ Operations  │                │
│  │ State       │ │ Positions   │ │ State       │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    UI Components                                │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ Vaults      │ │ Portfolio   │ │ Operations  │                │
│  │ List        │ │ Display     │ │ Forms       │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

### Rewards System

- [Back to the top](#table-of-contents)

The rewards system was unified in a refactor that introduced the `RewardCampaign` type, consolidating data from multiple reward providers into a single interface.

#### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Reward Providers                             │
│  ┌─────────────┐ ┌─────────────┐                                │
│  │ Merkl API   │ │ Brevis API  │                                │
│  └─────────────┘ └─────────────┘                                │
│           │               │                                     │
│           ▼               ▼                                     │
├─────────────────────────────────────────────────────────────────┤
│              Provider Composables                               │
│  ┌─────────────┐ ┌─────────────┐                                │
│  │ useMerkl    │ │ useBrevis   │                                │
│  │ (campaigns, │ │ (campaigns, │                                │
│  │  claiming,  │ │  ZK proofs) │                                │
│  │  REUL locks)│ │             │                                │
│  └─────────────┘ └─────────────┘                                │
│           │               │                                     │
│           ▼               ▼                                     │
├─────────────────────────────────────────────────────────────────┤
│              Unified Reward Layer                               │
│  ┌─────────────────────────────────────────────────┐            │
│  │ useRewardsApy                                   │            │
│  │ - Aggregates campaigns from all providers       │            │
│  │ - getSupplyRewardApy(vault) → number            │            │
│  │ - getBorrowRewardApy(vault, collateral?) → num  │            │
│  │ - Reactive version counter for cache busting    │            │
│  └─────────────────────────────────────────────────┘            │
│                         │                                       │
│                         ▼                                       │
├─────────────────────────────────────────────────────────────────┤
│                    UI Components                                │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                │
│  │ VaultItem   │ │ APY Modals  │ │ Portfolio   │                │
│  │ (reward     │ │ (breakdown) │ │ Rewards     │                │
│  │  badges)    │ │             │ │ Page        │                │
│  └─────────────┘ └─────────────┘ └─────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

#### RewardCampaign Type

All reward data is normalized into the `RewardCampaign` interface (`entities/reward-campaign.ts`):

```typescript
interface RewardCampaign {
  vault: string                     // Vault address
  collateral?: string               // For borrow-collateral campaigns
  type: RewardCampaignType          // 'euler_lend' | 'euler_borrow' | 'euler_borrow_collateral'
  apr: number                       // Annual percentage rate
  provider: 'merkl' | 'brevis'     // Which provider sourced this campaign
  endTimestamp: number              // Campaign expiry
  rewardToken?: { symbol: string; icon: string }
}
```

#### Provider Details

- **useMerkl** — Fetches campaigns from the Merkl API, maps `subType` indices (0 = lend, 1 = borrow, 2 = borrow-collateral) to `RewardCampaignType`. Also handles user reward balances, claiming, and REUL lock management.
- **useBrevis** — Fetches ZK-proof reward campaigns from the Brevis backend, normalizes them to `RewardCampaign`.

#### Consuming Rewards in UI

```typescript
const { getSupplyRewardApy, getBorrowRewardApy, hasSupplyRewards } = useRewardsApy()

// Get total supply reward APY across all providers for a vault
const rewardApy = getSupplyRewardApy(vault.address)

// Get borrow reward APY (optionally filtered by collateral)
const borrowReward = getBorrowRewardApy(borrowVault.address, collateral.address)
```

### Intrinsic APY

- [Back to the top](#table-of-contents)

The `useIntrinsicApy` composable (`composables/useIntrinsicApy.ts`) adds yield intrinsic to the underlying asset (e.g., stETH staking yield, sDAI DSR, Pendle PT implied yield) on top of vault lending/borrowing APY.

The system uses a **provider abstraction** with two implementations:
- **DefiLlama** — bulk pool fetch, poolId-based matching, 30-day average APY
- **Pendle** — per-market API fetch for PT implied yield, with maturity detection

All lookups are by **token address** (not symbol). Results are cached for 5 minutes with automatic chain-switch invalidation. APY modals show provider name and source link for transparency.

#### Key API

```typescript
const { getIntrinsicApy, getIntrinsicApyInfo, withIntrinsicSupplyApy, withIntrinsicBorrowApy } = useIntrinsicApy()

// Raw intrinsic APY by token address
const apy = getIntrinsicApy(vault.asset.address)  // e.g. 3.2 (percent)

// Full info with provider name and source URL (for modals)
const info = getIntrinsicApyInfo(vault.asset.address)

// Combined APY with compounding
const effectiveSupply = withIntrinsicSupplyApy(lendingApy, vault.asset.address)
```

See [Intrinsic APY](./intrinsic-apy.md) for the full architecture, provider details, and how to add new sources.

### Chain Switching

- [Back to the top](#table-of-contents)

When the user switches chains, `useVaults` resets all vault state and prevents stale data from the previous chain from being displayed:

1. `chainId` watcher in `app.vue` calls `resetVaultsState()` and `resetBalances()`
2. Labels are reloaded first, then `loadVaults()` runs
3. Before setting vault data, `useVaults` checks that `chainId` hasn't changed since the fetch began — if it has, the stale result is discarded

> **Note:** The Merkl rewards section below is from the original codebase. The current app uses a unified rewards system — see [Rewards System](#rewards-system) above.

### Goldsky Subgraph

- [Back to the top](#table-of-contents)

#### Operations:

- [Borrow positions fetching](#borrow-positions-fetching)

#### Data flow:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Goldsky Subgraph                             │
│  ┌─────────────┐                                                │
│  │ GraphQL     │                                                │
│  │ Endpoint    │                                                │
│  └─────────────┘                                                │
│           │                                                     │
│           ▼                                                     │
├─────────────────────────────────────────────────────────────────┤
│              Subgraph Query Integration                         │
│  ┌─────────────┐ ┌─────────────┐                                │
│  │ Borrow      │ │ Position    │                                │
│  │ Positions   │ │ Details     │                                │
│  └─────────────┘ └─────────────┘                                │
│           │               │                                     │
│           ▼               ▼                                     │
├─────────────────────────────────────────────────────────────────┤
│                    Application Composables                      │
│  ┌─────────────┐ ┌───────────────┐ ┌───────────────────┐        │
│  │ useVaults   │ │ useEulerAcct  │ │ useEulerOperations│        │
│  │             │ │               │ │                   │        │
│  └─────────────┘ └───────────────┘ └───────────────────┘        │
│           │               │               │                     │
│           ▼               ▼               ▼                     │
├─────────────────────────────────────────────────────────────────┤
│                    State Management                             │
│  ┌─────────────┐ ┌─────────────┐                                │
│  │ Borrow      │ │ Position    │                                │
│  │ Positions   │ │ Data        │                                │
│  └─────────────┘ └─────────────┘                                │
│           │               │                                     │
│           ▼               ▼                                     │
├─────────────────────────────────────────────────────────────────┤
│                    UI Components                                │
│  ┌─────────────┐ ┌─────────────┐                                │
│  │ Portfolio   │ │ Position    │                                │
│  │ Borrow      │ │ Details     │                                │
│  └─────────────┘ └─────────────┘                                │
└─────────────────────────────────────────────────────────────────┘
```

# Legacy Operations (TON/TAC)

> **Warning:** The operations below reference the removed TON/TAC integration. They are preserved for historical reference only. The current app uses Wagmi/Reown for wallet connection and direct EVM calls via `useEulerOperations`. See [Transaction Building](./transaction-building.md) for the current architecture.

## TON Blockchain (removed)

### Wallet connect/disconnect

- [Back to the top](#table-of-contents)

#### Connect wallet

##### useTonConnect composable, tonConnectUI initialization:

```typescript
const tonConnectUI = new TonConnectUI({
  manifestUrl: TVM_MANIFEST_URL,
  enableAndroidBackHandler: false,
});
const modal = tonConnectUI.modal;
Object.assign(account, tonConnectUI.account);
tonConnectUI.uiOptions = {
  language: "en",
  uiPreferences: {
    theme: THEME.LIGHT,
  },
  actionsConfiguration: {
    // twaReturnUrl: config.telegramMiniAppBotUrl as `${string}://${string}`,
  },
};

tonConnectUI.connectionRestored.then(() => {
  isLoaded.value = true;
});
tonConnectUI.onStatusChange((walletInfo) => {
  if (walletInfo?.account?.address) {
    Object.assign(account, walletInfo.account);
    walletName.value = walletInfo?.name;
  }
});
```

##### Components using composable, connect wallet modal opening:

```typescript
const { tonConnectUI } = useTonConnect();

const onConnectClick = () => {
  tonConnectUI.openModal();
};
```

#### Disconnect

##### useTonConnect composable:

```typescript
const disconnect = async () => {
  Object.assign(account, {
    address: "",
    chain: "" as CHAIN,
    walletStateInit: "",
    publicKey: "",
  });

  await tonConnectUI.disconnect();
};
```

##### Components using composable, wallet disconnecting:

```typescript
const { disconnect } = useTonConnect();

const onDisconnectClick = () => {
  disconnect();
};
```

### Balances fetching

- [Back to the top](#table-of-contents)

#### Implementation

##### useWallets composable, balance update function:

```typescript
export const updateBalances = async (isInitialLoading = true) => {
  try {
    if (!isConnected.value) {
      return;
    }

    const { TVM_TONCENTER_URL } = useEulerConfig();
    if (isInitialLoading) {
      isLoaded.value = false;
      isLoading.value = true;
    }

    const { isReady, map } = useVaults();
    await until(isReady).toBe(true);

    const { isLoaded: isTacSdkLoaded } = useTacSdk();
    await until(isTacSdkLoaded).toBe(true);

    const { tacSdk } = useTacSdk();

    // Collect all EVM addresses from vaults
    let tonAssetsAddress: string;
    const evmAddresses: string[] = [];
    map.value.forEach((vault) => {
      evmAddresses.push(vault.address);
      evmAddresses.push(vault.asset.address);
      if (vault.asset.symbol === "TON") {
        tonAssetsAddress = vault.asset.address;
      }
    });

    // Batch convert EVM addresses to TVM addresses
    const batchSize = 5;
    for (let i = 0; i < evmAddresses.length; i += batchSize) {
      const batch = evmAddresses.slice(i, i + batchSize);
      const results = await Promise.allSettled(
        batch.map((addr) => tacSdk.getTVMTokenAddress(addr))
      );

      batch.forEach((evmAddress, idx) => {
        const res = results[idx];
        const tvm =
          res.status === "fulfilled" && res.value ? res.value : "NONE";
        convertedAddresses.set(evmAddress, tvm);
      });
    }

    // Fetch jetton wallet balances from TON Center
    const { data } = await axios.get<{
      jetton_wallets: Record<string, string>[];
    }>(`${TVM_TONCENTER_URL}/api/v3/jetton/wallets`, {
      params: {
        jetton_address: Array.from(convertedAddresses.values()).filter(
          (o) => o !== "NONE"
        ),
        owner_address: address.value,
      },
    });
    const wallets = data.jetton_wallets;

    // Get TON balance directly from blockchain
    const client = new TonClient({
      endpoint: `${TVM_TONCENTER_URL}/api/v2/jsonRPC`,
    });
    const tonBalance = await client.getBalance(
      Address.parse(friendlyAddress.value)
    );

    // Map balances to EVM addresses
    convertedAddresses.forEach((value, key) => {
      balances.value.set(
        key,
        value === "NONE"
          ? key === tonAssetsAddress
            ? tonBalance
            : 0n
          : BigInt(
              wallets.find(
                (wallet) =>
                  wallet?.jetton ===
                  Address.parse(value).toRawString().toUpperCase()
              )?.balance || 0n
            )
      );
    });
  } catch (e) {
    console.warn(e);
  } finally {
    isLoaded.value = true;
    isLoading.value = false;
  }
};
```

##### Components using balance data, getting user balance in a vault:

```typescript
const { balances } = useWallets();
const balance = computed(() => balances.value.get(vault.asset.address) || 0n);
```

### User TON address management

- [Back to the top](#table-of-contents)

#### TON account - different formats of addresses handling

```typescript
const account: Account = reactive({} as Account);
const walletName = ref("Wallet");
const address = computed(() => account?.address || "");
const chain = computed(() => account.chain);
const friendlyAddress = computed(() =>
  account?.address ? toUserFriendlyAddress(account.address) : ""
);
const shortAddress = computed(() =>
  friendlyAddress.value ? truncate(friendlyAddress.value) : ""
);
const shorterAddress = computed(() =>
  friendlyAddress.value ? truncate(friendlyAddress.value, 3) : ""
);
const isConnected = computed(() => Boolean(address.value));

// TON account is set on connection status change
tonConnectUI.onStatusChange((walletInfo) => {
  if (walletInfo?.account?.address) {
    Object.assign(account, walletInfo.account);
    walletName.value = walletInfo?.name;
  }
});
```

#### Components using TON addresses, disconnect modal

```vue
<script setup lang="ts">
const emits = defineEmits(["close"]);

const { shorterAddress, friendlyAddress, disconnect } = useTonConnect();

const onCopyAddressClick = () => {
  navigator.clipboard.writeText(friendlyAddress.value);
};

const onDisconnectClick = () => {
  disconnect();
  emits("close");
};
</script>

<template>
  <BaseModalWrapper title="Wallet" @close="$emit('close')">
    <div :class="$style.content" class="flex column align-center gap-16 mb-16">
      <div class="flex justify-center align-center gap-16">
        <div class="h3 center">
          {{ shorterAddress }}
        </div>
        <UiButton
          variant="primary-stroke"
          size="medium"
          icon="copy"
          icon-only
          @click="onCopyAddressClick"
        />
      </div>
    </div>
    <UiButton
      variant="primary-stroke"
      size="xlarge"
      rounded
      icon="unlink"
      @click="onDisconnectClick"
    >
      Disconnect
    </UiButton>
  </BaseModalWrapper>
</template>
```

## Euler Finance

### Smart account initialization

- [Back to the top](#table-of-contents)

#### updateAccount function in useEulerAccount composable, executed whenever TON wallet is connected

```typescript
const address: Ref<string> = ref("");
const account: Ref<Account | undefined> = ref(undefined);

const updateAccount = async (tvmAddress: string | undefined) => {
  address.value = "";
  if (!tvmAddress) {
    borrowPositions.value = [];
    return;
  }

  try {
    const { NETWORK, TAC_FACTORY_ADDRESS, EULER_PROXY, EVM_PROVIDER_URL } =
      useEulerConfig();
    const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
    const tacFactoryAbi = [
      "function predictSmartAccountAddress(string,address) external view returns(address)",
    ];
    const addressContract = new ethers.Contract(
      TAC_FACTORY_ADDRESS,
      tacFactoryAbi,
      provider
    );
    const accountLensContract = new ethers.Contract(
      eulerLensAddresses[NETWORK].accountLens,
      eulerAccountLensABI,
      provider
    );
    address.value = await addressContract.predictSmartAccountAddress(
      Address.parse(tvmAddress).toString({ bounceable: true }),
      EULER_PROXY
    );
    account.value = (
      await accountLensContract.getAccountEnabledVaultsInfo(
        eulerCoreAddresses[NETWORK].evc,
        address.value
      )
    ).toObject({ deep: true });
    updateBorrowPositions();
  } catch (e) {
    console.warn(e);
    address.value = "";
  }
};
```

### Vaults fetching

- [Back to the top](#table-of-contents)

#### loadVaults function, which is executed on startup, and it's updateVaults function (all in useVaults composable)

```typescript
const map: Ref<Map<string, Vault>> = shallowRef(new Map());

const updateVaults = async () => {
  try {
    isUpdating.value = true;
    const res = await fetchVaults();
    map.value = new Map(res.map((i) => [i.address, i]));
  } finally {
    isUpdating.value = false;
  }
};
const loadVaults = async () => {
  try {
    isReady.value = false;
    isLoading.value = true;
    await updateVaults();
  } finally {
    isReady.value = true;
    isLoading.value = false;
  }
};
```

#### List of vaults computed from map in which vaults were stored (useVaults composable)

```typescript
const list = computed(() => [...map.value.values()]);
const borrowList = computed(() =>
  getBorrowVaultsByMap(map.value).filter((pair) => pair.borrow.supply > 0n)
);
```

#### fetchVaults function which is used by updateVaults above

```typescript
export const fetchVaults = async (): Promise<Vault[]> => {
  const { NETWORK, EVM_PROVIDER_URL } = useEulerConfig();
  const arr: Vault[] = [];
  const provider = new ethers.JsonRpcProvider(EVM_PROVIDER_URL);
  const governedPerspectiveContract = new ethers.Contract(
    eulerPeripheryAddresses[NETWORK].governedPerspective,
    eulerPerspectiveABI,
    provider
  );
  const vaultLensContract = new ethers.Contract(
    eulerLensAddresses[NETWORK].vaultLens,
    eulerVaultLensABI,
    provider
  );
  const verifiedVaults =
    (await governedPerspectiveContract.verifiedArray()) as string[];
  const batchSize = 5;
  for (let i = 0; i < verifiedVaults.length; i += batchSize) {
    const batch = verifiedVaults.slice(i, i + batchSize);
    const batchPromises = batch.map(async (vaultAddress) => {
      try {
        const raw = await vaultLensContract.getVaultInfoFull(vaultAddress);
        const data = raw.toObject({ deep: true });

        if (!data.irmInfo?.interestRateInfo?._) {
          data.irmInfo.interestRateInfo._ = {
            borrowAPY: 0n,
            borrowSPY: 0n,
            borrows: 0n,
            cash: 0n,
            supplyAPY: 0n,
          };
        }

        return {
          address: data.vault,
          name: data.vaultName,
          supply: data.totalAssets,
          borrow: data.totalBorrowed,
          symbol: data.vaultSymbol,
          decimals: data.vaultDecimals,
          supplyCap: data.supplyCap,
          borrowCap: data.borrowCap,
          totalCash: data.totalCash,
          totalAssets: data.totalAssets,
          interestFee: data.interestFee,
          configFlags: data.configFlags,
          collateralLTVs: raw.collateralLTVInfo
            .toArray()
            .map((o: { toObject: () => void }) => o.toObject()),
          collateralPrices: raw.collateralPriceInfo
            .toArray()
            .map((o: { toObject: () => void }) => o.toObject()),
          liabilityPriceInfo: data.liabilityPriceInfo,
          maxLiquidationDiscount: data.maxLiquidationDiscount,
          interestRateInfo: data.irmInfo.interestRateInfo._, // might be a toObject deep conversion bug
          asset: {
            address: data.asset,
            name: data.assetName,
            symbol: data.assetSymbol,
            decimals: data.assetDecimals,
          },
        } as Vault;
      } catch (e) {
        console.error(
          `Error fetching collaterals for vault ${vaultAddress}:`,
          e
        );
        return undefined;
      }
    });

    const res = await Promise.all(batchPromises);
    // await new Promise(resolve => setTimeout(resolve, 500))
    arr.push(...res.filter((o) => !!o));
  }

  return arr;
};
```

### Borrow pairs fetching

- [Back to the top](#table-of-contents)

#### getBorrowVaultsByMap function, used by borrowList computed above

```typescript
export const getBorrowVaultsByMap = (vaultsMap: Map<string, Vault>) => {
  const arr: BorrowVaultPair[] = [];
  const list = [...vaultsMap.values()];
  list.forEach((vault) => {
    vault.collateralLTVs.forEach((c) => {
      if (c.borrowLTV <= 0n) {
        return;
      }
      const cVault = vaultsMap.get(c.collateral);
      arr.push({
        borrow: vault,
        collateral: cVault!,
        borrowLTV: c.borrowLTV,
        liquidationLTV: c.liquidationLTV,
        initialLiquidationLTV: c.initialLiquidationLTV,
      });
    });
  });
  return arr.filter((o) => !!o && o?.collateral);
};
```

### Account positions and balances

- [Back to the top](#table-of-contents)

#### updateSavingsPositions and updateBorrowPositions in useEulerAccount composable, uses Euler and Goldsky

```typescript
const depositPositions: Ref<AccountDepositPosition[]> = ref([]);
const borrowPositions: Ref<AccountBorrowPosition[]> = ref([]);

const updateBorrowPositions = async (isInitialLoading = true) => {
  if (isInitialLoading) {
    isPositionsLoading.value = true;
  }

  const { NETWORK, EVM_PROVIDER_URL, GOLDSKY_API_URL } = useEulerConfig();
  const { isReady, map } = useVaults();
  await until(isReady).toBe(true);
  const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
  const accountLensContract = new ethers.Contract(
    eulerLensAddresses[NETWORK].accountLens,
    eulerAccountLensABI,
    provider
  );
  const { data } = await axios.post(GOLDSKY_API_URL, {
    query: `query AccountBorrows {
      trackingActiveAccount(id: "${address.value}") {
        borrows
      }
    }`,
    operationName: "AccountBorrows",
  });
  const borrowEntries = data.data.trackingActiveAccount?.borrows || [];

  let borrows: AccountBorrowPosition[] = [];
  const batchSize = 5;

  for (let i = 0; i < borrowEntries.length; i += batchSize) {
    const batch = borrowEntries
      .slice(i, i + batchSize)
      .map(async (entry: string) => {
        const vault = `0x${entry.substring(42)}`;
        const subAccount = entry.substring(0, 42);

        const res = await accountLensContract.getVaultAccountInfo(subAccount, vault);
        if (!res.isController || res.borrowed === 0n) {
          return undefined;
        }
        const collaterals = res.liquidityInfo?.collaterals || [];
        const collateral = collaterals.length ? map.value.get(ethers.getAddress(collaterals[0])) : undefined;
        const borrow = map.value.get(ethers.getAddress(vault));
        if (!collateral || !borrow) {
          return undefined;
        }
        const cLTV = borrow?.collateralLTVs.find(
          (ltv) => ltv.collateral === collateral.address
        );
        const collateralValueLiquidation =
          res.vaultAccountInfo.liquidityInfo.collateralValueLiquidation;
        const liabilityValue =
          res.vaultAccountInfo.liquidityInfo.liabilityValue;
        const liquidationLTV = cLTV?.liquidationLTV || 0n;
        const healthFixed = FixedNumber.fromValue(
          collateralValueLiquidation,
          18
        ).div(FixedNumber.fromValue(liabilityValue, 18));
        const userLTVFixed = healthFixed.isZero()
          ? FixedNumber.fromValue(0n, 2)
          : FixedNumber.fromValue(liquidationLTV, 2).div(healthFixed);
        const userLTV = userLTVFixed.value;
        // Conservative price ratio: collateral.bid / liability.ask
        // Matches EVK on-chain convention (LiquidityUtils.sol)
        const priceFixed = FixedNumber.fromValue(
          collateral.liabilityPriceInfo.amountOutBid || 0n,
          18
        ).div(
          FixedNumber.fromValue(
            borrow.liabilityPriceInfo.amountOutAsk || 1n,
            18
          )
        );
        const price = priceFixed.value;
        const borrowedFixed = FixedNumber.fromValue(
          res.vaultAccountInfo.borrowed,
          borrow.decimals
        );
        const supplied = borrowedFixed
          .div(userLTVFixed.div(FixedNumber.fromValue(100n)))
          .div(priceFixed)
          .round(Number(collateral.decimals))
          .toFormat({ decimals: Number(collateral.decimals) }).value;

        return {
          borrow,
          collateral,
          subAccount,
          liabilityLTV: 0n,
          borrowLTV: cLTV?.borrowLTV || 0n,
          initialLiquidationLTV: cLTV?.initialLiquidationLTV || 0n,
          timeToLiquidation:
            res.vaultAccountInfo.liquidityInfo.timeToLiquidation,
          health: healthFixed.value,
          borrowed: res.vaultAccountInfo.borrowed,
          price,
          userLTV,
          supplied,
          liabilityValue,
          liquidationLTV,
          collateralValueLiquidation,
        } as AccountBorrowPosition;
      });

    borrows = [
      ...borrows,
      ...(await Promise.all(batch)).filter((o) => !!o),
    ] as AccountBorrowPosition[];
  }

  borrowPositions.value = borrows;

  isPositionsLoading.value = false;
  isPositionsLoaded.value = true;
};
const updateDepositPositions = async () => {
  const { isReady, list } = useVaults();
  await until(isReady).toBe(true);

  let deposits: AccountDepositPosition[] = [];
  const batchSize = 5;

  for (let i = 0; i < list.value.length; i += batchSize) {
    const batch = list.value.slice(i, i + batchSize).map(async (vault) => {
      const balance = balances.value.get(ethers.getAddress(vault.address));
      return {
        vault,
        shares: balance,
        assets: balance
          ? await convertSharesToAssets(vault.address, balance)
          : 0n,
      } as AccountDepositPosition;
    });

    deposits = [
      ...deposits,
      ...(await Promise.all(batch)).filter((o) => o.shares > 0n),
    ] as AccountDepositPosition[];
  }

  depositPositions.value = deposits;
};
```

### Interest rate computations

- [Back to the top](#table-of-contents)

#### APY computing functions

```typescript
export const computeAPYs = (
  borrowSPY: bigint,
  cash: bigint,
  borrows: bigint,
  interestFee: bigint
) => {
  const { NETWORK, EVM_PROVIDER_URL } = useEulerConfig();
  const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
  const utilsLensContract = new ethers.Contract(
    eulerLensAddresses[NETWORK].utilsLens,
    eulerUtilsLensABI,
    provider
  );
  return utilsLensContract.computeAPYs(borrowSPY, cash, borrows, interestFee);
};
export const getNetAPY = (
  supplyUSD: number,
  supplyAPY: number,
  borrowUSD: number,
  borrowAPY: number,
  supplyRewardAPY?: number | null,
  borrowRewardAPY?: number | null
) => {
  const sum =
    supplyUSD * (supplyAPY + (supplyRewardAPY || 0)) -
    borrowUSD * (borrowAPY - (borrowRewardAPY || 0));
  if (sum === 0) {
    return 0;
  }
  return sum / (sum < 0 ? borrowUSD : supplyUSD);
};
```

#### Components using APY functions

```typescript
// BorrowPositionItem
const netAPY = computed(() => {
  return getNetAPY(
    getAssetUsdValue(position.supplied || 0n, collateralVault.value!),
    nanoToValue(collateralVault.value?.interestRateInfo.supplyAPY || 0n, 25),
    getAssetUsdValue(position.borrowed || 0n || 0, borrowVault.value!),
    nanoToValue(borrowVault.value?.interestRateInfo.borrowAPY || 0n, 25),
    opportunityInfoForCollateral.value?.apr || null,
    opportunityInfoForBorrow.value?.apr || null
  );
});

// Computing estimate when user is supplying to a vault
const updateEstimates = useDebounceFn(async () => {
  if (!vault.value) {
    return;
  }
  try {
    await updateVault(vault.value.address);
    const { supplyAPY } = await computeAPYs(
      vault.value.interestRateInfo.borrowSPY,
      vault.value.interestRateInfo.cash +
        valueToNano(amount.value, vault.value.decimals),
      vault.value.interestRateInfo.borrows,
      vault.value.interestFee
    );
    estimateSupplyAPY.value =
      supplyAPY + valueToNano(opportunityInfo.value?.apr || 0, 25);
    monthlyEarnings.value = !amount.value
      ? 0
      : (+(amount.value || 0) * nanoToValue(estimateSupplyAPY.value, 27)) / 12;
  } catch (e) {
    console.warn(e);
  } finally {
    isEstimatesLoading.value = false;
  }
}, 500);
```

### Price information

- [Back to the top](#table-of-contents)

#### Price Provider Service

The pricing system is built as a 3-layer architecture in `services/pricing/priceProvider.ts`:

**Layer 1: Raw Oracle Prices (Unit of Account)**
```typescript
import { getAssetOraclePrice, getCollateralOraclePrice, getUnitOfAccountUsdRate } from '~/services/pricing'

// Get asset price in vault's unit of account
const oraclePrice = getAssetOraclePrice(vault)

// Get collateral price from liability vault's perspective (in UoA)
const collateralPrice = getCollateralOraclePrice(liabilityVault, collateralVault)

// Get UoA → USD conversion rate (returns 1e18 if UoA is USD)
const uoaRate = getUnitOfAccountUsdRate(vault)
```

**Layer 2: USD Prices**
```typescript
import { getAssetUsdPrice, getCollateralUsdPrice } from '~/services/pricing'

// Get asset price in USD (handles vault type routing internally)
const usdPrice = getAssetUsdPrice(vault)

// Get collateral USD price in borrow context
const collateralUsdPrice = getCollateralUsdPrice(liabilityVault, collateralVault)
```

**Layer 3: USD Value Calculation**
```typescript
import { getAssetUsdValue, getCollateralUsdValue, formatAssetValue } from '~/services/pricing'

// Calculate USD value of an amount
const usdValue = getAssetUsdValue(amount, vault)

// Calculate collateral USD value in borrow context
const collateralValue = getCollateralUsdValue(assetAmount, liabilityVault, collateralVault)

// Format for UI display
const { display, hasPrice, usdValue } = formatAssetValue(amount, vault)
```

#### Components using price information

```vue
<template>
  <!-- code -->
  <div class="between gap-8 flex-wrap mb-12">
    <div class="text-euler-dark-900 p3">Current price</div>
    <div class="text-white p3">
      {{ formatUsdValue(getAssetUsdValue(1, vault)) }}
    </div>
  </div>
  <!-- code -->
</template>
```

### Supply, borrow, repay, withdraw, borrow more, supply more operations

- [Back to the top](#table-of-contents)

#### Supply operation (useEulerOperations composable) and components usage of it

```typescript
const supply = async (
  vaultAddress: string,
  assetAddress: string,
  amount: bigint,
  symbol: string,
  subAccount?: string
) => {
  const { EULER_PROXY } = useEulerConfig();
  const { tacSdk } = useTacSdk();
  const { address: eulerAccountAddress } = useEulerAccount();
  const hooks = new SaHooksBuilder();
  const hasSign = await hasSignature(eulerAccountAddress.value);
  const isTON = symbol === "TON";

  hooks.addContractInterface(vaultAddress, [
    "function deposit(uint256,address) external",
  ]);
  hooks.addContractInterface(assetAddress, [
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(SIGN_CONTRACT_ADDRESS, [
    "function signTermsOfUse(string,bytes32) external",
  ]);

  if (!eulerAccountAddress.value) {
    throw "Euler account address is empty. Is it loaded properly?";
  }

  hooks.addPreHookCallFromSA(assetAddress, "approve", [vaultAddress, amount]);
  hooks.addPreHookCallFromSelf(assetAddress, "transfer", [
    eulerAccountAddress.value,
    amount,
  ]);

  let callData;
  if (!hasSign) {
    const batchString = "tuple(address,address,uint256,bytes)[]";
    const dataForCall = hooks.getDataForCall(vaultAddress, "deposit", [
      amount,
      subAccount || EULER_PROXY,
    ]);
    const signData = hooks.getDataForCall(
      SIGN_CONTRACT_ADDRESS,
      "signTermsOfUse",
      [FINAL_MESSAGE, FINAL_HASH]
    );
    const batchItems = [
      [SIGN_CONTRACT_ADDRESS, eulerAccountAddress.value, 0n, signData],
      [vaultAddress, eulerAccountAddress.value, 0n, dataForCall],
    ];
    callData = new ethers.AbiCoder().encode(
      [hooks.tupleString(), hooks.bridgeString(), batchString],
      [hooks.build(), [subAccount ? [] : [vaultAddress]], batchItems]
    );
  } else {
    const callString = "tuple(address,address,uint256,bytes)";
    const dataForCall = hooks.getDataForCall(vaultAddress, "deposit", [
      amount,
      subAccount || EULER_PROXY,
    ]);
    callData = new ethers.AbiCoder().encode(
      [hooks.tupleString(), hooks.bridgeString(), callString],
      [
        hooks.build(),
        [subAccount ? [] : [vaultAddress]],
        [vaultAddress, eulerAccountAddress.value, 0n, dataForCall],
      ]
    );
  }

  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: EULER_PROXY,
    methodName: !hasSign ? "batch(bytes,bytes)" : "call(bytes,bytes)",
    encodedParameters: callData,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = [
    {
      ...(!isTON && { address: await tacSdk.getTVMTokenAddress(assetAddress) }),
      rawAmount: amount,
      type: AssetType.FT,
    },
  ];

  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    assets
  );
  tacSdk.closeConnections();

  const tsResult = res.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!asset.value?.address) {
      return;
    }
    const tl = await supply(
      vaultAddress,
      asset.value.address,
      valueToNano(amount.value || "0", asset.value.decimals),
      asset.value.symbol
    );
    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: () => {
        updateEstimates();
        updateBalance();
        setTimeout(() => {
          router.replace("/portfolio/saving");
        }, 400);
      },
    });
  } catch (e) {
    error("Transaction failed");
    console.warn(e);
  } finally {
    isSubmitting.value = false;
  }
};
```

#### Withdraw operation (useEulerOperations composable) and components usage of it

```typescript
const withdraw = async (
  vaultAddress: string,
  assetAddress: string,
  assetsAmount: bigint,
  symbol: string,
  subAccount?: string,
  maxSharesAmount?: bigint,
  isMax?: boolean
) => {
  const { EULER_PROXY } = useEulerConfig();
  const { tacSdk } = useTacSdk();
  const { address: eulerAccountAddress } = useEulerAccount();
  const hooks = new SaHooksBuilder();
  const hasSign = await hasSignature(eulerAccountAddress.value);
  // const isTON = symbol === 'TON'

  hooks.addContractInterface(vaultAddress, [
    "function withdraw(uint256,address,address) external",
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(assetAddress, [
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(SIGN_CONTRACT_ADDRESS, [
    "function signTermsOfUse(string,bytes32) external",
  ]);

  if (!eulerAccountAddress.value) {
    throw "Euler account address is empty. Is it loaded properly?";
  }

  let sharesAmount = isMax
    ? maxSharesAmount || 0n
    : await previewWithdraw(vaultAddress, assetsAmount);

  if (isMax === false && maxSharesAmount && sharesAmount > maxSharesAmount) {
    sharesAmount = maxSharesAmount;
  }

  if (!subAccount) {
    hooks.addPreHookCallFromSA(vaultAddress, "approve", [
      vaultAddress,
      sharesAmount,
    ]);
    hooks.addPreHookCallFromSelf(vaultAddress, "transfer", [
      eulerAccountAddress.value,
      sharesAmount,
    ]);
  } else {
    hooks.addPostHookCallFromSA(assetAddress, "transfer", [
      EULER_PROXY,
      assetsAmount,
    ]);
  }

  let callData;
  if (!hasSign) {
    const batchString = "tuple(address,address,uint256,bytes)[]";
    const dataForCall = hooks.getDataForCall(vaultAddress, "withdraw", [
      assetsAmount,
      subAccount ? eulerAccountAddress.value : EULER_PROXY,
      subAccount || eulerAccountAddress.value,
    ]);
    const signData = hooks.getDataForCall(
      SIGN_CONTRACT_ADDRESS,
      "signTermsOfUse",
      [FINAL_MESSAGE, FINAL_HASH]
    );
    const batchItems = [
      [SIGN_CONTRACT_ADDRESS, eulerAccountAddress.value, 0n, signData],
      [vaultAddress, eulerAccountAddress.value, 0n, dataForCall],
    ];
    callData = new ethers.AbiCoder().encode(
      [hooks.tupleString(), hooks.bridgeString(), batchString],
      [hooks.build(), [subAccount ? [] : [vaultAddress]], batchItems]
    );
  } else {
    const callString = "tuple(address,address,uint256,bytes)";
    const dataForCall = hooks.getDataForCall(vaultAddress, "withdraw", [
      assetsAmount,
      subAccount ? eulerAccountAddress.value : EULER_PROXY,
      subAccount || eulerAccountAddress.value,
    ]);
    callData = new ethers.AbiCoder().encode(
      [hooks.tupleString(), hooks.bridgeString(), callString],
      [
        hooks.build(),
        [[assetAddress]],
        [
          vaultAddress,
          subAccount || eulerAccountAddress.value,
          0n,
          dataForCall,
        ],
      ]
    );
  }
  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: EULER_PROXY,
    methodName: !hasSign ? "batch(bytes,bytes)" : "call(bytes,bytes)",
    encodedParameters: callData,
  };

  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = subAccount
    ? []
    : [
        {
          // ...(!isTON && { address: await tacSdk.getTVMTokenAddress(vaultAddress) }),
          address: await tacSdk.getTVMTokenAddress(vaultAddress),
          rawAmount: sharesAmount,
          type: AssetType.FT,
        },
      ];
  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    assets
  );
  tacSdk.closeConnections();

  const tsResult = res.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!asset.value?.address) {
      return;
    }
    const tl = await withdraw(
      vaultAddress,
      asset.value!.address,
      amountFixed.value.value,
      asset.value.symbol,
      undefined,
      sharesBalance.value,
      FixedNumber.fromValue(assetsBalance.value, asset.value?.decimals).lte(
        amountFixed.value
      )
    );
    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: async () => {
        await updateBalance();
        await updateBalances();
      },
    });
  } catch (e) {
    error("Transaction failed");
    console.warn(e);
  } finally {
    isSubmitting.value = false;
  }
};
```

#### Borrow operation (useEulerOperations composable) and components usage of it

```typescript
const borrow = async (
  vaultAddress: string,
  assetAddress: string,
  amount: bigint,
  borrowVaultAddress: string,
  borrowAssetAddress: string,
  borrowAmount: bigint,
  assetSymbol: string,
  subAcc?: string
) => {
  const { EULER_PROXY, ETH_VAULT_CONNECTOR } = useEulerConfig();
  const { tacSdk } = useTacSdk();
  const { address: eulerAccountAddress } = useEulerAccount();
  const hooks = new SaHooksBuilder();
  const hasSign = await hasSignature(eulerAccountAddress.value);
  const isTON = assetSymbol === "TON";

  hooks.addContractInterface(vaultAddress, [
    "function transfer(address,uint256) external",
    "function deposit(uint256,address) external",
  ]);
  hooks.addContractInterface(borrowAssetAddress, [
    "function transfer(address,uint256) external",
    "function deposit(uint256,address) external",
  ]);
  hooks.addContractInterface(borrowVaultAddress, [
    "function borrow(uint256 amount, address receiver) external returns (uint256)",
  ]);
  hooks.addContractInterface(ETH_VAULT_CONNECTOR, [
    "function enableCollateral(address account, address vault) external payable",
    "function enableController(address account, address vault) external payable",
  ]);
  hooks.addContractInterface(assetAddress, [
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(SIGN_CONTRACT_ADDRESS, [
    "function signTermsOfUse(string,bytes32) external",
  ]);

  const subAccount =
    subAcc || (await getNewSubAccount(eulerAccountAddress.value));
  const depositData = hooks.getDataForCall(vaultAddress, "deposit", [
    amount,
    subAccount,
  ]);
  const borrowData = hooks.getDataForCall(borrowVaultAddress, "borrow", [
    borrowAmount,
    eulerAccountAddress.value,
  ]);
  const controllerData = hooks.getDataForCall(
    ETH_VAULT_CONNECTOR,
    "enableController",
    [subAccount, borrowVaultAddress]
  );
  const collateralData = hooks.getDataForCall(
    ETH_VAULT_CONNECTOR,
    "enableCollateral",
    [subAccount, vaultAddress]
  );
  const signData = hooks.getDataForCall(
    SIGN_CONTRACT_ADDRESS,
    "signTermsOfUse",
    [FINAL_MESSAGE, FINAL_HASH]
  );

  const batchString = "tuple(address,address,uint256,bytes)[]";
  const batchItems = [
    [vaultAddress, eulerAccountAddress.value, 0n, depositData],
    [ETH_VAULT_CONNECTOR, ethers.ZeroAddress, 0n, controllerData],
    [ETH_VAULT_CONNECTOR, ethers.ZeroAddress, 0n, collateralData],
    [borrowVaultAddress, subAccount, 0n, borrowData],
  ];
  if (!hasSign) {
    batchItems.unshift([
      SIGN_CONTRACT_ADDRESS,
      eulerAccountAddress.value,
      0n,
      signData,
    ]);
  }

  hooks.addPreHookCallFromSA(assetAddress, "approve", [vaultAddress, amount]);
  hooks.addPreHookCallFromSelf(assetAddress, "transfer", [
    eulerAccountAddress.value,
    amount,
  ]);
  hooks.addPostHookCallFromSA(borrowAssetAddress, "transfer", [
    EULER_PROXY,
    borrowAmount,
  ]);

  const callData = new ethers.AbiCoder().encode(
    [hooks.tupleString(), hooks.bridgeString(), batchString],
    [hooks.build(), [[borrowAssetAddress]], batchItems]
  );

  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: EULER_PROXY,
    methodName: "batch(bytes,bytes)",
    encodedParameters: callData,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = [
    {
      // address: await tacSdk.getTVMTokenAddress(vaultAddress), // use with collateral
      ...(!isTON && { address: await tacSdk.getTVMTokenAddress(assetAddress) }), // use with user's assets
      rawAmount: amount,
      type: AssetType.FT,
    },
  ];

  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    subAcc ? undefined : assets
  );
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!collateralVault.value || !borrowVault.value) {
      return;
    }
    const tl = await borrow(
      collateralVault.value.address,
      collateralVault.value.asset.address,
      collateralAmountFixed.value.toFormat({
        decimals: Number(collateralVault.value.decimals),
      }).value,
      borrowVault.value.address,
      borrowVault.value.asset.address,
      borrowAmountFixed.value.toFormat({
        decimals: Number(borrowVault.value.decimals),
      }).value,
      collateralVault.value.asset.symbol
    );
    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: () => {
        updateEstimates();
        updateBalance();
        updateBorrowPositions();
        setTimeout(() => {
          router.replace("/portfolio");
        }, 400);
      },
    });
  } catch (e) {
    console.warn(e);
    error("Transaction failed");
  } finally {
    isSubmitting.value = false;
  }
};
```

#### Repay (and full repay) operations (useEulerOperations composable) and components usage of it

```typescript
const repay = async (
  subAccount: string,
  vaultAddress: string,
  assetAddress: string,
  amount: bigint,
  borrowVaultAddress: string,
  borrowAssetAddress: string,
  borrowAssetSymbol: string
) => {
  const { EULER_PROXY, ETH_VAULT_CONNECTOR } = useEulerConfig();
  const { tacSdk } = useTacSdk();
  const { address: eulerAccountAddress } = useEulerAccount();
  const hooks = new SaHooksBuilder();
  const hasSign = await hasSignature(eulerAccountAddress.value);
  const isTON = borrowAssetSymbol === "TON";

  hooks.addContractInterface(borrowAssetAddress, [
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(assetAddress, [
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(borrowVaultAddress, [
    "function repay(uint256 amount, address receiver) external returns (uint256)",
  ]);
  hooks.addContractInterface(ETH_VAULT_CONNECTOR, [
    "function disableCollateral(address account, address vault) external payable",
    "function disableController(address account) external payable",
  ]);
  hooks.addContractInterface(SIGN_CONTRACT_ADDRESS, [
    "function signTermsOfUse(string,bytes32) external",
  ]);

  hooks.addPreHookCallFromSA(borrowAssetAddress, "approve", [
    borrowVaultAddress,
    amount,
  ]);
  hooks.addPreHookCallFromSelf(borrowAssetAddress, "transfer", [
    eulerAccountAddress.value,
    amount,
  ]);
  const repayData = hooks.getDataForCall(borrowVaultAddress, "repay", [
    amount,
    subAccount,
  ]);
  const batchString = "tuple(address,address,uint256,bytes)";

  const batchItems = [
    borrowVaultAddress,
    eulerAccountAddress.value,
    0n,
    repayData,
  ];
  const callData = new ethers.AbiCoder().encode(
    [hooks.tupleString(), hooks.bridgeString(), batchString],
    [hooks.build(), [[]], batchItems]
  );

  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: EULER_PROXY,
    methodName: "call(bytes,bytes)",
    encodedParameters: callData,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = [
    {
      ...(!isTON && {
        address: await tacSdk.getTVMTokenAddress(borrowAssetAddress),
      }),
      rawAmount: amount,
      type: AssetType.FT,
    },
  ];
  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    assets
  );
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
const fullRepay = async (
  subAccount: string,
  vaultAddress: string,
  assetAddress: string,
  amount: bigint,
  borrowVaultAddress: string,
  borrowAssetAddress: string,
  borrowAssetSymbol: string
) => {
  const { EULER_PROXY, ETH_VAULT_CONNECTOR } = useEulerConfig();
  const { tacSdk } = useTacSdk();
  const { address: eulerAccountAddress } = useEulerAccount();
  const hooks = new SaHooksBuilder();
  const isTON = borrowAssetSymbol === "TON";

  hooks.addContractInterface(borrowAssetAddress, [
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(assetAddress, [
    "function approve(address,uint256) external",
    "function transfer(address,uint256) external",
  ]);
  hooks.addContractInterface(borrowVaultAddress, [
    "function repay(uint256 amount, address receiver) external returns (uint256)",
  ]);
  hooks.addContractInterface(vaultAddress, [
    "function redeem(uint256,address,address) external",
    "function deposit(uint256,address) external",
  ]);
  hooks.addContractInterface(ETH_VAULT_CONNECTOR, [
    "function disableCollateral(address account, address vault) external payable",
    "function disableController(address account) external payable",
  ]);

  hooks.addPreHookCallFromSA(borrowAssetAddress, "approve", [
    borrowVaultAddress,
    ethers.MaxUint256,
  ]);
  hooks.addPreHookCallFromSA(assetAddress, "approve", [
    vaultAddress,
    ethers.MaxUint256,
  ]);
  hooks.addPreHookCallFromSelf(borrowAssetAddress, "transfer", [
    eulerAccountAddress.value,
    amount,
  ]);
  const repayData = hooks.getDataForCall(borrowVaultAddress, "repay", [
    ethers.MaxUint256,
    subAccount,
  ]);
  const controllerData = hooks.getDataForCall(
    ETH_VAULT_CONNECTOR,
    "disableController",
    [subAccount]
  );
  const collateralData = hooks.getDataForCall(
    ETH_VAULT_CONNECTOR,
    "disableCollateral",
    [subAccount, vaultAddress]
  );
  const withdrawData = hooks.getDataForCall(vaultAddress, "redeem", [
    ethers.MaxUint256,
    eulerAccountAddress.value,
    subAccount,
  ]);
  const depositData = hooks.getDataForCall(vaultAddress, "deposit", [
    ethers.MaxUint256,
    EULER_PROXY,
  ]);

  const batchString = "tuple(address,address,uint256,bytes)[]";

  const batchItems = [
    [borrowVaultAddress, eulerAccountAddress.value, 0n, repayData],
    [ETH_VAULT_CONNECTOR, ethers.ZeroAddress, 0n, controllerData],
    [ETH_VAULT_CONNECTOR, ethers.ZeroAddress, 0n, collateralData],
    [vaultAddress, subAccount, 0n, withdrawData],
    [vaultAddress, eulerAccountAddress.value, 0n, depositData],
  ];

  const callData = new ethers.AbiCoder().encode(
    [hooks.tupleString(), hooks.bridgeString(), batchString],
    [hooks.build(), [[vaultAddress, borrowAssetAddress]], batchItems]
  );

  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: EULER_PROXY,
    methodName: "batch(bytes,bytes)",
    encodedParameters: callData,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = [
    {
      ...(!isTON && {
        address: await tacSdk.getTVMTokenAddress(borrowAssetAddress),
      }),
      rawAmount: amount,
      type: AssetType.FT,
    },
  ];
  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    assets
  );
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!position.value || !borrowVault.value || !collateralVault.value) {
      return;
    }
    const method =
      balance.value <=
      valueToNano(amount.value, borrowVault.value.asset.decimals)
        ? fullRepay
        : repay;
    console.log(
      balance.value <=
        valueToNano(amount.value, borrowVault.value.asset.decimals)
    );
    const tl = await method(
      position.value.subAccount,
      collateralVault.value.address,
      collateralVault.value.asset.address,
      valueToNano(amount.value, borrowVault.value.asset.decimals),
      borrowVault.value.address,
      borrowVault.value.asset.address,
      borrowVault.value.asset.symbol
    );

    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: () => {
        setTimeout(() => {
          updateBorrowPositions();
          router.replace("/portfolio");
        }, 400);
      },
    });
  } catch (e) {
    error("Transaction failed");
    console.warn(e);
  } finally {
    isSubmitting.value = false;
  }
};
```

#### Components using supply to supply more

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!asset.value?.address) {
      return;
    }
    const tl = await supply(
      collateralVault.value.address,
      asset.value.address,
      valueToNano(amount.value || "0", asset.value.decimals),
      asset.value.symbol,
      position.value.subAccount
    );
    console.log(tl);

    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: async () => {
        await updateBalance();
        await updateEstimates();
      },
    });
  } catch (e) {
    console.warn(e);
    error("Transaction failed");
  } finally {
    isSubmitting.value = false;
  }
};
```

#### Components using borrow to borrow more

```typescript
const send = async () => {
  try {
    isSubmitting.value = true;
    if (!collateralVault.value || !borrowVault.value) {
      return;
    }
    const tl = await borrow(
      collateralVault.value.address,
      collateralVault.value.asset.address,
      0n,
      borrowVault.value.address,
      borrowVault.value.asset.address,
      borrowAmountFixed.value.toFormat({
        decimals: Number(borrowVault.value.decimals),
      }).value,
      collateralVault.value.asset.symbol,
      position.value?.subAccount
    );
    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
      onClose: () => {
        updateEstimates();
        updateBalance();
        updateBorrowPositions();
        setTimeout(() => {
          router.replace("/portfolio");
        }, 400);
      },
    });
  } catch (e) {
    console.warn(e);
    error("Transaction failed");
  } finally {
    isSubmitting.value = false;
  }
};
```

## TAC Network

### SDK initialization

- [Back to the top](#table-of-contents)

#### tacSdk init function, called on startup

```typescript
const init = async () => {
  try {
    const { TVM_TONCENTER_URL, NETWORK, EVM_PROVIDER_URL } = useEulerConfig();

    const TONParams =
      NETWORK === Network.MAINNET
        ? {
            contractOpener: new TonClient({
              endpoint: `${TVM_TONCENTER_URL}/api/v2/jsonRPC`,
            }),
          }
        : {
            contractOpener: new TonClient({
              endpoint: `${TVM_TONCENTER_URL}/api/v2/jsonRPC`,
            }),
            settingsAddress: "EQCQTgXQ99LqwpeYUxDml9DeYTqoqnZEqiTnRyc63Um9RYn5",
          };
    const otherParams =
      NETWORK === Network.MAINNET
        ? {}
        : {
            TACParams: {
              settingsAddress: "0xCf4066EC68e24C9f28A577A48AA404459E871bA9",
              provider: ethers.getDefaultProvider(EVM_PROVIDER_URL),
            },
            customLiteSequencerEndpoints: [
              "https://datav3-combat.turin.tac.build",
            ],
          };

    tacSdk = await TacSdk.create({
      network: NETWORK,
      TONParams,
      ...otherParams,
    });
  } catch (e) {
    console.warn(e);
    if (isAxiosError(e)) {
      throw showError({
        statusCode: e.status,
        statusMessage: `TAC SDK failed to initialize: ${e.message}. Try again later.`,
      });
    }
    throw showError({
      statusMessage: "TAC SDK failed to initialize. Try again later.",
    });
  } finally {
    isLoaded.value = true;
  }
};
```

### Cross-chain transaction data and sending

- [Back to the top](#table-of-contents)

#### Example of tacSdk usage - claiming Merkl reward using tacSdk.sendCrossChainTransaction

```typescript
const claimReward = async (reward: Reward) => {
  const { isLoaded } = useTacSdk();
  await until(isLoaded).toBeTruthy();
  const { tacSdk } = useTacSdk();

  const encodedArguments = new ethers.AbiCoder().encode(
    ["tuple(address[],uint256[],bytes32[][],bool)"],
    [
      [
        [reward.token.address],
        [reward.amount],
        [reward.proofs],
        reward.token.symbol !== "rEUL",
      ],
    ]
  );
  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: MERKL_PROXY,
    methodName: "claim(bytes,bytes)",
    encodedParameters: encodedArguments,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });

  const res = await tacSdk.sendCrossChainTransaction(evmProxyMsg, sender);
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

### TVM to EVM, EVM to TVM addresses mapping

- [Back to the top](#table-of-contents)

#### Example of address mapping usage - a chunk of "withdraw" euler operation

```typescript
const withdraw = async (
  vaultAddress: string,
  assetAddress: string,
  assetsAmount: bigint,
  symbol: string,
  subAccount?: string,
  maxSharesAmount?: bigint,
  isMax?: boolean
) => {
  // the rest of code...
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const assets: RawAssetBridgingData[] = subAccount
    ? []
    : [
        {
          // ...(!isTON && { address: await tacSdk.getTVMTokenAddress(vaultAddress) }),
          address: await tacSdk.getTVMTokenAddress(vaultAddress),
          rawAmount: sharesAmount,
          type: AssetType.FT,
        },
      ];
  const res = await tacSdk.sendCrossChainTransaction(
    evmProxyMsg,
    sender,
    assets
  );
  tacSdk.closeConnections();
  // the rest of code...
};
```

### Jetton addresses fetching

- [Back to the top](#table-of-contents)

#### Example of jetton balance fetching usage - updateBalance function:

```typescript
const updateBalance = async (isInitialLoading = true) => {
  const { tacSdk } = useTacSdk();
  if (!isConnected.value) {
    balance.value = 0n;
    return;
  }
  if (isInitialLoading) {
    isBalanceLoading.value = true;
  }

  if (collateralVault.value?.asset.symbol === "TON") {
    const client = new TonClient({
      endpoint: `${TVM_TONCENTER_URL}/api/v2/jsonRPC`,
    });
    balance.value = await client.getBalance(
      Address.parse(friendlyAddress.value)
    );
  } else {
    balance.value = await tacSdk
      .getUserJettonBalance(address.value, tvmAssetAddress)
      .catch((e) => {
        console.warn(e);
        return 0n;
      });
  }
  isBalanceLoading.value = false;
};
```

## Merkl Rewards

### Merkl Initialization

- [Back to the top](#table-of-contents)

#### initMerkl, merkl smart acc predicting

```typescript
const address = ref("");

const initMerkl = async (tvmAddress: string | undefined) => {
  address.value = "";

  if (!tvmAddress) {
    return;
  }

  try {
    const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
    const tacFactoryAbi = [
      "function predictSmartAccountAddress(string, address) external view returns(address)",
    ];
    const addressContract = new ethers.Contract(
      MERKL_TAC_SA_FACTORY,
      tacFactoryAbi,
      provider
    );
    address.value = await addressContract.predictSmartAccountAddress(
      Address.parse(tvmAddress).toString({ bounceable: true }),
      MERKL_PROXY
    );
  } catch (e) {
    console.warn(e);
    address.value = "";
  }
};

watch(
  friendlyAddress,
  (val) => {
    initMerkl(val);
    loadOpportunities();
    loadRewards();
    loadREULLocksInfo();
  },
  { immediate: true }
);
```

### Reward opportunities and campaigns

- [Back to the top](#table-of-contents)

#### Opportunities fetching, saving it inside useMerkl composable

```typescript
const lendOpportunities: Ref<Opportunity[]> = ref([])
const borrowOpportunities: Ref<Opportunity[]> = ref([]

const loadOpportunities = async (isInitialLoading = true) => {
  try {
    if (isInitialLoading) {
      isOpportunitiesLoading.value = true
    }
    const res = await axios.get(endpoints.opportunities, {
      params: {
        type: 'EULER',
        chainId: MERKL_EULER_CHAIN_ID,
      },
    })

    const opportunities: Opportunity[] = res.data

    if (opportunities) {
      const lends = []
      const borrows = []

      for (let i = 0; i < opportunities.length; i++) {
        if (opportunities[i].status === 'LIVE') {
          switch (opportunities[i].action) {
            case 'BORROW':
              borrows.push(opportunities[i])
              break
            case 'LEND':
              lends.push(opportunities[i])
              break
            default:
              break
          }
        }
      }

      lendOpportunities.value = lends
      borrowOpportunities.value = borrows
    }
  }
  catch (e) {
    console.warn(e)
  }
  finally {
    isOpportunitiesLoading.value = false
  }
}

watch(
  friendlyAddress,
  (val) => {
    initMerkl(val);
    loadOpportunities();
    loadRewards();
    loadREULLocksInfo();
  },
  { immediate: true }
);
```

#### Components using opportunities through getOpportunity\*\* helper functions

##### The functions

```typescript
const getOpportunityOfLendVault = (vaultAddress: string) => {
  return lendOpportunities.value.find(
    (opportunity) => opportunity.identifier === vaultAddress
  );
};

const getOpportunityOfBorrowVault = (assetAddress: string) => {
  return borrowOpportunities.value.find(
    (opportunity) =>
      !!opportunity.tokens.find(
        (tokenInfo) => tokenInfo.address === assetAddress
      )
  );
};
```

##### Usage example

```typescript
const { getOpportunityOfLendVault } = useMerkl();

const opportunityInfo = computed(() =>
  getOpportunityOfLendVault(vault.value.address)
);
```

```vue
<template>
  <!-- code.. -->
  <div :class="$style.apy" class="p2">
    <SvgIcon
      v-if="opportunityInfo?.apr"
      name="sparks"
      class="icon--20 text-aquamarine-700 mr-4"
    />
    {{
      formatNumber(
        nanoToValue(vault.interestRateInfo.supplyAPY, 25) +
          (opportunityInfo?.apr || 0)
      )
    }}%
  </div>
  <!-- code.. -->
</template>
```

### User reward balances

- [Back to the top](#table-of-contents)

#### Reward fetching in useMerkl composable

```typescript
const rewards: Ref<Reward[]> = ref([]);

const loadRewards = async (isInitialLoading = true) => {
  await until(address).toBeTruthy();
  try {
    if (!address.value) {
      rewards.value = [];
      return;
    }
    if (isInitialLoading) {
      isRewardsLoading.value = true;
    }
    const res = await axios.get(endpoints.rewards(address.value), {
      params: {
        chainId: MERKL_EULER_CHAIN_ID,
      },
    });

    const data = res.data;

    const rewardsList: Reward[] = data.reduce(
      (prev: Reward[], curr: RewardsResponseItem) => {
        return [...prev, ...curr.rewards];
      },
      [] as Reward[]
    );

    rewards.value = rewardsList.filter(
      (reward) => reward.claimed !== reward.amount
    );
  } catch (e) {
    console.warn(e);
  } finally {
    isRewardsLoading.value = false;
  }
};
```

#### Components using fetched rewards

```vue
<script setup lang="ts">
const { rewards, isRewardsLoading, locks, isLocksLoading } = useMerkl();
</script>

<template>
  <!-- code.. -->
  <div :class="$style.tabContent">
    <PortfolioList :items="rewards" type="rewards" />
  </div>
  <!-- code.. -->
</template>
```

### Reward claiming

- [Back to the top](#table-of-contents)

#### claimReward function, uses TAC to send cross-chain transaction

```typescript
const claimReward = async (reward: Reward) => {
  const { isLoaded } = useTacSdk();
  await until(isLoaded).toBeTruthy();
  const { tacSdk } = useTacSdk();

  const encodedArguments = new ethers.AbiCoder().encode(
    ["tuple(address[],uint256[],bytes32[][],bool)"],
    [
      [
        [reward.token.address],
        [reward.amount],
        [reward.proofs],
        reward.token.symbol !== "rEUL",
      ],
    ]
  );
  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: MERKL_PROXY,
    methodName: "claim(bytes,bytes)",
    encodedParameters: encodedArguments,
  };
  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });

  const res = await tacSdk.sendCrossChainTransaction(evmProxyMsg, sender);
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

#### Components using claimReward

```typescript
const { isTokensLoading, rewardTokens, claimReward } = useMerkl();

const claim = async () => {
  try {
    isClaiming.value = true;

    const tl = await claimReward(reward);

    modal.open(OperationTrackerTransactionModal, {
      props: { transactionLinker: tl },
    });
  } catch (e) {
    console.warn(e);
  } finally {
    isClaiming.value = false;
  }
};
```

### REUL lock mechanisms and unlock schedules, unlocking

- [Back to the top](#table-of-contents)

#### Locks fetching, storing it in useMerkl composable

```typescript
const locks: Ref<REULLock[]> = ref([]);

const loadREULLocksInfo = async (isInitialLoading = true) => {
  await until(address).toBeTruthy();
  try {
    if (!address.value) {
      locks.value = [];
      return;
    }
    if (isInitialLoading) {
      isLocksLoading.value = true;
    }

    const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
    const contract = new ethers.Contract(
      REUL_TOKEN_CONTRACT_ADDRESS,
      [
        "function getLockedAmounts(address account) view returns (uint256[], uint256[])",
        "function getWithdrawAmountsByLockTimestamp(address account, uint256 lockTimestamp) view returns (uint256, uint256)",
        "function withdrawToByLockTimestamp(address account, uint256 lockTimestamp, bool allowRemainderLoss) external",
      ],
      provider
    );

    const [lockTimestamps, amounts] = await contract.getLockedAmounts(
      address.value
    );
    const withdrawAmountsData: {
      unlockableAmount: bigint;
      amountToBeBurned: bigint;
    }[] = [];

    const batchSize = 5;

    for (let i = 0; i < lockTimestamps.length; i += batchSize) {
      const batch = lockTimestamps
        .slice(i, i + batchSize)
        .map(async (timestamp: string) => {
          const [unlockableAmount, amountToBeBurned] =
            await contract.getWithdrawAmountsByLockTimestamp(
              address.value,
              timestamp
            );
          return {
            unlockableAmount,
            amountToBeBurned,
          };
        });

      withdrawAmountsData.push(...(await Promise.all(batch)));
    }

    locks.value = withdrawAmountsData.map((item, index) => ({
      timestamp: lockTimestamps[index],
      amount: amounts[index],
      unlockableAmount: item.unlockableAmount,
      amountToBeBurned: item.amountToBeBurned,
    }));
  } catch (e) {
    console.warn(e);
  } finally {
    isLocksLoading.value = false;
  }
};
```

#### Unlocking function, uses TAC

```typescript
const unlockREUL = async (lockTimestamps: bigint[]) => {
  const { isLoaded } = useTacSdk();
  await until(isLoaded).toBeTruthy();
  const { tacSdk } = useTacSdk();
  // const oneTimestampFunctionSelector = '0xd47d9de6'
  const manyTimestampsFunctionSelector = "0x4f570258";

  const withdrawToByLockTimestampData = new ethers.AbiCoder().encode(
    ["tuple(uint256[],bool)"],
    [[lockTimestamps, true]]
  );

  const encodedArguments = new ethers.AbiCoder().encode(
    ["tuple(address,bytes4[],bytes[],address[])"],
    [
      [
        REUL_TOKEN_CONTRACT_ADDRESS,
        [manyTimestampsFunctionSelector],
        [withdrawToByLockTimestampData],
        [EUL_TOKEN_CONTRACT_ADDRESS],
      ],
    ]
  );
  const evmProxyMsg: EvmProxyMsg = {
    evmTargetAddress: MERKL_PROXY,
    methodName: "customFunctionCall(bytes,bytes)",
    encodedParameters: encodedArguments,
  };

  const sender = await SenderFactory.getSender({ tonConnect: tonConnectUI });
  const res = await tacSdk.sendCrossChainTransaction(evmProxyMsg, sender);
  tacSdk.closeConnections();

  const tsResult = res?.sendTransactionResult as {
    success: boolean;
    error: Record<string, unknown>;
  };
  if (!tsResult?.success) {
    throw tsResult?.error?.info || "Unknown error";
  }

  return res;
};
```

#### Components using fetched locks

```vue
<script setup lang="ts">
const { rewards, isRewardsLoading, locks, isLocksLoading } = useMerkl();
</script>

<template>
  <!-- code.. -->
  <div class="text-white br-16">
    <RewardUnlockList :items="locks" />
  </div>
  <!-- code.. -->
</template>
```

#### Components using unlocking

```typescript
const onUnlockClick = () => {
  modal.open(RewardUnlockConfirmModal, {
    props: {
      item,
      onConfirm: async () => {
        isUnlocking.value = true;
        setTimeout(() => {
          isUnlocking.value = false;
        }, 5000);

        const tl = await unlockREUL([item.timestamp]);

        modal.open(OperationTrackerTransactionModal, {
          props: { transactionLinker: tl },
        });
      },
    },
  });
};
```

## Goldsky Subgraph

### Borrow positions fetching

- [Back to the top](#table-of-contents)

#### updateBorrowPositions function, uses Goldsky API with Euler smartacc address to fetch borrows of the user, stores it in useEulerAccount composable

```typescript
const borrowPositions: Ref<AccountBorrowPosition[]> = ref([]);

const updateBorrowPositions = async (isInitialLoading = true) => {
  if (isInitialLoading) {
    isPositionsLoading.value = true;
  }

  const { NETWORK, EVM_PROVIDER_URL, GOLDSKY_API_URL } = useEulerConfig();
  const { isReady, map } = useVaults();
  await until(isReady).toBe(true);
  const provider = ethers.getDefaultProvider(EVM_PROVIDER_URL);
  const accountLensContract = new ethers.Contract(
    eulerLensAddresses[NETWORK].accountLens,
    eulerAccountLensABI,
    provider
  );
  const { data } = await axios.post(GOLDSKY_API_URL, {
    query: `query AccountBorrows {
      trackingActiveAccount(id: "${address.value}") {
        borrows
      }
    }`,
    operationName: "AccountBorrows",
  });
  const borrowEntries = data.data.trackingActiveAccount?.borrows || [];

  let borrows: AccountBorrowPosition[] = [];
  const batchSize = 5;

  for (let i = 0; i < borrowEntries.length; i += batchSize) {
    const batch = borrowEntries
      .slice(i, i + batchSize)
      .map(async (entry: string) => {
        const vault = `0x${entry.substring(42)}`;
        const subAccount = entry.substring(0, 42);

        const res = await accountLensContract.getVaultAccountInfo(subAccount, vault);
        if (!res.isController || res.borrowed === 0n) {
          return undefined;
        }
        const collaterals = res.liquidityInfo?.collaterals || [];
        const collateral = collaterals.length ? map.value.get(ethers.getAddress(collaterals[0])) : undefined;
        const borrow = map.value.get(ethers.getAddress(vault));
        if (!collateral || !borrow) {
          return undefined;
        }
        const cLTV = borrow?.collateralLTVs.find(
          (ltv) => ltv.collateral === collateral.address
        );
        const collateralValueLiquidation =
          res.vaultAccountInfo.liquidityInfo.collateralValueLiquidation;
        const liabilityValue =
          res.vaultAccountInfo.liquidityInfo.liabilityValue;
        const liquidationLTV = cLTV?.liquidationLTV || 0n;
        const healthFixed = FixedNumber.fromValue(
          collateralValueLiquidation,
          18
        ).div(FixedNumber.fromValue(liabilityValue, 18));
        const userLTVFixed = healthFixed.isZero()
          ? FixedNumber.fromValue(0n, 2)
          : FixedNumber.fromValue(liquidationLTV, 2).div(healthFixed);
        const userLTV = userLTVFixed.value;
        // Conservative price ratio: collateral.bid / liability.ask
        // Matches EVK on-chain convention (LiquidityUtils.sol)
        const priceFixed = FixedNumber.fromValue(
          collateral.liabilityPriceInfo.amountOutBid || 0n,
          18
        ).div(
          FixedNumber.fromValue(
            borrow.liabilityPriceInfo.amountOutAsk || 1n,
            18
          )
        );
        const price = priceFixed.value;
        const borrowedFixed = FixedNumber.fromValue(
          res.vaultAccountInfo.borrowed,
          borrow.decimals
        );
        const supplied = borrowedFixed
          .div(userLTVFixed.div(FixedNumber.fromValue(100n)))
          .div(priceFixed)
          .round(Number(collateral.decimals))
          .toFormat({ decimals: Number(collateral.decimals) }).value;

        return {
          borrow,
          collateral,
          subAccount,
          liabilityLTV: 0n,
          borrowLTV: cLTV?.borrowLTV || 0n,
          initialLiquidationLTV: cLTV?.initialLiquidationLTV || 0n,
          timeToLiquidation:
            res.vaultAccountInfo.liquidityInfo.timeToLiquidation,
          health: healthFixed.value,
          borrowed: res.vaultAccountInfo.borrowed,
          price,
          userLTV,
          supplied,
          liabilityValue,
          liquidationLTV,
          collateralValueLiquidation,
        } as AccountBorrowPosition;
      });

    borrows = [
      ...borrows,
      ...(await Promise.all(batch)).filter((o) => !!o),
    ] as AccountBorrowPosition[];
  }

  borrowPositions.value = borrows;

  isPositionsLoading.value = false;
  isPositionsLoaded.value = true;
};
```
