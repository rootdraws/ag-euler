# AG-Euler — TODO

Consolidated task tracker across all partner deployments and repo-wide work.

---

## Falcon Markets — Transition or Wind Down — TOP PRIORITY

**Status: NOW.** The existing Falcon markets need a path forward. Two options, either is acceptable but a decision is needed:

1. **Hand off** — find a curator/operator willing to accept the Falcon markets and assume the position
2. **Wind down** — set Falcon collateral LTVs to 0, liquidate open positions, repurpose the now-empty USDC capacity for a new strategy on Mainnet

- [ ] **Survey potential acceptors** — who would take over Falcon markets (Cork, Midas, Renzo, Mellow, an existing curator)?
- [ ] **If no acceptor: kill plan** — `setLTV(0,0,0)` on Falcon collaterals, drive positions to liquidation, confirm zero open debt before unwinding
- [ ] **Reuse the USDC slot** — once Falcon is off the books, design a replacement USDC-borrow strategy for that capacity (mAPOLLO PT, Midas RWA, USDM1, etc.)
- [ ] **Comms** — notify any Falcon supply LPs of the wind-down or curator change before action

---

## Base USDC Market — Repurpose for Alpha Structures — TOP PRIORITY

**Status: NOW.** AG's USDC market on Base currently pairs against reUSD (~8% yield, ~414k USDC available). Plan: remove reUSD as collateral and redirect that USDC capacity into Alpha Structures on Base (Majors basket and/or Long Tail basket).

- [ ] **Remove reUSD as collateral** — `setLTV(0,0,0)` on the reUSD collateral, force-close or migrate any open positions, then `setCaps(0,0)` on the reUSD collateral vault
- [ ] **Confirm USDC capacity post-migration** — verify ~414k USDC is free + healthy after reUSD is gone
- [ ] **Route capacity into Alpha Structures Base** — wire USDC borrow side to the Majors (ETH/BTC/AERO) and/or Long Tail (VVV/VIRTUAL/ZRO) markets once those land
- [ ] **Comms** — notify any reUSD suppliers/borrowers before LTV changes hit

---

## mAPOLLO — Pendle PT on Euler Mainnet — TOP PRIORITY

**Status: NOW.** Midas has $1.3M in instant USDC liquidity on mainnet for mAPOLLO. Add the Pendle PT for mAPOLLO as collateral on the Euler mainnet market — instant USDC liquidity means we can run aggressive collateral factors with a custom liquidator if needed. Pair the launch with co-incentivization from Euler and Midas, plus an Apollo podcast for distribution.

- [ ] **Add PT-mAPOLLO to Euler mainnet market** — wire oracle (Pendle PT pricing), set LTV, caps, IRM
- [ ] **Appeal to Euler for incentives co-matching** — pitch them on co-funding rewards for this market
- [ ] **Ask Midas for co-incentivization matching** — Midas matches AG/Euler rewards
- [ ] **Book podcast with Apollo** — co-marketing for launch
- [ ] **(Optional) Custom liquidator** — if we want collateral factors above what the $1.3M instant liquidity supports natively

---

## Morph Chain — BGB Long/Short Markets

**Status: WAITING.** Morph (L2 chain) wants BGB long and short markets deployed. Two open threads: (a) Morph needs to compensate AG for the build, (b) waiting on Morph to migrate bgBTC.

- [ ] **Confirm compensation with Morph** — terms + scope before build kicks off
- [ ] **bgBTC migration** — track Morph's timeline; markets can't ship until this lands
- [ ] **Design BGB long/short markets** — collateral, borrow side, oracle, IRM, caps
- [ ] **Check Euler V2 deployment status on Morph** — confirm core contracts (EVC, EVK factory, oracle adapters) are available

---

## Virtuals — Base (Chain 8453) — GTM PITCH

**Status: NEEDS FULL GTM PROPOSAL.** Virtuals wants a complete GTM proposal / pitch from AG before they move forward. Structured product around Virtuals LP — agent token positions, looping, hedging. Plugs into `alpha-structures/` framework.

- [ ] **Draft full GTM proposal / pitch deck** — supply story, borrower story, leveraged-position thesis, fee/incentive split, timeline
- [ ] **Research Virtuals LP structure on Base** — token addresses, ERC-4626 compatibility, oracle options
- [ ] **Design market** — collateral, borrow asset, IRM curve, caps
- [ ] **Schedule pitch with Virtuals team** — present the proposal, get sign-off on direction

### Cannibalize yoBTC — Short-BTC Carry via Virtuals

The yoBTC market on Base has ~136k cbBTC sitting in broken markets. Capture that liquidity by adding cbBTC into the Virtuals market and building a **short-BTC carry trade** denominated in the Virtuals token (long Virtuals, short BTC, harvest the funding/yield differential).

- [ ] **Confirm cbBTC supply parked in yoBTC** — verify ~136k cbBTC and migration path
- [ ] **Add cbBTC as collateral in the Virtuals market** — adapter + oracle (Chainlink cbBTC/USD on Base) + cluster wiring
- [ ] **Design short-BTC carry strategy** — long Virtuals collateral, borrow cbBTC (or short via Hyperliquid hedge), package as a one-click position
- [ ] **Pitch to yoBTC depositors** — migration messaging: stuck in broken yoBTC → productive carry position in Virtuals/cbBTC

