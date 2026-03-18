# Euler Labels Submission Template

Reusable template for submitting new vaults to the official [euler-xyz/euler-labels](https://github.com/euler-xyz/euler-labels) repo. This makes vaults visible on app.euler.finance.

**Fork:** `rootdraws/euler-labels` (already forked from `euler-xyz/euler-labels`)

---

## Quick Steps

1. `cd euler-labels && git checkout master && git pull upstream master`
2. `git checkout -b feat/alphagrowth-<partner>-<market>`
3. Add logo(s) to `logo/` (square SVG/PNG/JPG)
4. Edit `<chainId>/entities.json`, `vaults.json`, `products.json`
5. `npm i && node verify.js` — must print `OK`
6. Commit, push, `gh pr create --repo euler-xyz/euler-labels`

---

## Entity Template (`<chainId>/entities.json`)

AlphaGrowth entity (add once per chain, skip if already present):

```json
"alphagrowth": {
  "name": "AlphaGrowth",
  "logo": "alphagrowth.svg",
  "description": "AlphaGrowth curates lending markets and structured DeFi products on Euler V2.",
  "url": "https://alphagrowth.io/",
  "addresses": {},
  "social": {
    "twitter": "alphagrowth1"
  }
}
```

---

## Vault Template (`<chainId>/vaults.json`)

Add one entry per vault. All fields required by verify.js:

```json
"0xVAULT_ADDRESS_CHECKSUMMED": {
  "name": "<Vault Display Name>",
  "description": "<One-line vault description>",
  "entity": "alphagrowth"
}
```

**Rules:**
- Address MUST be checksummed (`ethers.getAddress()` format)
- `name` max 40 characters
- `entity` must exist in `entities.json` on the same chain

---

## Product Template (`<chainId>/products.json`)

Every vault MUST belong to exactly one product:

```json
"<product-slug>": {
  "name": "<Product Display Name>",
  "description": "<Product description>",
  "entity": "alphagrowth",
  "logo": "<partner-logo-filename>",
  "url": "<partner-app-url>",
  "vaults": [
    "0xVAULT_1_CHECKSUMMED",
    "0xVAULT_2_CHECKSUMMED"
  ]
}
```

**Rules:**
- Product slug: lowercase alphanumeric + hyphens only (`^[a-z0-9-]+$`)
- Every vault in `vaults` array must exist in `vaults.json`
- A vault cannot appear in multiple products
- `entity` must exist in `entities.json`
- `logo` must exist in `logo/` directory

---

## Points Template (`<chainId>/points.json`)

Only needed if there are incentive/points programs. Otherwise leave as `[]`.

```json
{
  "name": "<Multiplier> <Points Name>",
  "logo": "<points-logo-filename>",
  "collateralVaults": ["0xVAULT_CHECKSUMMED"]
}
```

---

## Opportunities Template (`<chainId>/opportunities.json`)

Only needed for Cozy Finance safety modules. Otherwise leave as `{}`.

---

## Logo Requirements

- Format: SVG (preferred), PNG, or JPG
- **Must be square** (equal width and height)
- Place in `logo/` directory at repo root (shared across all chains)
- `alphagrowth.svg` already exists in the repo

---

## Verify Script Checks

`node verify.js` validates ALL chains. It checks:
- All addresses are checksummed
- Every vault has `name` + `description`
- Every vault's `entity` references an existing entity
- Every vault belongs to exactly one product
- All referenced logos exist in `logo/` and are square
- All slugs match `^[a-z0-9-]+$`

---

## Existing Submissions

| Partner | Chain | PR | Product Slug |
|---|---|---|---|
| Origin stETH ARM | 1 (Ethereum) | [#521](https://github.com/euler-xyz/euler-labels/pull/521) | `origin-arm-weth` |

---

## PR Template

```
## Summary

- Adds X new vaults to `<chainId>/vaults.json`
- Adds `<product-slug>` product to `<chainId>/products.json`
- Adds `logo/<filename>` product logo

## Contracts

| Contract | Address |
|---|---|
| <Vault Name> | `0x...` |

## Context

<Brief description of what the market does>
```
