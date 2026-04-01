# Pending Markets

Candidate tokens for Euler V2 deployment. Data as of 2026-04-01.

---

## Part 1: Perp Markets (Funding Rate Arbitrage)

Tokens with perp open interest where lending/borrowing creates FR arb opportunities.

### Tier 1: High OI (>$20M)

**HYPE** — $845M OI
- FR: 0.0013% current | 0.40% 30D | 15.63% 365D
- Listed: Morpho (collateral only), HyperLend (can short)
- Cannot short on Morpho

**ASTER** — $60M OI
- FR: -0.0013% current | 0.18% 30D | 9.48% 365D
- Listed: Euler (collateral only)
- Supply cap: 5.92%, $6.59/112M
- DEX: 250k drop 10

**PAXG** — $53M OI
- FR: 0.0010% current | 0.01% 30D | 5.13% 365D
- Listed: Morpho

**ZRO** — $47M OI (**SCRIPTS READY** — `contracts/zro-contracts/`)
- FR: 0.0013% current | -1.04% 30D | -10.14% 365D
- Listed: NO
- DEX: 170k drop 10 on Base

**AVAX** — $38M OI
- FR: 0.0013% current | 0.59% 30D | 4.98% 365D
- Listed: AAVE (supply cap 89.80%, $141/157M)

**LIT** — $30M OI
- FR: 0.0010% current | 0.37% 30D | 2.43% 365D
- Listed: NO
- DEX: Low liquidity. Has own SPOT market: app.lighter.xyz/trade/LIT_USDC
- Opportunity: Long, C&C. Challenge: Liquidations, USDC supply

**LINK** — $28M OI
- FR: 0.0010% current | 0.74% 30D | 11.59% 365D
- Listed: AAVE, Compound

**XPL** — $28M OI
- FR: 0.0013% current | 0.72% 30D | 9.29% 365D
- Listed: AAVE (cap hit), Euler (cap not hit)
- DEX: 40k drop 10 on BSC

**MON** — $28M OI
- FR: -0.0086% current | -1.13% 30D | 1.25% 365D
- Listed: Morpho, Euler
- Negative FR

**BNB** — $21M OI
- FR: -0.0004% current | 0.24% 30D | 4.20% 365D
- Listed: AAVE, Euler

**AAVE** — $21M OI
- FR: 0.0013% current | 0.36% 30D | 11.58% 365D
- Listed: AAVE

**WLD** — $20M OI
- FR: -0.0035% current | 0.59% 30D | 7.90% 365D
- Listed: Morpho

### Tier 2: Medium OI ($5M-$20M)

**WLFI** — $19M OI
- FR: 0.0012% current | 0.34% 30D | -11.34% 365D
- Listed: NO
- DEX: 410k drop 10
- Opportunity: Short, RC&C. Challenge: WLFI supply

**VIRTUAL** — $15M OI
- FR: 0.0013% current | -1.09% 30D | 0.66% 365D
- Listed: Morpho (with fxUSD, supply only)
- DEX: 350k drop 10
- No place to short it. Challenge: VIRTUAL supply

**ENA** — $13M OI
- FR: -0.0005% current | -0.13% 30D | 1.93% 365D
- Listed: NO
- DEX: 110k drop 10
- Opportunity: Short, RC&C, Long, C&C