---

## yoUSD — Base Euler — June Incentives Campaign

**Status: WAITING.** Yield Optimizer's yoUSD is live on Base Euler markets. They want to run a joint incentives campaign with AG in **June 2026**.

- [ ] **Confirm yoUSD market on Base Euler** — vault address, current supply/borrow, IRM, oracle
- [ ] **Scope June campaign with Yield Optimizer** — budget split, target metrics (TVL / utilization), duration, asset pairs
- [ ] **Wire incentives plumbing** — Merkl distribution, dashboards, eligibility rules
- [ ] **Co-marketing plan** — coordinated posts, threads, partner crosspost on launch day

---

## Midas / 0g — Morpho on 0g — TOP PRIORITY

**Status: BLOCKED ON ORACLE INFO + expanding scope.** Morpho deployment on 0g (not Euler) — tracked here since AG manages it. mRocks and mRe7 as collateral on Morpho markets via Oku frontend. Expanding to include borrowing against 0g-native collateral and a Mellow-backed liquidation vault structure.

**Repo:** https://github.com/rootdraws/0g-alphagrowth (includes frontend)
**Frontend:** https://0g.alphagrowth.markets/

### What Needs to Happen

1. Deploy mRocks and mRe7 as collateral to Morpho markets on 0g
2. Register the collateral with the MetaMorpho vault
3. Set fees
4. Test the frontend
5. Add 0g-collateral borrow markets
6. Stand up Mellow liquidation vault structure

### Blockers & Next Steps

- [ ] **Requested oracle info from Midas** — need oracle and contract details for mRocks and mRe7
- [ ] **Deploy collateral** — once oracle info received
- [ ] **Register collateral with MetaMorpho vault** — part of the Morpho deployment process
- [ ] **Set fees** — configure curator fees on the vault
- [ ] **Test frontend** — verify 0g.alphagrowth.markets works end-to-end
- [ ] **Ask Merkl about 0g coverage** — need to confirm Merkl supports 0g chain for incentives

### Borrowing Against 0g Collateral

0g wants markets where their native assets serve as collateral. Spec the borrow side (stablecoin? ETH-correlated?), oracle path, and IRM curve.

- [ ] **Define 0g-collateral borrow markets** — which 0g assets, what borrowable counterpart, expected demand
- [ ] **Oracle path** — what feeds exist on 0g, fallback if Chainlink/Pyth absent
- [ ] **Market design** — LTV, IRM curve, caps for each pair

### Mellow Liquidation Vault Structure

Mellow-backed vault providing liquidation liquidity for the 0g markets — analogous to the InfiniFi Credit Pool pattern but tailored to Mellow's stack.

- [ ] **Spec the Mellow vault structure** — collateral, accepted-on-liquidation assets, settlement flow
- [ ] **Engage Mellow** — confirm willingness to back, agree on parameters
- [ ] **Integrate liquidation routing** — Morpho liquidations seize collateral → routed to Mellow vault for unwinding
- [ ] **Incentivization** — supply-side bribes / curator fees to keep Mellow capacity full

---

## Redstone <> Symbiotic — Duration Swap Infrastructure

**Status: WAITING.** Redstone (with Symbiotic) is building liquidation and duration-swap infrastructure. Two deployment targets:

### 0g

Use Redstone <> Symbiotic duration-swap infra alongside the Mellow liquidation vault on 0g (see the 0g/Midas section above). Lets locked/duration-mismatched 0g collateral be liquidated without forced unwinds.

- [ ] **Track Redstone build progress** — confirm 0g chain support
- [ ] **Integrate with 0g Morpho markets** — liquidation routing path through duration-swap infra

### Mainnet ETH — Renzo Liquidation Vault

On Mainnet ETH, the duration-swap infra needs a supply source for the liquidation vault. Renzo is the lead candidate.

- [ ] **Talk to Renzo** — pitch them on supplying capital to the Mainnet ETH liquidation vault
- [ ] **Spec the Mainnet ETH liquidation vault** — accepted collateral on liquidation, settlement path, fee/rebate to Renzo
- [ ] **Confirm Redstone Mainnet support** — duration-swap infra readiness on ETH

---

## USDM1 / USDC — Morpho via Oku

**Status: BLOCKED.** USDM1 wants a Morpho market (USDM1 <> USDC) fronted by Oku. Part of the supply mechanism for looping lower-yield RWAs / tokenized treasury bills.

- [ ] **Spec USDM1 / USDC Morpho market** — LLTV, oracle path, IRM curve, supply caps
- [ ] **Confirm USDM1 token + oracle** — Chainlink/internal feed, staleness window
- [ ] **Coordinate with Oku** — frontend integration, MetaMorpho vault registration

---

## Balancer — Monad (Chain 143)

**Status: LIVE.** Contracts deployed and verified on MonadScan. Labels in `frontends/labels/alphagrowth/143/`. Frontend custom code (BPT adapter/Enso multiply, loop-zap) in `frontends/alphagrowth/`. Lending, borrowing, multiply (Pools 1, 2, 4), Zap BPT, and repay all functional.

### Deployed Addresses

