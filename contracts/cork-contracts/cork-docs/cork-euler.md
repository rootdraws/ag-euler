### **Objective**

Enable a *fully Euler-native Protected Loop*—a leveraged looping trade using an illiquid Reference Asset (REF) as collateral—without relying on a Cork “Looping Vault.” All leverage, collateralization, borrowing, liquidation, and rollover behavior is implemented via:

- A **dedicated Euler market with REF, cST, and USDC vaults**
- A **Cork-aware liquidation path**
- **Hooks** enforcing cST/REF pairing and rollover validity
- **Oracles** that allow high LLTV by treating REF as effectively backed by CA (the Cork Pool collateral asset)

This design fully preserves the Protected Loops behavior from the original spec while using Euler’s risk engine, hooks, and liquidation framework.

---

# **1. System Overview**

## **Assets in the Euler Market (Cluster)**

### 1. **REF Vault (Reference Asset; e.g., BIGEY RWA token or wrapped wRWA)**

- Collateral-only.
- All collateral value is driven by **REFEffectiveOracle** (based on CA unwind value through Cork).
- Used with cST to perform protected looping.

### 2. **cST Vault (Cork Swap Token for a given series)**

- Collateral-only.
- **Oracle value in Euler = 0**.
- Acts as a **control token**—its presence is required to borrow and to allow liquidation to succeed.
- Must always match REF quantities on accounts with debt.
- Cannot be withdrawn while debt exists.
- Must belong to a valid, non-expired Cork Pool series.

### 3. **USDC Vault**

- Borrowable asset for looping.
- Collateral optional.

The Euler market therefore sees a position like:

```
Collateral: REF + (zero-value cST)
Debt: USDC

```

but **liquidations succeed because seized REF + cST can be exercised into CA in Cork**.

---

# **2. Risk Model & Oracle Design**

**Relevant Quote from Euler’s Team:**

> 
> 
> 
> The **fundamental issue is that when oracles are called, they only receive the amount of token to price**, crucially - they don't know which account they price. So even if we ensured cST balance is in sync with REF, during rollovers there would be no way to reprice REF for the account.
> 
> If the oracle did know what account it's pricing though, then everything becomes much more simple. There's no need to enforce a sync between REF and cSTs, the oracle would just look at the account, figure out how much non-expired cST it has and how much REF is covered and just provide a collateral value number.
> 
> So the only challange is to pass the account to the oracle. We can overload the token amount and encode the account into return of balanceOf on a custom collateral, if called by a designated controller (borrow vault which is pricing the collateral)
> 
> https://github.com/euler-xyz/evk-periphery/blob/cork-poc/src/Vault/deployed/ERC4626EVCCollateralCork.sol
> 
> So to asses if the account is healthy, the borrow vault will price the debt in USDC, for cSTs will see 0 value, and for REF it will call to the custom vault and receive a balance, which is the encoded account. This balance will then be passed to the custom oracle:
> 
> https://github.com/euler-xyz/euler-price-oracle/blob/cork-poc/src/adapter/cork/CorkCustomRiskManagerOracle.sol
> 

## **2.1 cST Oracle**

- Always returns **0**.
- cST contributes **no collateral value** to Euler’s health factor.
- Instead, it is a *key* for the liquidation value mentioned below: REF + cST unlocks CA at exercise.

## **2.2 REF Effective Oracle (REFEffectiveOracle)**

Euler should not use pure NAV or market price of REF.

Instead, REF is effectively worth:

```
min( NAV(REF), CA_price * (1 - max_discount) * H_pool )

```

Where:

- **CA_price** is the price of Collateral Asset (e.g., sUSDS or USYC).
- **max_discount** is the maximum swap/exercise discount specified by the Cork Pool (e.g., 0.5%).
- **H_pool** is a Cork impairment factor:
    - Reflects CA liquidity, peg risk, pool composition, repurchase availability, etc.
    - Acts as an anti-bad-debt safeguard.

