# euler-lite-frax — Frontend Context

Frax FX Markets frontend. Fork of `ag-euler-lite` customized for the Frax ICHI vault cluster on Base (8453).

**Parent repo:** `rootdraws/ag-euler-lite` (shared euler-lite frontend)
**Labels repo:** `rootdraws/ag-euler-frax-labels` (branch: `main`)
**Contract context:** See `frax-contracts/frax-claude.md` in the AG-Euler workspace.

---

## What This Frontend Shows

One frxUSD borrow market with 5 ICHI vault LP collateral types on Base:

| Vault | Pair | Collateral |
|---|---|---|
| frxUSD Lending | (borrow vault) | frxUSD supply |
| frxUSD/BRZ ICHI LP | Brazilian Real / frxUSD | ICHI vault shares |
| tGBP/frxUSD ICHI LP | British Pound / frxUSD | ICHI vault shares |
| USDC/frxUSD ICHI LP | USDC / frxUSD | ICHI vault shares |
| IDRX/frxUSD ICHI LP | Indonesian Rupiah / frxUSD | ICHI vault shares |
| KRWQ/frxUSD ICHI LP | Korean Won / frxUSD | ICHI vault shares |

All ICHI vaults are single-sided frxUSD deposits on Hydrex (Algebra V3 DEX on Base).

---

## Configuration

- **Chain:** Base only (8453). `.env` has `RPC_URL_HTTP_8453` + matching subgraph.
- **Pages:** Lend enabled, Earn and Explore disabled.
- **Labels:** Fetched from `rootdraws/ag-euler-frax-labels` on GitHub.
- **Theme:** `themeHue = 0` (neutral). Actual palette from SCSS variables.
- **Branding:** "Frax FX Markets" title. Entity logos: Frax, ICHI, Hydrex, Alpha Growth.

---

## Key Differences from Shared euler-lite

1. Base-only deployment (no multi-chain).
2. No EulerEarn vaults (earn page disabled).
3. ICHI vault collateral — not standard ERC-20 tokens. The frontend displays these as regular collateral vaults; the oracle handles pricing.
4. No multiply/leverage feature planned initially (would need custom Swapper routing for ICHI vault shares).

---

## Deployed eVault Addresses (Base 8453)

| Vault | Address |
|---|---|
| frxUSD Borrow | `0x42BA0a943EDcc846333642d62F500894b199A798` |
| BRZ Collateral | `0xB5587B4BE26608c7a6E6081B50C43AEBbA09E187` |
| tGBP Collateral | `0xd8277Cbb6576085C192b9F920c5447aa5624a84B` |
| USDC Collateral | `0x417E102f1d2BF2E52d0599Da14Fb79dDb4B0b89F` |
| IDRX Collateral | `0x3371667cB5f6676fa14d95c3839da77705E46A39` |
| KRWQ Collateral | `0x764Fb38Fe7519d2544BACBc8A495Cf64c0505b44` |

---

## Deploy Checklist

- [ ] Set `NUXT_PUBLIC_APP_KIT_PROJECT_ID` (Reown)
- [x] Set `RPC_URL_HTTP_8453` (Alchemy Base RPC)
- [ ] Push `frax-labels` to `rootdraws/ag-euler-frax-labels` on GitHub
- [x] Replace placeholder addresses in labels with real deployed eVault addresses
- [ ] Create Vercel project `ag-euler-lite-frax`, set env vars
- [ ] Verify vaults appear in the UI