| Contract | Address |
|---|---|
| KinkIRM | `0x2CB88c8E5558380077056ECb9DDbe1e00fdbC402` |
| EulerRouter | `0x77C3b512d1d9E1f22EeCde73F645Da14f49CeC73` |
| AUSD Borrow Vault | `0x438cedcE647491B1d93a73d491eC19A50194c222` |
| WMON Borrow Vault | `0x75B6C392f778B8BCf9bdB676f8F128b4dD49aC19` |
| Pool1 Vault (wnAUSD/wnUSDC/wnUSDT0) | `0x5795130BFb9232C7500C6E57A96Fdd18bFA60436` |
| Pool2 Vault (sMON/wnWMON) | `0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5` |
| Pool3 Vault (shMON/wnWMON) | `0x6660195421557BC6803e875466F99A764ae49Ed7` |
| Pool4 Vault (wnLOAZND/AZND/wnAUSD) | `0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92` |
| Pool 1 BPT Adapter | `0xC904aAB60824FC8225F6c8843897fFba14c8Bf98` |
| Pool 4 BPT Adapter | `0x8753eCb44370fcd4068Dd5BA1BE5bdd85122c832` |

### New Integrations

- [ ] **Beefy integration** — add Beefy vaults as collateral on Monad cluster
- [ ] **hMON (Fastlane)** — add hMON from Fastlane as collateral/market

### BPT-as-Collateral Campaign — Expansion

Balancer's BPT-as-collateral campaign is starting. AG can extend it by adding more BPT collaterals to the existing cluster and running joint marketing alongside Balancer.

- [ ] **Identify additional BPTs to add as collateral** — survey high-TVL Balancer Monad pools not yet wired, prioritize by liquidity + oracle availability
- [ ] **Deploy + wire new BPT collateral vaults** — adapter + oracle + cluster config + (where needed) `BalancerBptAdapter` deployment
- [ ] **Joint marketing with Balancer** — coordinate launch posts, threads, and any campaign-period incentives

### Negative-Funding-Rate Arb: Short MON HL / Long MON Balancer

Standalone strategy that ties together the Balancer cluster with Fastlane. The trade: short MON on Hyperliquid (collect negative funding), long MON via Balancer BPTs as collateral on the AG Euler market. Use this strategy as the wedge to extend underlying value of Balancer / MON activity and pull Fastlane into the loop.

- [ ] **Spec the arb strategy** — funding-rate threshold, position sizing, hedge mechanics, BPT collateral choice
- [ ] **Connect with Fastlane** — they're the natural partner on the BSC/MON side; line up co-marketing or co-incentivization
- [ ] **Increase independent yield on underlying pools** — pitch Balancer on structured-product overlays for the pools (e.g. covered-call / range-bound yield enhancement) so BPT collateral has higher native yield, making the long leg more attractive
- [ ] **Tooling: package the strategy** — one-click vault or template that retail/structured users can deposit into, rather than asking them to leg in manually

---

## Structures

Structured-product markets — depend on the `alpha-structures/` repo (separate codebase, in progress). Revisit as the structures framework matures.

### Alpha Structures — BSC (Chain 56) — TOP PRIORITY

**Status: NOW.** Long/short structured markets on Binance Smart Chain on top of the existing BNB cluster (`contracts/bnb-contracts/`, USDT + BNB cross-margin). First target market: **asBNB / USDT**.

- [ ] **Deploy asBNB / USDT market** — long/short asBNB against USDT, plug into BNB cluster
- [ ] **Source asBNB oracle** — confirm feed (Chainlink/Pyth/internal) and staleness window
- [ ] **Wire into `alpha-structures/`** — structured-product framework on BSC
- [ ] **Caps + IRM** — sensible defaults for launch sizing

### Alpha Structures — Base Majors (Chain 8453) — TOP

**Status: BLOCKED on BSC.** Base Euler deployment belongs to AlphaGrowth. Majors basket: **ETH | BTC | AERO**. Uses Chainlink CRE feeds. Blocked until Alpha Structures BSC ships — framework lands there first, then ports here.

- [ ] **(Blocker) Ship Alpha Structures BSC** — see asBNB / USDT entry above
- [ ] **Confirm Chainlink CRE feeds on Base** — ETH/USD, BTC/USD, AERO/USD adapters
- [ ] **Design ETH long/short market** — collateral, IRM, caps
- [ ] **Design BTC long/short market** — collateral, IRM, caps
- [ ] **Design AERO long/short market** — collateral, IRM, caps
- [ ] **Port `alpha-structures/` framework to Base** — once BSC is stable

#### AERO Structures — GTM with 40 Acres

40 Acres offered a collaborative structured-product partnership. Use them as the GTM partner for the AERO leg of the Base Majors basket — co-build the AERO long/short structured product and co-market it.

- [ ] **Engage 40 Acres** — confirm scope of collaboration (co-build, co-distribute, fee split)
- [ ] **Co-design AERO structured product** — long/short overlay, vault wrapper, target user, incentive structure
- [ ] **Joint GTM plan** — co-marketing, launch sequencing, shared incentives

### Alpha Structures — Base Long Tail (Chain 8453)

**Status: BLOCKED on BSC.** Base Euler long-tail basket: **VVV | VIRTUAL | ZRO**. Uses Chainlink CRE feeds. The underlying markets already exist as standalone subsections — this entry groups them under the long-tail Structures umbrella so we can pitch / launch them as a basket.