This gives Euler a **stable-backed effective collateral value**, enabling:

- LLTV ≈ 85–92% (pilot example: 91.17% LLTV for Bigey)
- Meaningfully lower borrow REFtes than lending directly against an illiquid RWA

**Implementation Guidance from Euler’s Team:**

> 
> 
> 
> https://github.com/euler-xyz/euler-price-oracle/blob/cork-poc/src/adapter/cork/CorkCustomRiskManagerOracle.sol
> 
> The oracle decodes the account, fetches all the enabled collaterals from EVC and iterates over them to determine how much valid cST an account has and how it relates to the REF balance. In essence the logic can be arbitrary and can decide if the account should be healthy or not (It could also fetch the debt from EVC).
> 
> Just an encoded address would be passed, then the oracle can fetch the collateral balances on its own. The list of collaterals as well as the debt vault can be fetched from EVC just by having the account address
> 
> Overloading balanceOf is a bit hacky, and in hindsight, we should have added an account to the oracle invocation, but the whole architecture is sound imo, and implementation should be quite easy.
> 
> The idea can be extended as well if REF should be rehypothecated in a borrowable vault.
> 

## **2.3 Expiry-Aware Rollover Oracle Behavior**

If a cST series is approaching expiry:

- **cST has some effect on collateral**, as its expiry would reduce collateral value.
- The **REF oracle should reduce H_pool → 0** if there is *no valid rollover* to a successor cST series shortly before expiry (e.g., 1h).
- This forces the health factor to fall and triggers liquidation *unless rollover occurs*.
    - An operator could step in to liquidate any positions that are above the threshold.

To avoid operator error (see automation section), we recommend:

- H_pool transitions out only if **no successor cST is present in the account’s collateral**.

**Implementation Guidance from Euler’s Team:**

> 
> 
> 
> Darek | Euler, [5 Feb 2026 at 4:45:22 PM]:
> In the POC the oracle makes no distinction if borrow or liquidation ltvs should be concerned, but it is possible in general, because the vault will call getQuotes (plural) for calculating borrow LTV and getQuote (singular) for the liquidation. The POC would just need to override those 2 public functions instead of the internal one.
> 
> But I don't think it would be required in this case. The borrow / liquidation LTV distinction is applied in the vault logic already and I don't think there's a need to modify this behavior
> 

---

# **3. Hook Logic (ProtectedLoopHook)**

Attached to REF Vault, cST Vault, and USDC Vault.

## **3.1 Borrow Gating**

Before any borrow of USDC:

- Require: `REF_balance > 0`, `cST_balance > 0`
- Require matching: REF`_balance == cST_balance` (units or normalized)
- Require cST series is valid and not expired
- Require rollover conditions met during the rollover window (e.g., a valid new cST exists)

If any fail → revert borrow.

## **3.2 Withdrawal Restrictions**

When USDC debt exists:

- **cST withdrawals forbidden**
- **REF withdrawals forbidden**, except as part of a liquidation or authorized rollover batch

Without debt:

- Both REF and cST may be withdrawn, but must not break pairing.

## **3.3 Rollover Exception Path**

If the call originates from the **RolloverOperator**:

- Temporarily allow REF/cST movements
- But enforce after the batch ends:
    - `REF_balance == cST_new_balance`
    - cST is from the **new**, valid series

---

# **4. Liquidation Architecture**

## **4.1 Core Requirement**

Liquidators must be able to unwind **REF + cST → CA → USDC** *atomically*, without warehousing the RWA.

**Implementation Guidance from Euler’s Team:**

> Darek | Euler, [5 Feb 2026 at 4:52:22 PM]:
For liquidations, the bots will need special casing. They need to call the liquidate function 2 times, for both REF and cST (or more if multiple expiry cSTs are present), then redeem to CA and then swap for debt as usual. All the above can happen in a single batch. Overall it's a REFther small lift to implement in our bot
> 

