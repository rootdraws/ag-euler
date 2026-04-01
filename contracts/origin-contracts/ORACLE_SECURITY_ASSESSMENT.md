# Security Assessment: ARM convertToAssets Oracle on Euler V2

**Date:** 2026-03-27
**Scope:** Can `convertToAssets()` on LidoARM (`0x85B78AcA6Deae198fBF201c82DAF6Ca21942acc6`) be profitably manipulated when used as Euler V2 collateral pricing via `EulerRouter.govSetResolvedVault`?
**Contracts reviewed:** `AbstractARM.sol`, `LidoARM.sol`, `CapManager.sol` from [origin-protocol/arm-oeth](https://github.com/OriginProtocol/arm-oeth)
**Oracle config:** EulerRouter (`0xd4Dc83f8041B9B9BcE50850edc99B90830bCa3C3`) resolves Collateral Vault → ARM token → WETH via recursive `convertToAssets`
**Risk parameters:** 90% borrow LTV, 93% liquidation LTV

---

## The Concern

The ARM oracle derives its exchange rate from:

```solidity
function convertToAssets(uint256 shares) public view returns (uint256 assets) {
    assets = (shares * totalAssets()) / totalSupply();
}
```

Where `totalAssets()` ultimately reads `IERC20(liquidityAsset).balanceOf(address(this))` — a raw balance check, not internal accounting. Anyone can send WETH directly to the ARM contract and inflate `totalAssets()` without increasing `totalSupply()`, thereby inflating the `convertToAssets` exchange rate.

The question: can an attacker exploit this to steal from Euler lenders?

---

## Finding 1: Flash Loan + Donation — IMPOSSIBLE

**Attack:** Flash-borrow WETH → donate to ARM → borrow from Euler at inflated rate → repay flash loan with profit.

**Proof it fails:**

Let the attacker deposit `C` ARM shares (out of `S` total) into Euler as collateral. ARM total assets = `A`. Attacker flash-loans `D` WETH and donates to ARM.

- Extra Euler borrow capacity = `C × D / S × LTV`
- Flash loan repayment required = `D`

For profit: `C/S × LTV ≥ 1`

Since `C/S ≤ 1` and `LTV = 0.90`:

**Maximum value of `C/S × LTV` is `0.90`, which is always < 1.**

The extra borrow capacity is always less than the donation. The flash loan cannot be repaid. This holds regardless of how many ARM shares the attacker owns.

**Verdict: Not viable.**

---

## Finding 2: Multi-Transaction Donation + Default — ALWAYS UNPROFITABLE

**Attack:** Attacker accumulates ARM shares, deposits into Euler, donates WETH from own funds, borrows max, defaults on the Euler loan.

**Proof it fails:**

Attacker owns fraction `f` of ARM supply. They deposit all shares as Euler collateral and donate `D` WETH.

Scenario A — attacker defaults, walks away with borrowed WETH:
- Borrowed WETH: `f × (A + D) × LTV`
- Cost (ARM shares + donation): `f × A + D`
- Profit: `f×A×LTV + f×D×LTV − f×A − D = f×A×(LTV−1) + D×(f×LTV−1)`

Both terms are negative for any `f < 1/LTV = 1.11`. Since `f ≤ 1`, **profit is always negative**.

Scenario B — attacker keeps Euler position healthy, redeems non-collateral ARM shares:
- Total wealth after = `f × (A + D)` (Euler equity + redeemed shares + borrowed WETH all net out)
- Total cost = `f × A + D`
- Profit = `f×D − D = D×(f − 1)`

For any `f < 1`, **profit is always negative**. The attacker permanently loses `(1−f)×D` to other ARM holders.

The donation benefits ALL shareholders proportionally. The attacker can never recapture more than their ownership fraction `f` of the donation. Since `f < 1`, the donation is a guaranteed net loss.

**Verdict: Not viable at any ownership percentage.**

---

## Finding 3: Deflation Attack (Oracle Manipulation Downward) — NOT POSSIBLE

**Attack:** Reduce `totalAssets()` to push existing borrowers into liquidation.

`totalAssets()` depends on:
1. `IERC20(WETH).balanceOf(ARM)` — WETH sitting in the contract
2. `_externalWithdrawQueue()` — stETH in Lido's withdrawal queue (storage variable, operator-only)
3. `IERC20(stETH).balanceOf(ARM) × crossPrice` — stETH in the contract, valued at cross price
4. `activeMarket.previewRedeem(shares)` — assets in a lending market (if configured)

Can a non-privileged user reduce any of these within a single transaction?

**WETH balance** — Only decreases via:
- ARM swaps (selling stETH → WETH): ARM receives stETH valued at `crossPrice`, sends WETH. Since `traderate1 < crossPrice` is enforced by `setPrices()`, the WETH paid out is less than the `crossPrice`-valued stETH received. Net change to `totalAssets`: **positive** (increases, not decreases).
- ARM swaps (selling WETH → stETH): ARM receives WETH, sends stETH. Since `sellT1 ≥ crossPrice` is enforced, the stETH removed is valued at ≤ the WETH received. Net change: **non-negative**.
- Withdrawal claims (`claimRedeem`): requires prior `requestRedeem` which burns shares proportionally, and has 10-min delay. Cannot be used within a single-tx attack.

**Lido queue amount** — Only changes via `requestLidoWithdrawals` (operator-only) and `claimLidoWithdrawals` (validated against stored request amounts).

**crossPrice** — Owner-only. Capped between `PRICE_SCALE - MAX_CROSS_PRICE_DEVIATION` (99.8%) and `PRICE_SCALE` (100%).

**Active market** — Operator/owner-only to change. `previewRedeem` depends on the external market's implementation.

**Verdict: A non-privileged attacker cannot decrease `totalAssets()` in a single transaction.** The swap price invariants (`traderate1 < crossPrice ≤ sellT1`) guarantee that all swap paths maintain or increase total assets.

---

## Finding 4: Read-Only Reentrancy — NOT APPLICABLE

For read-only reentrancy to work, the Euler oracle would need to be called during an ARM state transition where `totalAssets()` and `totalSupply()` are temporarily inconsistent.

The relevant ARM function is `_deposit()`:
```
shares = convertToShares(assets);                              // reads state
lastAvailableAssets += ...;                                    // updates storage
IERC20(liquidityAsset).transferFrom(msg.sender, ..., assets);  // external call ←
_mint(receiver, shares);                                       // updates totalSupply
```

After `transferFrom` (WETH balance increased) but before `_mint` (shares not yet increased), `convertToAssets` would return an inflated rate. However:

1. **WETH (`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`) is a standard ERC-20 with no transfer callbacks.** There is no hook during `transferFrom` where an attacker could trigger an Euler operation.
2. **stETH** also has no `transferFrom` callback hooks.
3. Even with a hypothetical callback, the attacker would need to trigger an Euler vault operation (borrow/liquidation) from within the token transfer — which requires a very specific, unlikely setup.

**Verdict: Not applicable.** WETH and stETH do not support transfer callbacks.

---

## Finding 5: Active Lending Market Dependency

ARM's `totalAssets()` includes `IERC4626(activeMarket).previewRedeem(shares)` when an active market is configured. If the active market's `previewRedeem` is itself manipulable, that manipulation would propagate through to the ARM oracle.

This is a **transitive trust dependency** — the ARM oracle is only as safe as whatever lending market Origin configures as their active market.

Currently, the LidoARM on mainnet uses Morpho as its active market (if any). This is a governance assumption: Origin's multisig chooses which markets to deploy into.

**Verdict: Acceptable governance risk.** This is standard for DeFi composability. If Origin deploys ARM funds into a manipulable market, that's a governance failure, not an oracle design flaw. Euler can mitigate by monitoring the ARM's `activeMarket` setting.

---

## Finding 6: Rounding — SAFE DIRECTION

```solidity
// convertToAssets rounds DOWN (Solidity truncation)
assets = (shares * totalAssets()) / totalSupply();
```

Rounding down means the oracle slightly undervalues collateral. This is the **conservative direction** for a lending protocol — lenders are protected, borrowers get slightly less than the true value.

The dead shares (`MIN_TOTAL_SUPPLY = 1e12`) ensure denominators are always large enough that rounding errors are negligible (< 1 wei per share at any reasonable scale).

**Verdict: Safe.** Rounding favors lenders.

---

## Finding 7: Governance / Trust Assumptions

These are not oracle manipulation vectors, but residual risks that Euler should be aware of:

| Risk | Actor | Impact |
|---|---|---|
| `crossPrice` lowered while stETH is held | ARM owner | Can reduce `totalAssets` by up to 0.2% (MAX_CROSS_PRICE_DEVIATION). Enforced minimum: 99.8%. Low impact. |
| `activeMarket` changed to malicious market | ARM owner/operator | `previewRedeem` returns inflated value → inflated `totalAssets`. Requires compromised Origin multisig. |
| Fee collector drains liquidity | ARM owner | `collectFees` can extract accumulated performance fees, reducing WETH balance. But fees are accounted for — `totalAssets()` already subtracts accrued fees. No oracle impact. |
| Trade rates set to extreme values | ARM operator | Does not affect `totalAssets()` directly. Affects swap volumes but not oracle. |

---

## Summary

| Vector | Viable? | Proof |
|---|---|---|
| Flash loan + donation | **No** | `f × LTV < 1` always. Can't repay flash loan. |
| Multi-tx donation + default | **No** | Profit = `D×(f−1)`, negative for all `f < 1`. |
| Deflation (oracle down) | **No** | Swap invariants guarantee `totalAssets` non-decreasing. No single-tx extraction path. |
| Read-only reentrancy | **No** | WETH/stETH have no transfer callbacks. |
| Rounding exploitation | **No** | Rounds down (conservative for lenders). Dead shares prevent precision loss. |
| Active market manipulation | Governance risk | Requires compromised Origin multisig. Standard composability trust assumption. |

**Assessment: The ARM `convertToAssets` oracle is safe for use as Euler V2 collateral pricing.**

The `balanceOf`-based calculation that Kasper flagged is a valid general concern, but in this specific case the ARM's properties prevent exploitation:
- Donations are permanent (no instant redeem — 10-min delay)
- The math proves donation attacks are unprofitable at ANY ownership fraction below 100%
- No path exists for non-privileged users to deflate `totalAssets` within a single transaction
- Swap price invariants (`traderate1 < crossPrice ≤ sellT1`) maintain the monotonically increasing property through all swap operations

The remaining risks are standard DeFi governance assumptions (Origin multisig behavior) and transitive trust in Origin's active lending market choice, which are acceptable and common across all collateral types.