- See `### Venice (VVV) — Base (Chain 8453)` below (includes ZRO nested as cluster collateral)
- See `## Virtuals — Base (Chain 8453) — GTM PITCH` at top of file
- [ ] **(Blocker) Ship Alpha Structures BSC** — framework lands there first
- [ ] **Confirm Chainlink CRE feeds on Base** — VVV/USD, VIRTUAL/USD, ZRO/USD
- [ ] **Long/short overlay for each** — once the framework lands, layer long/short markets on top of the existing collateral markets
- [ ] **Package as a long-tail basket pitch** — one GTM story for VVV + VIRTUAL + ZRO

### Alpha Structures — Unichain

**Status: BLOCKED on BSC.** Unichain Euler deployment belongs to AlphaGrowth. Target use cases: ETH / USDC basis trades and LP-as-collateral experiments. Blocked until Alpha Structures BSC ships — the framework needs to land there first, then port to Unichain.

- [ ] **(Blocker) Ship Alpha Structures BSC** — see asBNB / USDT entry above
- [ ] **Confirm Unichain Euler V2 core deployment** — EVC, EVK factory, oracle adapters available
- [ ] **Design ETH / USDC basis trade market** — collateral, oracle path, IRM, caps
- [ ] **LP-as-collateral experiments** — pick target Unichain DEX LPs to wrap, oracle path
- [ ] **Port `alpha-structures/` framework to Unichain** — once BSC is stable

### Venice (VVV) — Base (Chain 8453)

**Status: LIVE.** Three borrow vaults (VVV, USDC, ETH) deployed on Base with cross-collateral support. All vaults activated, oracles verified, labels pushed, frontend tested locally.

**Contract dir:** `contracts/venice-contracts/`
**Chain:** Base (8453)
**Deployer:** `0x8B59fC48e305AFe0934a897F0CaC6CbD3764F3dd`

#### Deployed Addresses

| Contract | Address |
|---|---|
| KinkIRM | `0x23bBDD9B5c795626A043a52C7984e6F3EE47BBDf` |
| VVV/USD ChainlinkOracle Adapter | `0x52cACC037E8F6f681718E08BafaEe305FB1e5512` |
| EulerRouter | `0x0293B19af06dF6CB00323e1e924AA8995bC1718B` |
| VVV Borrow Vault | `0x4B6509B06f664eb8c8a4e9072655A4C6cafc1D9C` |
| USDC Borrow Vault | `0x21c8c8A56790A2b10370373fAcb94e925fD6a06E` |
| ETH Borrow Vault | `0x68AAD2c78065E2D28d2B46f6A80c5a813461FFf4` |
| USDC Collateral Vault | `0x70abc7848ce268017728aD8E45F979F6F1071403` |
| VVV Collateral Vault | `0xDA8f11258CAC545F2A6f28b13aAca364E08F8599` |
| WETH Collateral Vault | `0xeC0c00e9b0894553c9D63C1Dd930c27a303F953c` |

#### Market Parameters

| | Market 1: Borrow VVV | Market 2: Borrow USDC | Market 3: Borrow ETH |
|---|---|---|---|
| Collateral | USDC, WETH | VVV, WETH | USDC, VVV |
| Borrow LTV | 80% | 80% | 80% |
| Liquidation LTV | 85% | 85% | 85% |
| Max Liq Discount | 5% | 5% | 5% |
| Interest Fee | 10% | 10% | 10% |
| Supply Cap | 200,000 VVV | 1,500,000 USDC | 800 WETH |
| Borrow Cap | 200,000 VVV | 1,500,000 USDC | 800 WETH |

IRM (shared): Base=1%, Kink(80%)=40%, Max=100% APY. Fee receiver: `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C`.

#### Remaining TODOs

- [ ] **Build out `alpha-structures/` repo** — structured-product framework that VVV plugs into
- [ ] **Liquidation testing** — confirm end-to-end for all collateral types
- [ ] **Governor transfer** — transfer borrow vaults + router from deployer EOA to multisig
- [ ] **Official Euler listing** — PR to euler-xyz/euler-labels for app.euler.finance
- [ ] **Production frontend** — coordinate with Michael to deploy to euler.alphagrowth.io
- [ ] **Rotate deployer credentials** — private key was exposed during deployment session

#### ZRO (LayerZero) — Added to Cluster

**Status: DEPLOYED.** ZRO added to the Venice USDC/ETH cluster. ZRO is both borrowable (against USDC + ETH collateral) and usable as collateral (to borrow USDC or ETH). No custom Solidity — uses Euler's `ChainlinkOracle` adapter. Labels pushed.

**Contract dir:** `contracts/zro-contracts/` (scripts) + `contracts/venice-contracts/.env` (deployed addresses)

##### Market Design

```
        USDC Vault       ETH Vault      (Kyril deploys)
           |   \         /   |
           |    \       /    |
           |     ZRO Vault   |          (we deploy)
           |    /       \    |
           |   /         \   |
        VVV Vault    (other collaterals)
```

- ZRO Borrow Vault: accepts USDC + ETH vaults as collateral (70% / 75% LTV)
- Existing USDC Vault: accepts ZRO vault as collateral (70% / 75% LTV)
- Existing ETH Vault: accepts ZRO vault as collateral (70% / 75% LTV)
- Unit of account: USD (address(840)) for all vaults

##### Key Addresses