## **4.2 Liquidation Flow via CorkProtectedLoopLiquidator**

When REF-based position breaches LLTV:

1. Liquidator calls `liquidate()`
2. Inside an EVC batch:
    - Repay USDC debt (from balance or flash liquidity)
    - Seize REF + cST from the account
3. Call Cork Pool:
    - Exercise REF + cST → CA
4. Convert CA → USDC
5. Repay flash and keep profit

This mirrors the “Looping Vault acts as liquidator” flow from the spec—but now executed by an Euler-integrated liquidator contract.

## **4.3 Important Requirement**

Euler must configure this market so that REF and cST are both seizable in liquidation.

---

# **5. Rollover Support (cST_old → cST_new)**

**Relevant Quote from Euler’s Team:**

> My initial thoughts - if this rollover happens automatically, by essentially cST1 being swapped for cST2 with some fee paid, then maybe the simplest thing to do is to develop a wrapper token, `RollingCST` if you will. Users would simply buy the wrapper which would decrease in price over time (fees) and deposit it into a regular Euler vault.
> 

**Relevant Quote from Cork’s Team:**

> We really liked this original idea (i.e. RollingCST token) as REF could be rehypothecated in a borrowable vault.
We do, however, need some design guidance on whether a “pre-liquidation” extension or hook would be viable within the Euler architecture — specifically, whether it would allow a risk curator or bot to utilize a portion of the user's REF collateral in the borrowable vault (or any other token deposited by the user) to fund the cover extension premium prior to any actual liquidation (or the account becoming unhealthy because of expiry).
> 

### Guided by Cork’s rollover flow:

1. Euler EVC takes from Euler user account’s collateral stack, and deposits into RolloverVendingManager operated by underwriters, the: 
    - cST_old
    - Premium payment for next cST
2. RolloverVendingManager unwinds old cPT + cST → CA
3. CA deposited into new Cork Pool → cST_new + cPT_new minted
4. Euler EVC receives cST_new; underwriters receive cPT_new + premium

### In Euler:

- **Only cST series** and the Cork Reference asset is accepted as collateral.
- cPT is handled entirely off-market by Cork Underwriters (and strategies); Euler need not track it.

### Rollover Mechanics in Euler:

A **single EVC batch**:

1. Withdraw cST_old (temporarily) from a user’s collateral stack on Euler
    1. ~~Unwrap RollingCST token back into cST_old~~
2. Withdraw REF or any other token (temporarily) from a user’s collateral stack on Euler for the premium payment
3. Sends user’s payment token and cST_old to a **RolloverVendingManager** operated by underwriters
4.  **RolloverVendingManager** (or Module) operated by underwriters:
    - obtain **cPT_old** using an arbitrary internal mechanism/strategy, such as:
        - burning shares to return deployed **cPT_old** from other protocols/markets selected by the underwriter (or underwriter’s risk curator).
    - unwinds old pair (cPT_old + cST_old) → CA
    - mints cPT_new + cST_new
    - reallocates and redeploys **cPT_new** into underwriter’s choice of protocol and market
5. ~~Mints RollingCST: Deposit cST_new into RollingCST address~~
6. End-of-batch hook check ensures:
    - Valid new series
    - REF and cST_new remain 1:1

---

# **6. Components To Be Built**

## **6.1 To Be Built on Cork**

### 1. **Cork Series Registry**

- Metadata for each cST series:
    
    `expiry`, `liq_window`, `max_discount`, `CA token`, `successorSeries`, etc.
    
- Functions:
    - `isValidSeries(token, timestamp)`
    - `getSeriesParams(token)`

### 2. **Cork Pool Enhancements**

- Exercise: `exercise(RA, cST) → CA`
- Create new position: `mintNewSeries(CA, premium) → cST_new + cPT_new`

### 3.  **Vault With RolloverVendingUserLib &  RolloverVendingManager Architecture**