**VVV** — $11M OI (**Under Kyril's deployment**)
- FR: -0.0058% current | -6.23% 30D | -32.60% 365D
- Listed: Morpho (supply only)
- DEX: 1.2M drop 10
- No place to short it

**UNI** — $10M OI
- FR: 0.0013% current | 0.46% 30D | 10.45% 365D
- Listed: Compound, Morpho

**DOT** — $7M OI
- FR: 0.0013% current | -1.98% 30D | 1.42% 365D
- Listed: NO
- DEX: Low liquidity

**CRV** — $5M OI
- FR: -0.0045% current | 0.32% 30D | 10.37% 365D
- Listed: NO
- DEX: 10M drop 2%
- No place to long it. Challenge: CRV supply

**MORPHO** — $5M OI
- FR: 0.0003% current | -0.47% 30D | 1.42% 365D
- Listed: Morpho (high utilization)

### Tier 3: Lower OI ($1M-$5M)

**MNT** — $4.7M OI | FR 365D: 10.51% | AAVE (40% max LTV)

**FET** — $4.4M OI | FR 365D: -4.82% | NOT listed | 30k drop 2%

**ETHFI** — $4.3M OI | FR 365D: 6.72% | NOT listed | 25k drop 2%
- Ether.fi has $91M collateral held

**PENDLE** — $3.8M OI | FR 365D: 11.01% | NOT listed

**LDO** — $3.7M OI | FR 365D: 12.43% | NOT listed

**ATOM** — $3.7M OI | FR 365D: -11.32% | NOT listed | Negative FR

**PURR** — $3.7M OI | FR 365D: 25.07% | NOT listed (HyperEVM) | Very high FR

**ARB** — $3.3M OI | FR 365D: 6.66% | Compound (collateral only)

**STBL** — $3.3M OI | FR 365D: 14.93% | NOT listed

**OP** — $3.2M OI | FR 365D: 0.01% | Compound (collateral only)

**STABLE** — $3.1M OI | FR 365D: -17.50% | NOT listed | Deeply negative FR

**STRK** — $3.1M OI | FR 365D: -0.82% | NOT listed

**ZK** — $3.0M OI | FR 365D: -12.96% | NOT listed

**ONDO** — $2.8M OI | FR 365D: 6.21% | Morpho (collateral only)

**BERA** — $2.7M OI | FR 365D: -81.42% | Euler | Extremely negative FR

**LINEA** — $2.6M OI | FR 365D: 0.06% | NOT listed

**CFX** — $2.6M OI | FR 365D: 4.50% | -

**KAITO** — $2.5M OI | FR 365D: -59.12% | NOT listed

**RENDER** — $2.4M OI | FR 365D: 4.89% | NOT listed

**AERO** — $2.4M OI | FR 365D: -0.42% | Compound (borrow only), Morpho (collateral only), Euler

**AXS** — $2.4M OI | FR 365D: -78.59% | NOT listed | Extremely negative FR

**POL** — $2.3M OI | FR 365D: 1.25% | AAVE, Compound, Morpho (96% on AAVE)

**EIGEN** — $2.2M OI | FR 365D: 0.89% | Morpho (collateral only)

**SKY** — $2.1M OI | FR 365D: -5.33% | Compound (USDS market, collateral only)

**ENS** — $1.8M OI | FR 365D: 11.47% | NOT listed

**APEX** — $1.8M OI | FR 365D: 6.90% | NOT listed

**MAVIA** — $1.6M OI | FR 365D: 33.97% | NOT listed | Extremely high FR

**SPX** — $1.6M OI | FR 365D: 6.16% | NOT listed

**INJ** — $1.6M OI | FR 365D: -2.42% | NOT listed

**HEMI** — $1.3M OI | FR 365D: -4.29% | NOT listed

**SYRUP** — $1.3M OI | FR 365D: 1.80% | Morpho (collateral only)

**RESOLV** — $1.2M OI | FR 365D: -102.98% | NOT listed | No liquidity

**SAGA** — $1.1M OI | FR 365D: 1.38% | NOT listed | No liquidity

**NXPC** — $1.1M OI | FR 365D: -11.47% | NOT listed

**S** — $1.1M OI | FR 365D: 3.08% | AAVE, Morpho

**RUNE** — $1.0M OI | FR 365D: 7.98% | NOT listed

**AVNT** — $1.0M OI | FR 365D: -72.59% | NOT listed

---

## Part 2: Duration Risk RWAs (Pendle PT Leverage)

Yield-bearing tokens with Pendle PT markets. The play: borrow the underlying, buy PT at a discount, hold to maturity for fixed yield.

**Key:** TVL = Pendle market TVL | LP = PT-to-underlying liquidity | APR = fixed yield at maturity | Redemption = time to get underlying back | Score = internal rating (1-10)

### Ethereum Mainnet — USD Underlying

**sENA** — Ethena | Score: 6
- TVL: $17.9M | LP: $5.5M | APR: 16.1% | Duration: 18d
- Underlying: Staked ENA | Redemption: 7 days
- Looped exposure to sENA

**AID / sAID** — GAIB | Score: 8
- TVL: $6.5M | LP: $622k | APR: 14.1% | Duration: 11d
- Underlying: USDC | Redemption: 30 days
- Low liquidity on Pendle market

**USD3 / sUSD3** — 3JANE | Score: 4
- TVL: $14.0M | LP: $5.3M | APR: 13.2% | Duration: 11d
- Underlying: USDC | Redemption: Instant / 30 days
- Problem: recovery can be a legal process

**RLP** — Resolv | Score: 6
- TVL: $10.8M | LP: $4.5M | APR: 13.0% | Duration: 81d
- Underlying: USDC | Redemption: 1 day
- Leverage: Morpho (RLP/USDC)
- Good PT liquidity, shallow for RLP. Delta neutral basis trade token

**mHYPER** — Midas | Score: 7
- TVL: $26.5M | LP: $7.8M | APR: 12.8% | Duration: 102d
- Underlying: USDC | Redemption: 888k instant
- Leverage: Morpho (mHYPER/USDC)
- Flag: Hyperithm. Improving efficiency for Risk Curator competition

**savUSD** — Avant | Score: 6
- TVL: $6.8M | LP: $3.7M | APR: 12.4% | Duration: 116d
- Underlying: USDC | Redemption: 1 day (savUSDx = 7 days, junior tranche)

**USN / sUSN** — Noon | Score: 7
- TVL: $3.1M | LP: $1.6M | APR: 11.7% | Duration: 11d
- Underlying: USDC | Redemption: 1d / 7d whitelisted
- Good whitelisting arbitrage (7 days)

**mAPOLLO** — Midas | Score: 8
- TVL: $9.1M | LP: $3.8M | APR: 10.0% | Duration: 102d
- Underlying: USDC | Redemption: 1.8M instant
- Competitor, but a good solution. Risk Manager Fund

**upUSDC** — Upshift | Score: 7
- TVL: $1.3M | LP: $907k | APR: 10.0% | Duration: 74d
- Underlying: USDC | Redemption: 1 day
- Leverage: Morpho (upUSDC/USDC)

**reUSD** — re.xyz | Score: 10
- TVL: $102.0M | LP: $8.8M | APR: 10.0% | Duration: 158d
- Underlying: USDC / USDe | Redemption: 7d / 180d
- Leverage: Morpho (reUSD/USDC)
- reUSDe PT good for 6mo duration token

**jrUSDe** — Ethena / Strata | Score: 7
- TVL: $38.9M | LP: $15.1M | APR: 9.6% | Duration: 74d
- Underlying: sUSDe | Redemption: 7 days (sUSDe to USDe)
- Leverage: Euler (jrUSDe/USDC)
- Ethena leveraged structured product, junior tranche

**wstUSR** — Resolv | Score: 8
- TVL: $3.8M | LP: $915k | APR: 9.4% | Duration: 39d
- Underlying: USDC | Redemption: 1 day
- Leverage: Morpho (wstUSR/USR)

**rUSD / wsrUSD** — Reservoir | Score: 7
- TVL: $224k | LP: $54k | APR: 9.0% | Duration: 39d
- Underlying: USDC | Redemption: 250k instant (refills hourly)
- Leverage: Euler (wsrUSR/USR)

**syrupUSDC** — Maple | Score: 8
- TVL: $1.3M | LP: $374k | APR: 8.8% | Duration: 67d
- Underlying: USDC | Redemption: 24 hours
- Leverage: Morpho Arbitrum (syrupUSDC/USDC)
- Potential partner

**mEDGE** — Midas | Score: 7
- TVL: $1.1M | LP: $386k | APR: 8.6% | Duration: 11d
- Underlying: USDC | Redemption: 1.2M instant
- Flag: Edge Capital. Risk Curator Competition

**DUSD** — Makina | Score: 8.5
- TVL: $30.5M | LP: $13.1M | APR: 8.3% | Duration: 11d
- Underlying: USDC | Redemption: Manual release
- Leverage: Morpho (DUSD/USDC)
- All onchain strategies

**msyrupUSDp** — Midas | Score: 10
- TVL: $2.6M | LP: $1.0M | APR: 7.9% | Duration: 39d
- Underlying: USDC | Redemption: 2.89M instant
- Leverage: TermMax (msyrupUSDp/USDC) — currently empty

**USDaf** — Asymmetry | Score: 7
- TVL: $49k | LP: $40k | APR: 7.9% | Duration: 102d
- Underlying: BOLD | Redemption: Instant
- Hedge fund structure around Liquity v2. Struggling

**coreUSDC** — Upshift | Score: 7
- TVL: $4.8M | LP: $2.9M | APR: 7.8% | Duration: 102d
- Underlying: USDC | Redemption: 1 day
- Looping on top of Upshift's general purpose vault

**iUSD / siUSD** — InfiniFi | Score: 10
- TVL: $21.4M | LP: $9.0M | APR: 7.0% | Duration: 67d
- Underlying: USDC | Redemption: Discretionary queue
- Leverage: Morpho (iUSD/USDC)
- Onchain strategies. Direct competitor

**sYUSD** — Aegis | Score: 8
- TVL: $7.8M | LP: $6.4M | APR: 6.9% | Duration: 67d
- Underlying: USD | Redemption: 7 days
- Unstaking fee. FR arb on CEX

**ysUSDC** — Superform | Score: 9
- TVL: $2.8M | LP: $1.5M | APR: 6.6% | Duration: 11d
- Underlying: USDC | Redemption: 1 hour
- Multi-money market USDC lender

**srUSDe** — Ethena / Strata | Score: 7
- TVL: $68.9M | LP: $17.5M | APR: 6.1% | Duration: 74d
- Underlying: sUSDe | Redemption: 7 days (sUSDe to USDe)
- Leverage: Euler (srUSDe/USDC)
- Ethena leveraged structured product, senior tranche

**ysyBOLD** — Liquity | Score: 7
- TVL: $347k | LP: $355k | APR: 6.0% | Duration: 130d
- Underlying: BOLD | Redemption: Instant
- Tokenized Pendle Yearn product. Liquity v2

**USDe / sUSDe** — Ethena | Score: 7
- TVL: $1.5B | LP: $50.0M | APR: 5.6% | Duration: 81d
- Underlying: sUSDe | Redemption: 7 days
- Leverage: AAVE (sUSDe/USDT)
- Obvious trade. Foundational market

### Ethereum Mainnet — ETH Underlying

**ysETH** — Superform | Score: 9
- TVL: $4.3M | LP: $1.5M | APR: 6.6% | Duration: 11d
- Redemption: 1 hour
- Multi-money market ETH lender

**hgETH** — Kelp | Score: 9
- TVL: $6.4M | LP: $4.2M | APR: 5.4% | Duration: 158d
- Redemption: 3 days
- Leverage: Morpho (hgETH/wETH)
- Depends on Kelp's vault operators, but insured

**tETH** — Treehouse | Score: 10
- TVL: $1.9M | LP: $745k | APR: 5.1% | Duration: 102d
- Redemption: Instant + 7d for larger size
- Great

**strETH** — Lido / Mellow | Score: 8
- TVL: $2.5M | LP: $524k | APR: 4.9% | Duration: 66d
- Redemption: 3 days
- Mellow x Lido vault

**GGV** — Lido / Veda | Score: 6
- TVL: $726k | APR: 4.7% | Duration: 66d
- Redemption: 3 days
- Veda x Lido levered LST vault. Performance fee. 24h transfer lock

**agETH** — Kelp | Score: 8
- TVL: $1.2M | LP: $913k | APR: 4.3% | Duration: 157d
- Redemption: 6 days
- Kelp airdrop gain vault

**pufETH** — Puffer | Score: 9
- TVL: $3.1M | LP: $1.2M | APR: 4.1% | Duration: 158d
- Redemption: 14 days

**wOETH** — Origin | Score: 8
- TVL: $693k | LP: $315k | APR: 4.0% | Duration: 157d
- Redemption: 8 days
- Good growth opportunity

**ARM-wETH-stETH** — Origin | Score: 5
- TVL: $68k | LP: $46k | APR: 4.0% | Duration: 157d
- Redemption: 10 min
- Redemption strategy arb vault. Really low APR

**DETH** — Makina | Score: 8.5
- TVL: $23.0M | LP: $11.5M | APR: 4.0% | Duration: 11d
- Redemption: Manual release
- Leverage: TermMax (wETH/DETH)
- All onchain strategies

**weETH / weETHs** — EtherFi / EigenLayer | Score: 10
- TVL: $14.0M | LP: $3.2M | APR: 3.8% | Duration: 158d
- Redemption: 5 days
- Leverage: TermMax (weWETH/wETH)
- Easy yes

**uniETH** — Bedrock | Score: 10
- TVL: $2.5M | LP: $1.3M | APR: 3.2% | Duration: 158d
- Redemption: Queue (32 ETH at a time)
- Full node staking LST

**rswETH** — Swell | Score: 8
- TVL: $7.9M | LP: $5.8M | APR: 3.1% | Duration: 158d
- Redemption: 28 days

**swETH** — Swell | Score: 8
- TVL: $1.1M | LP: $497k | APR: 3.0% | Duration: 158d
- Redemption: 12 days

**rsETH** — Kelp | Score: 10
- TVL: $2.8M | LP: $5.8M | APR: 2.5% | Duration: 158d
- Redemption: 15-21 days

**wstETH** — Lido | Score: 10
- TVL: $20.1M | LP: $12.1M | APR: 2.4% | Duration: 158d
- Redemption: 1 day
- There's a play here. Easy yes

### Ethereum Mainnet — BTC Underlying

**DBIT** — Makina | Score: 8.5
- TVL: $5.9M | LP: $2.5M | APR: 4.7% | Duration: 11d
- Redemption: Manual release
- All onchain strategies

**uniBTC** — Bedrock | Score: 7
- TVL: $29.2M | LP: $11.4M | APR: 1.0% | Duration: 32d
- Redemption: 8 days
- Low yield

### Arbitrum

**USDai / sUSDai** — usd.ai | Score: 10
- TVL: $401.3M | LP: $69.0M | APR: 13.5% | Duration: 31d
- Underlying: USD
- Leverage: Euler Arbitrum (sUSDai/USDC)
- CupOJoseph is bullish

**thBILL** — Theo
- TVL: $43.6M | LP: $11.4M | APR: 8.0% | Duration: 31d | Underlying: USD

**weETH** — EtherFi
- TVL: $8.2M | APR: 2.4% | Duration: 157d | Underlying: ETH

**rETH** — Rocket Pool
- TVL: $4.0M | LP: $2.7M | APR: 2.3% | Duration: 157d | Underlying: ETH

**wstETH** — Lido
- TVL: $1.5M | APR: 2.4% | Duration: 157d | Underlying: ETH

**RLP** — Resolv
- TVL: $819k | APR: 13.0% | Duration: 10d | Underlying: USD

**rsETH** — Kelp
- TVL: $744k | APR: 2.5% | Duration: 157d | Underlying: ETH

**uniETH** — Bedrock
- TVL: $693k | APR: 3.2% | Duration: 157d | Underlying: ETH

**gUSDC** — Gains
- TVL: $301k | LP: $451k | APR: 4.5% | Duration: 157d | Underlying: USD

**wstUSR** — Resolv
- TVL: $189k | APR: 9.4% | Duration: 10d | Underlying: USD

**syrupUSDC** — Maple
- TVL: $82k | APR: 8.8% | Duration: 10d | Underlying: USD

### Plasma (Chain 9745)

**USDai / sUSDai** — usd.ai | TVL: $551.4M | APR: 13.5%

**yzUSD / syzUSD** — Yuzu | TVL: $2.7M | APR: 15.0%

**RLP** — Resolv | TVL: $10.8M | APR: 13.0%

**mHYPER** — Midas | TVL: $26.5M | APR: 12.8%

**splUSD** — Trevee | TVL: $603k | APR: 9.6%

**wstUSR** — Resolv | TVL: $3.8M | APR: 9.4%

**syrupUSDT** — Maple | TVL: $18.6M | APR: 8.1%

**fUSDT0** — Fluid | TVL: $5.6M | APR: 6.3%

**USDe / sUSDe** — Ethena | TVL: $1.5B | APR: 5.6%

**aUSDT** — USDT | TVL: $3.8M | APR: 5.0%

**plasmaUSD** — Plasma | TVL: $13.9M | APR: 4.9%

### BNB Chain (Chain 56)

**slisBNBx** — Lista | TVL: $61.5M | APR: 5.3% | Underlying: BNB

**uniBTC** — Bedrock | TVL: $29.2M | APR: 1.0% | Underlying: BTC

**cUSDO** — Open Eden | TVL: $21.7M | APR: 5.0% | Underlying: USD

**SolvBTC** — Solv | TVL: $5.0M | APR: 1.1% | Underlying: BTC

**satUSD** — River | TVL: $1.5M | APR: 4.9% | Underlying: USD

**ynBNBx** — YieldNest | TVL: $159k | APR: 2.6% | Underlying: BNB

### Base (Chain 8453)

**sKaito** — Kaito | TVL: $5.4M | APR: 51.6% | Underlying: KAITO
- Extremely high APR

**yoUSD** — YO | TVL: $2.0M | APR: 8.1% | Underlying: USD

**yoETH** — YO | TVL: $5.7M | APR: 5.0% | Underlying: ETH

**yoEUR** — YO | TVL: $158k | APR: 4.7% | Underlying: USD

**wOETH / wsuperOETHb** — Origin | TVL: $693k | APR: 3.5% | Underlying: ETH

**uniBTC** — Bedrock | TVL: $29.2M | APR: 1.0% | Underlying: BTC

---

## Active Deployments

See `TODO.md` for full status.

- **ZRO** — Scripts ready (rootdraws). `contracts/zro-contracts/` — adds to Kyril's USDC/ETH cluster on Base
- **VVV** — In progress (Kyril). Part of USDC/ETH/VVV cluster on Base
- **USDC** — In progress (Kyril). Shared borrow vault for Base cluster
- **ETH** — In progress (Kyril). Shared borrow vault for Base cluster

---

## Collateral Research

**Ether.fi** — $91M collateral held (ETHFI)
- Borrow demand: See OI + positive FR for ETH/USDT
- DEX liquidity: $1.4M | Max collateral cap: $467k