| Item | Address |
|---|---|
| ZRO token | `0x6985884C4392D348587B19cb9eAAf157F13271cd` |
| USDC token | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| WETH token | `0x4200000000000000000000000000000000000006` |
| Chainlink ZRO/USD feed | `0xdc31a4CCfCA039BeC6222e20BE7770E12581bfEB` |
| Existing USDC/USD adapter | `0x5C9d3504d64B401BE0E6fDA1b7970e2f5FF75485` |
| Existing ETH/USD adapter | `0xeCa05CC73e67c344d5B146311B13ddB75F7fE4E4` |

##### Parameters

| Parameter | ZRO Vault | USDC/ETH Vaults |
|---|---|---|
| IRM | Base=2%, Kink(70%)=15%, Max=200% | Managed by Kyril |
| Borrow LTV | 70% | 70% (for ZRO collateral) |
| Liquidation LTV | 75% | 75% (for ZRO collateral) |
| Max Liq Discount | 5% | Unchanged |
| Interest Fee | 10% | Unchanged |
| Supply Cap | 185,000 ZRO | Managed by Kyril |
| Borrow Cap | 185,000 ZRO | Managed by Kyril |

##### Deployed Addresses

| Contract | Address |
|---|---|
| ZRO/USD ChainlinkOracle Adapter | `0x9D39B08C040501c0977274F865cD11891BF3c1d2` |
| KinkIRM (ZRO) | `0xD362cf3119854BdB08A0F160B37528EfF5F0280d` |
| ZRO Borrow Vault | `0xCB935d7916B20748e7f14C3B95931b8dcdA2472D` |
| ZRO Collateral Vault | `0xaA73062F331873581991eDdD6848e0e57575E14f` |

##### Remaining TODOs

- [ ] **Activate markets** — call `setHookConfig(address(0), 0)` on ZRO borrow vault + ZRO collateral vault (may already be done — verify with `cast call`)
- [ ] **Official listing** — PR to euler-xyz/euler-labels for app.euler.finance
- [ ] **Liquidation testing** — confirm end-to-end for ZRO-collateralized positions
- [ ] **Governor transfer** — transfer ZRO vault + router from deployer EOA to multisig

### Morpheus — Base (Chain 8453)

**Status: TODO.** Structured product around Morpheus LP. Plugs into `alpha-structures/` framework.

- [ ] **Research Morpheus LP structure on Base** — token addresses, oracle options
- [ ] **Define GTM** — supply/borrow sides, leveraged-position thesis
- [ ] **Design market** — collateral, borrow asset, IRM curve, caps
- [ ] **Frontend integration for MOR on Base** — wire MOR token + Morpheus market into `euler.alphagrowth.io` (labels, vault display, any custom flow). Coordinate with Michael on deploy.

### Hydrex — Base (Chain 8453)

**Status: TODO.** LP-as-collateral market on Hydrex, enabled by Steer's tokenized ALM positions. Ties into Frax BRZ work. Plugs into `alpha-structures/` framework.

**The Steer angle:** Steer tokenizes ALM (active liquidity management) positions, which lets Hydrex LPs be used as ERC-20/4626-style collateral instead of raw concentrated-liquidity NFTs. Without Steer, Hydrex LP-as-collateral is hard because of CL position pricing; with Steer, the wrapped ALM token is straightforward to oracle and accept as collateral.

**Contacts:** Austin Lee (Hydrex), Steer team (TBD)

- [ ] **Engage Steer** — confirm Steer ALM vaults exist for the Hydrex pools we care about
- [ ] **Pick target Hydrex pools** — which pairs to wrap via Steer first
- [ ] **Research Steer ALM token structure** — ERC-4626 compatibility, share→underlying pricing, oracle path
- [ ] **Coordinate with Austin Lee** — supply/incentives questions for Hydrex side
- [ ] **Resolve incentives question** — Frax <> Hydrex <> Steer triangle (who pays whom for what)
- [ ] **Define GTM** — supply/borrow sides, leveraged-farming thesis
- [ ] **Design market** — collateral (Steer-wrapped LP), borrow asset, IRM curve, caps

---

## Needs Supply

Markets are deployed and functional, but stalled on supply/demand. Revisit once capital is lined up.

### Avalanche — CDP or Euler Markets

**Status: WAITING, NEEDS SUPPLY.** Path: Avalanche Treasury buys Securitize ACRED → pair against Frankencoin (ZCHF) for supply. Originally planned to route through AUSD but they've been unresponsive; ACRED → Frankencoin is the live thread. Once supply is lined up, Euler Institutional can help launch the market.

- [ ] **Avalanche Treasury → buy ACRED (Securitize)** — confirm purchase plan and size
- [ ] **Engage Frankencoin** — line up ZCHF as the borrow side against ACRED collateral
- [ ] **Determine deployment path** — Euler V2 on Avalanche (chain 43114) is supported. Check `reference/euler-interfaces/addresses/43114/` for core addresses
- [ ] **Loop in Euler Institutional** — once ACRED + ZCHF are confirmed, hand off launch coordination

### BTCY — Euler Market (Long/Short)

**Status: NEEDS wBTC SUPPLY.** Lead from Shardul. BTCY wants an Euler market — possibly long/short against a stablecoin, possibly a loop. Blocked on a wBTC supply source. Doc: https://aarc.docsend.com/view/s/fwr3pp8myck3hv8e