The rollover mechanism uses two coordinating contracts:

### **RolloverVendingManager (Cork Periphery Contract)**

- Maintains a list of **preapproved/**timelocked standing orders or instructions signed by each LP.
- **LP Controls:**
    - LPs may cancel any pending order/instruction at any time prior to execution.
    - LPs may opt out by revoking the cPT allowance granted to the  **RolloverVendingManager** contract.
- **Execution Model:**
    - Once a timelock expires, **any caller** may execute the standing orders/instructions queued, as long as they can supply the corresponding cST required for execution.
    - Standing instruction include:
        - Unwinding the pre-approved cPT of each LP, using the cST supplied by caller.
        - Redepositing the resulting CA from the unwind into a longer-dated market, which mints the next-edition Cork tokens.
        - Transferring next-edition-cPT minted (of the subsequent market) into the LP's wallet
        - Returning next-edition-cST minted (of the subsequent market) to the caller as part of settlement

### **Vault with RolloverVendingUserLib Contract (Euler-side)**

- Rollover automatically triggered by keepers operated by Euler Risk Curators as expiry approaches.
- **Execution Flow (atomic multicall):**
    1. The Euler contract—holding a balance of Cork cST—gives full cST allowance to Cork's **RolloverVendingManager** contract.
    2. Triggers the **RolloverVendingManager** to execute its standing instructions (mentioned above).
    3. Ensure that balance of next-edition cST (of the subsequent market) held by the EVC/vault after settlement is sufficient to cover collateral, otherwise put an account into an unhealthy state that allows liquidators to exercise any remaining current-edition cST tokens (before they expire).

### 

### 4. **Automation Layer (Optional but recommended)**

- Off-chain keepers + `RolloverOperator`
- Should auto-roll before `liq_window`
- Should check successor series availability
- Should manage multiple accounts in parallel

### 5. **UI / UX Automation (Recommended)**

- “Auto-roll enabled” toggle
- Estimated rollover cost & next expiry timeline
- Warnings when near expiry if automation disabled

---

## **6.2 To Be Built on Euler**

### 1. **Vaults**

- REF vault (collateral-only)
- cST vault (collateral-only, zero-valued oracle)
- USDC vault (borrowable)

### 2. **Oracles**

- **REFEffectiveOracle:**
    
    Encodes:
    
    - NAV price
    - CA-backed unwind value
    - Impairment factor H_pool
    - Discount max rules
    - Rollover window constraints
- **cSTOracle:** always returns 0

### 3. **ProtectedLoopHook**

- Enforce REF=cST pairing
- Enforce cST validity
- Block withdrawals during debt
- Allow rollover exceptions
- Block borrowing if no rollover within `liq_window`

### 4. **CorkProtectedLoopLiquidator**

- Executes REF+cST → CA → USDC unwind
- Works inside Euler liquidation module
- Handles flash liquidity operations if needed

### 5. **EVC Operator Plumbing**

- Allow Cork’s RolloverOperator to batch operations
- Provide testing harness for end-of-batch invariant checks

---

# **7. Additional Suggested Automation Enhancements**

### **1. Safety Auto-Deleveraging**

Before price impairment or H_pool reduction:

- Automation can repay a portion of USDC using CA or small RWA unwind
- Avoids involuntary liquidation

### **2. Pre-Liquidation Auction Routing**

If Cork Pool liquidity is low:

- Routing CA → USDC can be split across multiple AMMs automatically
- Ensures slippage-safe liquidation

### **3. Auto-Repurchase for Vault Health**

If swaps have been exercised earlier in the cycle:

- System can acquire discounted REF + cST via repurchase
- Rebuilds the protected loop collateral pair automatically

### **4. Emergency Mode**

If CA depegs:

- EVC operator unwinds REF+cST ahead of liquidation
- Repays debt aggressively
- Minimizes bad debt risk

---

# **8. Updated Interface Skeletons (Aligned With Protected Loops Spec)**

## **8.1 CorkSeriesRegistry**

```solidity
interface ICorkSeriesRegistry {
    struct SeriesParams {
        address refToken;
        address caToken;
        uint64  expiry;
        uint64  liqWindow;
        uint64  maxDiscountBps;
        address successorSeries;
        bool    active;
    }

    function getSeriesParams(address cstToken)
        external
        view
        returns (SeriesParams memory);

    function isValidSeries(address cstToken, uint256 timestamp)
        external
        view
        returns (bool);

    function successor(address cstToken)
        external
        view
        returns (address);
}

```

---

## **8.2 Cork Pool**

```solidity
interface ICorkPool {
    function exercise(
        address refToken,
        address cstToken,
        uint256 REFAmount,
        uint256 cstAmount
    ) external returns (uint256 caOut);

    function repurchase(
        uint256 caAmountIn
    ) external returns (uint256 REFOut, uint256 cstOut);

    function mintNewSeries(
        uint256 caAmountIn,
        uint256 premiumAmount
    ) external returns (uint256 cstNew, uint256 cptNew);
}

```

---

## **8.3  RolloverVendingManager**

```solidity
interface IRolloverVendingManager {
    struct RolloverParams {
        address account;
        address REFToken;
        address cstOld;
        address cstNew;
        address corkPoolOld;
        address corkPoolNew;
        uint256 amount;
        uint256 premiumAmount;
    }

    function rollover(RolloverParams calldata params) external;
}

```

---

## **8.4 ProtectedLoopHook**

```solidity
interface IProtectedLoopHook {
    function beforeBorrow(
        address vault,
        address account,
        uint256 amount,
        bytes calldata data
    ) external;

    function beforeWithdraw(
        address vault,
        address account,
        uint256 amount,
        bytes calldata data
    ) external;

    function beforeDeposit(
        address vault,
        address account,
        uint256 amount,
        bytes calldata data
    ) external;
}

```

---

## **8.5 Liquidator**

```solidity
interface ICorkProtectedLoopLiquidator {
    struct Params {
        address borrower;
        address REFVault;
        address cstVault;
        address usdcVault;
        address cstToken;
        address corkPool;
        uint256 repayAmount;
        uint256 minProfit;
    }

    function liquidate(Params calldata params) external;
}

```

---

## **8.6 RolloverOperator (optional automation)**

```solidity
interface IRolloverOperator {
    struct Config {
        bool enabled;
        uint64 rollAheadSeconds;
        uint64 maxGasPriceWei;
    }

    function setConfig(Config calldata cfg) external;

    function rolloverIfNeeded(address account) external;
}

```

---

# **Protected Looping Market on Euler – Technical Design (Cork Integration)**

---

### 1. Objective

Implement a dedicated Euler market that enables **leveraged looping** on illiquid RWAs / vault tokens, while:

- Maintaining **high LLTV** (≈ 85–92%) with low borrow REFtes.
- Ensuring **atomic liquidation** via Cork: REF + cST → CA (stable) → USDC.
- Avoiding liquidators warehousing long-duration RWAs.
- Supporting **expiry-based rollovers** of cST series without relying on a separate “looping vault” contract.

All user interaction is through Euler; Cork is used only for hedging/liquidations and rollovers.

---

### 2. Assets and Market Configuration

**Market**: single Euler cluster with three key vaults.

1. **REF Vault (Reference Asset)**
    - Underlying: RWA or wrapped RWA (e.g., BIGEY / wBIGEY).
    - `collateralEnabled = true`, `borrowEnabled = false`.
    - Oracle: REF`EffectiveOracle` (see below).
2. **cST Vault (Cork Swap Token)**
    - Underlying: cST for a given Cork Pool series.
    - `collateralEnabled = true`, `borrowEnabled = false`.
    - Oracle: always returns 0 (no collateral contribution).
    - Purpose:
        - Enforced via hooks: positions with USDC debt must have REF and cST matched 1:1.
        - During liquidation, both REF and cST are seized and exercised in Cork.
3. **USDC Vault**
    - Underlying: USDC.
    - `borrowEnabled = true` (only borrow asset for the loop).
    - Oracle: standard USDC feed.

All leverage is REF–USDC; cST is a control key for liquidation and rollover, not a value-bearing asset in Euler.

---

### 3. Oracle Design

### 3.1 cST Oracle

- Returns 0 always.
- cST balances are **accounted for but never valued** in Euler’s health factor.
- Risk model is purely REF-driven.

### 3.2 REFEffectiveOracle

Instead of using pure NAV or spot price of REF, Euler should consider REF as effectively backed by the Cork Pool’s Collateral Asset (CA, e.g. sUSDS / USYC), with conservative discounts:

Let:

- `P_RA_Nav` – NAV price or fair value of REF.
- `P_CA` – oracle price of CA.
- `maxDiscountBps` – max swap discount + exercise fee (e.g. 50 bps).
- `H_pool` – impairment factor in [0,1] capturing CA liquidity, peg risk, and Cork Pool capacity.

Then:

```
P_RA_effective = min(
    P_RA_Nav,
    P_CA * (1 - maxDiscountBps/10_000) * H_pool
)

```

Euler uses `P_RA_effective` as REF’s collateral price:

- With robust CA and low `maxDiscountBps`, REF behaves almost like a stable-backed position → allows high LLTV.
- As CA degrades (peg, liquidity, pool underfunding), `H_pool` decreases → REFEffectiveOracle pushes collateral value down, forcing deleveraging and preventing bad debt.

**Expiry awareness** (cST series):

- RefEffectiveOracle can also read CorkSeriesRegistry to:
    - Reduce H_pool to 0 if there is no valid successor cST series within a defined liquidation window before expiry, unless the account already holds the successor cST.

---

### 4. Hook Logic (ProtectedLoopHook)

One Hook Target contract is configured on:

- REF vault: `beforeDeposit`, `beforeWithdraw`.
- cST vault: `beforeDeposit`, `beforeWithdraw`.
- USDC vault: `beforeBorrow` (and optionally other points).

Key invariants enforced per account:

1. **Pairing for debt**
    
    If `USDC_debt > 0` or a borrow is attempted:
    
    - `RA_balance > 0` and `cST_balance > 0`.
    - `RA_balance == cST_balance` (units or normalized).
    - cST belongs to a valid Cork series (non-expired, registered).
2. **Withdrawal restrictions**
    
    If `USDC_debt > 0`:
    
    - Reject cST withdrawals outright.
    - Reject REF withdrawals that would:
        - Break REF=cST pairing; or
        - Reduce collateral below what is needed for outstanding debt.
3. **Rollover exception**
    - When called by RolloverOperator (Risk Curator):
        - Allow temporary REF/cST movements within a single EVC batch.
        - At end-of-batch, Euler will enforce:
            - Valid successor cST series.
            - RA_balance == cST_new_balance.
4. **Expiry enforcement (optional in hook)**
    - Block new borrowing if the current cST series is within its liquidation window and the account does not already hold the successor cST.

---

### 5. Liquidation Architecture

Liquidation must unwind REF + cST into CA and then USDC in a single transaction.

**CorkProtectedLoopLiquidator** (Euler-side liquidation module):

1. Called by Euler liquidation system when an account falls below LLTV.
2. Inside an EVC batch:
    - Optionally flash-borrow USDC.
    - Repay victim’s USDC debt.
    - Seize REF and cST collateral from REF vault and cST vault.
3. Call Cork Pool:
    - Exercise REF + cST → CA (sUSDS / USYC).
4. Swap CA → USDC through approved route(s).
5. Repay flash and retain USDC profit.

Market configuration:

- This market’s liquidation path must be wired so that under-water accounts are processed via this Cork-aware liquidator, not the generic default.

---

### 6. Rollover Design

cST tokens are series-based and expire. RWA loops must be hedged by valid, non-expired cST series.

**Overview of Rollover Mechanism**:

1.  **RolloverVendingManager** (underwriter-side) when called, performs:
    - Receives **cST_old** and some premium amount.
    - Unwind underwriter-side custom strategies:
        - return **cPT_old** by unwinding positions or burning share tokens from the underwriter’s choice of protocol or market, or
        - return **cPT_old** sitting idle and unproductive (i.e. not rehypothecated) from the underwriter’s treasury account.
    - **Cork UnwindMint & Mint:**
        - **cST_old** (+ cPT_old) → **CA** → **cST_new** (+ cPT_new).
    - Keeps premium-payment token (i.e. the extension fee) or sends it automatically to:
        - the underwriter’s choice of yield-bearing protocol or market, or
        - the underwriter’s treasury account balance.
    - Deploys **cPT_new** during the rollover (within the same atomic transaction), such as an automatic allocation into:
        - the underwriter’s choice of yield-bearing protocol or market, or
        - the underwriter’s treasury account balance.
    - Sends minted **cST_new** to the recipient (i.e. the Euler EVC).
2. **In Euler**, an EVC batch:
    - Enable **cST_new** as accepted collateral with Euler Risk Curator’s authorization.
    - Withdraw REF (or another premium-payment token) and cST_old from user account’s collateral stack (with or without user’s authorization).
        - ~~If RollingCST withdrawn instead, burns RollingCST to obtain cST_old.~~
        - This is temporary, as it should not affect the ending value of the user’s collateral stack.
    - Call **RolloverVendingManager** operated by underwriter to mint cST_new.
    - Deposit cST_new into Euler vault as collateral of user account.
        - ~~Or alternatively, mint RollingCST, and deposit RollingCST as collateral.~~
    - End-of-batch hooks confirm account healthy (REF == cST_new) and validity of cST_new address.
3. **RolloverOperator** (risk-curator-side):
    - Users explicitly or implicitly delegate the rollover of their Euler account’s collateral stack to this operator.
    - Off-chain keepers monitor time to expiry from `cST.expiry()` function and next cST-edition-address from **CorkSeriesRegistry**.
    - Before expiry window, operator triggers rollovers via EVC batch.

---

### 7. Implementation Checklist (Euler)

1. Create REF, cST, and USDC vaults in a dedicated market.
2. Implement and deploy:
    - `RefEffectiveOracle`
    - `cSTOracle` (zero-value)
3. Implement `ProtectedLoopHook` and attach to REF, cST, and USDC vaults.
4. Implement `CorkProtectedLoopLiquidator` and configure this market’s liquidation path to use it.
5. Ensure EVC supports:
    - Batch operations for rollovers and liquidations.
    - Delegation to an operator (RolloverOperator).

---

# Cork-Facing Technical Brief (Mirror)

This is the same design, but framed as “what Cork needs to provide so Euler can safely treat REF as CA-backed collateral.”

### 1. Objective

Provide Cork-side infrastructure so that:

- Any Euler market using REF and cST as collateral can:
    - Liquidate REF positions **atomically** via Cork pools into CA and then USDC.
    - Rely on **Cork’s series and pool metadata** to compute a conservative REF effective price.
    - Roll cST series forward without manual operator risk.

Cork does **not** manage user leverage directly; Euler does. Cork provides:

- Liquidity hedge,
- Rollover machinery,
- Metadata and oracles,
- Liquidation & repurchase paths.

---

### 2. Required Onchain Components

### 2.1 CorkSeriesRegistry

A registry for cST series metadata, used by Euler oracles, hooks, and liquidators.

For each cST series (each cST token):

- `raToken` – reference asset used with this series.
- `caToken` – collateral asset (e.g. sUSDS / USYC).
- `expiry` – timestamp at which cST expires.
- `liqWindow` – seconds before expiry when positions should be rolled / liquidatable.
- `maxDiscountBps` – worst-case fee + discount for exercising.
- `successorSeries` – cST token for the next series (if configured).
- `active` – series status.

Must expose:

- `getSeriesParams(cstToken)` → `SeriesParams`.
- `isValidSeries(cstToken, timestamp)` → bool.
- `successor(cstToken)` → cST token.

Euler’s REFEffectiveOracle and ProtectedLoopHook will read this.

---

### 2.2 Cork Pool (per REF-CA market)

The existing Cork Pool must support:

- **Exercise path**:
    
    `exercise(raToken, cstToken, REFAmount, cstAmount) → caAmountOut`
    
    Used by liquidator and rollovers.
    
- **Repurchase path**:
    
    `repurchase(caAmountIn) → (raOut, cstOut)`
    
    Used when loop wants to increase notional exposure using pool inventory.
    
- **New series minting path**:
    
    `mintNewSeries(caAmountIn, premium) → (cstNew, cptNew)`
    
    For rollovers: use CA + premium to mint the next cST series and corresponding cPT.
    

Cork must ensure:

- CA is available and can be redeemed (CA → underlying stable).
- Pool accounting is sound under repeated exercise / repurchase cycles.

---

### 2.3  RolloverVendingManager

Coordinating contract allowing for automated cST series rollover:

- Accepts from collateral belonging to Euler accounts:
    - cST_old, and
    - premium amount in any token accepted by underwriter.
- Unwinds strategies (i.e. currently deployed cPT):
    - Make cPT_old flow back from underwriter’s choice of market or protocol, or underwriter’s treasury balance.
- Calls into old Cork Pool to unwind:
    - cPT_old + cST_old → CA.
- Calls new Cork Pool to:
    - Deposit CA → mint cST_new + cPT_new.
- Sends:
    - cST_new to the EVC (risk-curator side) to be returned to the Euler account’s collateral stack
    - cPT_new and premium flows back to underwriter’s choice of market or protocol, or underwriter’s treasury balance.

Exposed function:

```solidity
function rollover(RolloverParams calldata params) external;

```

This function is invoked within an Euler EVC batch.

---

### 2.4 RolloverOperator (Optional Automation)

Operator contract and/or bot operated by an Euler Risk Curator that:

- Maintains per-account configuration:
    - `enabled`, `rollAheadSeconds`, `maxGasPriceWei`.
- Off-chain keepers call:
    - `rolloverIfNeeded(account)`:
        - Reads CorkSeriesRegistry to get expiry & liqWindow.
        - If within `rollAheadSeconds` and successorSeries exists:
            - Invokes `RolloverVendingManager.rollover()` via EVC for that account.

Goal: **avoid liquidations caused solely by lack of rollover**, while leaving economic liquidations (e.g. CA impairment) intact.

---

### 2.5 RWA Wrapper

Standard whitelisting wrapper, as in your spec:

- `RWA → wRWA` (for lender-facing token).
- Curator / vault has wrapping permission.
- No whitelist for unwrapping (`wRWA → RWA`) so any liquidator can unwind on-chain.

Cork must ensure:

- RWA wrapper works smoothly with:
    - Cork Pool (if Pool holds RWA vs wRWA).
    - Euler REF vault (which might use wRWA as the REF).

---

### 3. Off-Chain Support

To make Euler integration work well, Cork should provide:

- Reference implementation for:
    - RefEffectiveOracle logic (solidity + math).
    - ProtectedLoopHook’s view into CorkSeriesRegistry.
    - CorkProtectedLoopLiquidator’s Cork Pool interactions.
- Indexing / analytics:
    - Expose H_pool and series risk metrics via subgraphs / APIs so Euler governance/risk teams can calibrate collateral factors.
- Documentation:
    - RWA partners (like Bigey) and curators can understand the full unwind path and rollover obligations.

---

##