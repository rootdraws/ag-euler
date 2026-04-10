# Frontend Integration Stash — Cork & Origin

Nuxt layer code extracted from the old consolidated frontend. Ready to be integrated into Michael's frontend (`frontend/`) when needed.

## Cork (Ethereum / Tenderly fork 9991)

Dual-collateral borrow: deposit vbUSDC + cST to borrow sUSDe in a single EVC batch.

| File | Purpose |
|---|---|
| `cork/pages/cork-borrow.vue` | Full borrow page UI |
| `cork/composables/borrow/useCorkBorrowForm.ts` | Form logic, balance checks, tx plan building |
| `cork/entities/forkChainMap.ts` | Maps Tenderly fork chain 9991 -> Ethereum mainnet |
| `cork/entities/chainRegistry.ts` | Adds Tenderly fork as a custom chain definition |
| `cork/nuxt.config.ts` | Layer config (empty, placeholder) |

**Contract addresses** are hardcoded in `useCorkBorrowForm.ts`:
- vbUSDC: `0x53E82ABbb12638F09d9e624578ccB666217a765e`
- cST: `0x1b42544f897b7ab236c111a4f800a54d94840688`
- sUSDe borrow vault: `0x53FDab35Fd3aA26577bAc29f098084fCBAbE502f`

**Feature flag:** `NUXT_PUBLIC_CONFIG_ENABLE_CORK_BORROW_PAGE`

## Origin ARM (Ethereum)

Leveraged stETH via ARM adapter — routes WETH -> ARM-WETH-stETH through Swapper GenericHandler.

| File | Purpose |
|---|---|
| `origin/composables/useArmRoute.ts` | Builds SwapApiQuote for ARM deposit routing |
| `origin/abis/arm.ts` | ARM contract ABI (deposit, previewDeposit, convertTo*) |
| `origin/nuxt.config.ts` | Layer config (empty, placeholder) |

**Feature flag:** `NUXT_PUBLIC_CONFIG_ARM_ADAPTER_CONFIG` (JSON map of collateral vault -> ARM address)

## Integration Notes

- These were Nuxt layers (`extends` in nuxt.config.ts). Michael's frontend may use a different extension pattern.
- Cork depends on `useEulerOperations().buildDualCollateralBorrowPlan` and `useTermsOfUseGate` from the AG shared layer.
- Origin depends on `SwapApiQuote`/`SwapApiVerify` types and `swapVerifierAbi` from euler-lite.