- [ ] **Source wBTC supply** — who provides the wBTC side of the market?
- [ ] **Review BTCY doc** — token structure and which market design fits
- [ ] **Design market** — long/short vs loop, collateral, IRM, caps

### Origin Protocol — Ethereum Mainnet

**Status: LIVE but no supply.** Contracts deployed, frontend custom code (ARM multiply) merged into consolidated alphagrowth frontend. Labels in `frontends/labels/alphagrowth/1/`. Lending, borrowing, and multiply (direct ARM deposit, zero-slippage looping) all functional.

#### Deployed Addresses

| Contract | Address |
|---|---|
| KinkIRM | `0xa3AC336b108E698d5e96D96F9E1b56dAa9B28bcC` |
| EulerRouter | `0x1C33Db5FC563ac9732C5352c37B73d95b7015E6f` |
| WETH Borrow Vault | `0x2ff5F1Ca35f5100226ac58E1BFE5aac56919443B` |
| ARM-WETH-stETH Collateral Vault | `0xbD858DCee56Df1F0CBa44e6F5a469FbfeC0246cd` |
| Curator Fee Receiver | `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` |

#### Remaining TODOs

- [ ] **Add `origin.svg` logo** to labels — currently using `origin.png` from euler-labels
- [ ] **EulerSwap pool deployment** — Origin deploys via Maglev. Needed for ARM → WETH instant liquidity, unwind, and liquidations.
- [ ] **ARM CapManager check** — if per-LP caps are active, the Swapper contract may need whitelisting for ARM deposits
- [ ] **`setCaps()`** — tighten supply/borrow caps once ready for production. Currently unlimited (0,0).
- [ ] **EulerSwap equilibrium price updates** — determine if periodic updates are needed as ARM exchange rate drifts up
- [ ] **Initial liquidity** — determine WETH and ARM-WETH-stETH amounts for EulerSwap pool
- [ ] **Liquidation testing** — confirm liquidation works end-to-end for ARM-collateralized positions
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable

#### Launch (pending Euler app.euler.finance listing)

Official listing PR submitted: [euler-xyz/euler-labels#521](https://github.com/euler-xyz/euler-labels/pull/521). Once approved:

- [ ] **Schedule podcast with Origin** — co-marketing for launch
- [ ] **Prepare incentives campaign** — ready to go at launch, coordinate with Origin on rewards structure

### Frax — Base (Chain 8453)

**Status: DEPLOYED but no supply.** All contracts live on Base. Labels in `frontends/labels/alphagrowth/8453/`. No custom frontend code needed — standard euler-lite flows.

**Contract dir:** `contracts/frax-contracts/` (Foundry project with `ichi-oracle-kit/` oracle adapter)
**Context doc:** `contracts/frax-contracts/frax-claude.md`
**Governor/deployer:** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448`

#### Cluster

5 ICHI vault collateral markets (single-sided frxUSD on Hydrex) + 1 shared frxUSD borrow vault. Custom `ICHIVaultOracle` uses Algebra VolatilityOracle TWAP for flash-loan-resistant pricing.

#### Deployed Contracts

| Contract | Address |
|---|---|
| KinkIRM | `0xDa930180CC4203d2Fad620c56828b0a1807a9D27` |
| EulerRouter | `0x6565475B4Ed91aD20Ea9C3799fB04648D1a170CA` |
| ICHIVaultOracleFactory | `0x279901f966160dCf3D53236EbEAc08DC372e0821` |
| OraclePoke | `0x455587b12e079bd1dAc1a16C7470df8F7Fbe69BC` |
| frxUSD Borrow Vault | `0x42BA0a943EDcc846333642d62F500894b199A798` |
| Collateral: BRZ | `0x92f8b6bfC276E9A38545bE6517d3295593060D00` |

**Note:** KRWQ poke required explicit gas limit (500k) due to gas estimation being too tight for the `beforeSwap` hook + community vault transfer. The `keeper.ts` cron must set an explicit gas limit when calling `pokeStale()`.

#### Remaining TODOs

- [ ] **Verify frontend** — vaults appear in consolidated frontend, deposit/borrow UI works
- [ ] **`setFeeReceiver()`** — set once AG has a Base fee address
- [ ] **`setCaps()`** — tighten supply/borrow caps before production
- [ ] **Liquidation testing** — confirm end-to-end with treasury liquidation flow
- [ ] **Governor transfer** — transfer from deployer EOA to multisig after stable

#### Launch Plan (from Mar 17-19, 2026 Telegram)

Frontend live at `frax.alphagrowth.fun` — frxUSD borrowable, BRZ as collateral, Chainlink oracle, everything connected. Should also get listed on Euler's official frontend.

**Three things needed for go-live:**

1. **frxUSD supply** — co-incentivization + co-marketing with collateral asset issuers and their LPs through Hydrex. Austin (Hydrex) can set bribes into Hydrex supply-side gauges.
2. **BRZ borrow demand** — users who want to borrow BRZ for Hydrex LP farming. Hydrex can help drive this. Nader (Frax) notes most borrowers prefer setting their own positions, not single-sided vaults.
3. **Liquidator strategy** — two options discussed:
   - Internalized: hold a frxUSD vault, accept BRZ on liquidation
   - Volume-driving: liquidator pushes trades through frxUSD/BRZ LP on Hydrex (Nader's preference — adds volume to Frax pools)

**Contacts:** Nader (Frax), Austin Lee (Hydrex), Pedro (via Austin — can help with all three items)

- [ ] **Submit to Euler official frontend** — get listed on app.euler.finance
- [ ] **Coordinate with Pedro (via Austin)** — key contact for supply, demand, and liquidation
- [ ] **Set up co-incentivization** — AG + Frax + Hydrex bribes for frxUSD supply-side gauges
- [ ] **Build liquidator** — volume-driving through Hydrex frxUSD/BRZ LP (preferred by Frax)
- [ ] **Co-marketing with Frax** — joint announcement once supply + demand are seeded

---

## Standby

Parked work — partner is paused or upstream blocker. Revisit when the listed condition changes.

### Cork Protocol — Ethereum Mainnet

Contracts deployed and verified. Labels in `frontends/labels/alphagrowth/1/`. Frontend custom code (dual-collateral borrow) in `frontends/alphagrowth/`.

**Negotiations open.** Cork has shipped unpaid contract work (rollover MVP, redemption-pool pivot specs) and is asking AG to integrate it. Before advancing, we need to clarify terms: scope of paid vs unpaid work, compensation for the rollover wiring, whether Cork helps source supply (e.g. 10M Midas utilization angle), and what the redemption-pool pivot means for the existing mainnet deployment. Hold all open items below until this conversation lands.

- [ ] **Clarify negotiations with Cork** — paid scope, compensation for rollover integration, supply commitments from Cork side, treatment of existing deployment under the redemption-pool pivot

#### Liquidator — CRITICAL: Redeploy Required

The mainnet-deployed liquidator (`0x1e95cC20ad3917ee523c677faa7AB3467f885CFe`) has a **bug in the seizure order** — it seizes vbUSDC before cST, which causes `InvalidParams()` on every liquidation because zero cST is seized when the violator's debt is already cleared. The fixed version (in `cork-contracts/src/liquidator/CorkProtectedLoopLiquidator.sol`) seizes cST first, then vbUSDC, and caps the Cork exercise amount via `previewExercise`. Tested end-to-end on Tenderly fork — full liquidation cycle succeeds.

- [ ] **Redeploy fixed `CorkProtectedLoopLiquidator` to mainnet** — run `07_DeployLiquidator.s.sol` with updated source
- [ ] **Send NEW liquidator address to Cork team for whitelist** — old address is useless
- [ ] **Confirm Cork whitelist on new address** — `WhitelistManager.addToMarketWhitelist(poolId, newAddress)`
- [ ] **Also whitelist deployer EOA** `0x5304ebB378186b081B99dbb8B6D17d9005eA0448` for minting test cST

#### Liquidation Bot — Built, Needs Production Deploy

Bot scripts at `cork-contracts/script/bot/`. Tested manually on Tenderly fork (successful liquidation: ~6000 sUSDe debt cleared, ~291 sUSDe profit). Uses `cast` (Foundry) and runs as a polling loop.

- [ ] **Deploy bot to Digital Ocean** — install Foundry, configure `.env` with mainnet RPC + bot private key
- [ ] **Fund bot wallet with ETH** for gas on mainnet
- [ ] **Run `setup.sh`** on mainnet (enable controller, set operator, approve sUSDe)
- [ ] **Start `run.sh`** as a systemd service or `nohup` background process

#### Post-Deployment Testing

- [ ] **Acquire mainnet test assets:**
  - vbUSDC: approve USDC → deposit into Cork's vbUSDC vault (1:1)
  - sUSDe: buy via Ethena or DEX
  - cST: `CorkPoolManager.mint()` — requires Cork whitelist on deployer EOA
- [ ] **Switch Cork frontend to mainnet** — update `.env` from Tenderly RPC to mainnet RPC
- [ ] **Verify on euler.alphagrowth.io** — cluster appears, vaults load, deposit/borrow UI works on real mainnet
- [ ] **Test borrow on mainnet** — deposit vbUSDC + cST, borrow sUSDe
- [ ] **Test liquidation on mainnet** — create unhealthy position, confirm end-to-end

#### Rollover Infrastructure (delivered by Cork)

Cork shipped the rollover MVP as `contracts/cork-contracts/rollover-phoenix-private-fix-deploy-and-adapter-cleanup/` — ERC-7683 settlers + ERC-6909 premium escrow + EVC fillers/adapters. The `CorkSeriesRegistry` concept was absorbed into the `CorkCellar` / `CorkCellarFactory` pattern (one cellar per cST series, factory tracks them); referenced in the repo as `ICorkCellarPremiumView` and pulled via `lib/cellar` submodule.

This is unpaid contract work — AG is being asked to wire Cork's rollover infra into the existing Euler market.

- [ ] **H_pool auto-reduction near expiry** — oracle should reduce `hPool → 0` if no valid successor cST exists within `liqWindow`. Mitigation: governor manually calls `CorkOracleImpl.setHPool(0)` before expiry.
- [ ] **Borrow restriction within liqWindow** — hook should block new borrows near expiry without successor cST.
- [ ] **Rollover exception in hook** — `RolloverOperator` temporarily moves cST within EVC batch. `ProtectedLoopHook` on mainnet does not yet recognize the rollover operator — needs a hook update or redeploy.

#### Ongoing Monitoring

- [ ] **Rollover operator** — keeper for cST_old → cST_new before expiry. Must be operational before April 19, 2026.
- [ ] **hPool governance** — if Cork pool impaired, call `CorkOracleImpl.setHPool(value)` to reduce collateral value.
- [ ] **Governor transfer** — after demo stable, transfer from deployer EOA to multisig via `setGovernorAdmin` (borrow vault) and `transferGovernance` (router).

#### Cork Architecture Pivot — Redemption Pool (from Mar 9, 2026 call)

Cork is shifting from an insurance/depeg-protection model to a **redemption pool** model. Key changes:

**Redemption pool vs insurance pool:**
- The Cork pool functions as a redemption facility, not depeg insurance. It buys the collateral asset (e.g. hgETH) at its NAV or slight discount — not 1:1.
- cST tokens are "tickets" that enable access to the redemption pool. They don't have independent value — they're the key that makes the redemption happen.
- Cork's profit model: extracting a portion of position NAV when pools transition between epochs. Pools have a fixed lifespan, then cST goes to 0.

**Oracle change needed:**
- Current liquidator assumes 1:1 exchange (ref asset to collateral asset). This is wrong for a redemption pool.
- Must use the actual exchange rate between collateral asset and reference asset. Cork has a `previewSwap` function for this.
- Example: if hgETH = 1.1 ETH and rsETH = 1.2 ETH, you need ~1.09 hgETH to redeem 1 rsETH. The ratio fluctuates.

**New market needed:**
- Deploy a Cork pool for hgETH / rsETH
- Deploy a new Euler market for hgETH / ETH
- The liquidator needs to be multi-step (manageable via EVC batching)

**Multiply / looping with cST:**
- Looping requires acquiring cST tokens within the multiply EVC batch (you need cST + collateral as a pair)
- Cork has a limit order system (built on 1inch protocol) for cST purchases
- Options: (a) integrate Cork's limit orders into the EVC batch via GenericHandler, (b) ask Euler to add Cork routing to their swap API, (c) Cork builds a zap contract around their limit order system
- Unwinding = selling/redeeming cST in the opposite direction

**cST rollover / epoch migration:**
- cST tokens expire (e.g. every 90 days). At expiry, cST goes to 0.
- Before expiry, a rollover operator must migrate all cST_old to cST_new via EVC batch
- Users pay a premium (cost of ongoing insurance) to extend — taken from ref asset value
- The oracle must accept multiple cST addresses simultaneously (overlap period where both cST_old and cST_new are valid collateral)
- Users must delegate collateral management to an operator who can perform the swap
- Cork will provide a `CorkSeriesRegistry` contract for tracking valid cST addresses
- Hard deadline: cST_old becomes worthless at expiry. Rollover operator must act before this.
- The governor/bot needs to: add new cST collaterals to the market, perform debt swaps, migrate positions — all before expiry via EVC batching

**Open items:**

- [ ] **Cork to clarify limit order integration** — how to buy cST within an EVC batch for multiply
- [ ] **Update oracle to use `previewSwap` exchange rate** — not 1:1, use actual CA/RA ratio
- [ ] **Update liquidator for redemption model** — seize at NAV exchange rate, not 1:1
- [ ] **Test cST expiry scenarios** — what happens to positions when cST approaches 0
- [ ] **Test rollover MVP end-to-end on Tenderly fork** — see "Rollover MVP Testing" below
- [ ] **Build rollover governor bot** — automated EVC batch that adds new cST collaterals and migrates positions before expiry

#### Rollover MVP Testing

The rollover repo ships its own test suite (libs, BTT trees, integration, invariant). To validate it locally and against AG's deployed Cork market:

1. **Init submodules + build:**
   ```bash
   cd contracts/cork-contracts/rollover-phoenix-private-fix-deploy-and-adapter-cleanup
   git submodule update --init --recursive
   forge build
   ```
2. **Run Cork's tests:**
   ```bash
   forge test                                           # full suite
   forge test --match-path "test/libs/*"                # 22 lib tests
   forge test --match-path "test/erc6909/*"             # 31 ERC6909 BTT
   forge test --match-path "test/integration/*"         # multi-contract flows
   ```
3. **Tenderly fork test against deployed Cork market:**
   - Fork mainnet; ensure the deployed market (`0x53FDab…502f`, `0xadF7afdA…8C6b`, `0xd0f8aC…dA4c`) is in scope
   - Deploy settlers + EVC adapters + fillers via `script/foundry-scripts/Deploy*.s.sol`
   - Open a position on the existing market (vbUSDC + cST collateral, sUSDe debt)
   - Mint a successor cST series via `CorkCellarFactory`
   - Submit a rollover intent → filler picks it up → EVC batch swaps cST_old for cST_new without repaying debt
   - Validate: position health unchanged, debt preserved, premium debited via ERC6909Premium
4. **Hook gap to test:** The existing `ProtectedLoopHook` does not recognize a `RolloverOperator`. The rollover EVC batch will be blocked by the dual-collateral pairing check. Either:
   - Deploy a new hook with a rollover-operator exception and migrate the market, OR
   - Add the exception to existing hook (if upgradeable — verify before testing)
5. **Premium flow:** Filler must pre-deposit payment tokens into `ERC6909Premium`; settler debits via dual-auth `settle()`. Validate this leg in isolation before integrating with the EVC batch.
