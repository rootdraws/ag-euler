Full Codebase Breakdown: euler-lite
1. Project Overview
Euler Lite is a Nuxt 3 / Vue 3 SPA (SSR disabled) for the Euler Finance lending/borrowing protocol. It is white-label-ready via environment variables — one Docker image, many deployments. The Nitro server only runs API proxies (RPC, address screening, Tenderly simulation); the frontend is fully client-side.
Key dependencies:
nuxt 3.16.1, vue 3.5.16, typescript 5.9.3
viem 2.44.2 — EVM calls
@wagmi/vue 0.2.10 + @reown/appkit 1.8.7 — wallet connection
@tanstack/vue-query 5.90.2 — async data
axios 1.13.5 — HTTP (labels, swap API, pricing)
luxon 3.4.4 — dates
chart.js 4.5.1 + vue-chartjs — charts
@pythnetwork/price-service-client — Pyth oracle prices
Tailwind CSS 3 + SCSS
2. Directory Structure
euler-lite/├── assets/│   ├── sprite/svg/         ← 40+ SVG icons (built into a sprite)│   └── styles/             ← Global SCSS (main entry, variables, fonts, reset, transitions)├── components/│   ├── base/               ← Generic layout primitives│   ├── entities/           ← Domain-specific components│   └── ui/                 ← Headless UI primitives (inputs, modals, tabs, etc.)├── composables/            ← 74 composable files (+ subdirs)├── docs/                   ← 12 markdown documentation files├── entities/               ← Data models, ABIs, business logic├── middleware/             ← Nuxt route middleware (client-side)├── pages/                  ← All routes (26 .vue files)├── plugins/                ← Nuxt plugins (5)├── public/                 ← Static assets (entity SVGs, oracle SVGs, favicons)├── server/                 ← Nitro server│   ├── api/                ← 4 API routes│   ├── middleware/         ← 4 server middleware│   ├── plugins/            ← 3 Nitro plugins│   └── utils/              ← 4 server utilities├── services/               ← Pure service modules (pricing, intrinsic APY, geo)├── types/                  ← Shared TS types└── utils/                  ← 29 pure utility files
3. Key Configuration Files
nuxt.config.ts
ssr: false — pure SPA; Nitro is only for API proxying
Modules: @nuxtjs/tailwindcss, @nuxt/eslint, @gvade/nuxt3-svg-sprite (auto-generates icon sprite), @vueuse/nuxt
components.pathPrefix: false — all components auto-imported without path prefix
runtimeConfig.public — typed defaults for all NUXT_PUBLIC_CONFIG_* env vars (feature flags, social URLs, labels repo, API URLs, etc.)
nitro.compressPublicAssets: true — gzip compression on all public files
Meta tags (og:title, twitter:title) are hardcoded as "Euler Lite" in the static HTML; patched at runtime by server/plugins/app-config.ts
package.json
Scripts: dev, build, generate, preview, lint, lint:fix, typecheck
simple-git-hooks pre-commit runs lint-staged (ESLint --fix on *.ts,*.vue)
.env
Current deployment is configured for:
NUXT_PUBLIC_CONFIG_LABELS_REPO="rootdraws/ag-euler-cork-labels" ← AG's Cork deployment
ETH mainnet only (RPC_URL_HTTP_1)
All subgraph URIs for 14 chains pre-configured (mainnet, Arbitrum, Base, Sonic, Swell, Unichain, Monad, BSC, Linea, Avalanche, BOB, Berachain, Plasma, Ink)
All feature flags enabled
DOPPLER_ENVIRONMENT=dev
tailwind.config.js
Spacing: pixel-exact scale (0–100px)
Colors: fully mapped to CSS variables — surface, card, content.*, line.*, primary.*, accent.*, neutral.*, success/warning/error, plus legacy euler-dark.* and aquamarine.* families
Screens: mobile (max 900px) / laptop (min 901px) — only two breakpoints
Shadows: all reference CSS variables for theme-aware depth
Typography: semantic scale h1–h6, p1–p3 with lineHeight + fontWeight baked in
!./components/ui/**/*.vue excluded from Tailwind — UI primitives use SCSS only
4. Assets & Styles
assets/styles/
File	Purpose
main.scss	Entry point — imports all other SCSS files + components/ui/styles/main
variables.scss	Full design token system — institutional navy/gold light palette, dark theme overrides, shadows, border radii, animation easing, semantic bg/text/border vars, all euler-dark-* and aquamarine-* HSL vars, legacy RGB vars
fonts.scss	Self-hosted Inter (variable woff2) + Besley (variable woff2) — no Google Fonts in prod
reset.scss	CSS reset rules
transitions.scss	Global transition utility classes
Dark theme: the [data-theme="dark"] block in variables.scss flips the entire neutral palette (inverted: neutral-50 becomes near-black #0a0a0a, neutral-900 becomes near-white #fafafa) and adjusts all semantic background/text/border/shadow tokens.
Color families:
--primary-* — Professional Navy (50→900)
--accent-* — Gold/Bronze CTAs (300→700)
--neutral-* — Warm Grays (50→900)
--aquamarine-* — Legacy accent (gold/bronze tones in HSL)
--euler-dark-* — Legacy surface hierarchy (remapped per theme)
assets/sprite/svg/
40 SVG icons auto-compiled into a single sprite by @gvade/nuxt3-svg-sprite. Used via <UiIcon name="..." />.
5. Entities Directory (entities/)
Pure TypeScript — no Vue. Business logic, types, ABIs, constants.
File	Purpose
custom.ts	themeHue = 150 (legacy; currently overridden by SCSS). Also contains the giant intrinsicApySources[] array — ~170 vault→DefiLlama pool and vault→Pendle market mappings across 14 chains
constants.ts	Error message maps, EVC error signatures, swap constants, oracle ABI components, MERKL distributor address, all external API URLs
menu.ts	MenuItem[] definition + getMenuItems() (filters by feature flags) + getDefaultPageRoute() (priority order: explore→earn→lend→borrow→portfolio)
vault/types.ts	Core TS interfaces: Vault, EarnVault, SecuritizeVault, VaultAsset, VaultCollateralLTV, VaultInterestRateInfo, AnyBorrowVaultPair, etc.
vault/fetcher.ts	All vault data fetching from the Euler Lens contracts. fetchVaults() — async generator, batches via multicall. processRawVaultData() — single source of truth for raw→Vault mapping. Also fetches earn vaults, escrow vaults, securitize vaults, vault factories
vault/apy.ts	APY calculations from exchange rate history
vault/pricing.ts	Oracle price resolution (resolveAssetPriceInfo, resolveUnitOfAccountPriceInfo)
vault/ltv.ts	LTV computation utilities
vault/index.ts	Re-exports + getVaultUtilization()
vault/factory.ts	Fetches vault factory addresses to distinguish EVK vs Securitize vaults
vault/escrow-fetcher.ts	Fetches escrow vault data
vault/utils.ts	General vault utilities
txPlan.ts	Transaction plan types and builder logic for EVC batch operations
euler/abis.ts	All Euler contract ABIs (VaultLens, EarnVaultLens, AccountLens, UtilsLens, PerspectiveABI, etc.)
euler/labels.ts	Type definitions for labels JSON: EulerLabelEntity, EulerLabelProduct, EulerLabelPoint, empty defaults, getEulerLabelEntityLogo()
chainRegistry.ts	Maps chain IDs to @reown/appkit/networks objects via getNetworksByChainIds()
oracle.ts	Oracle types and collectPythFeedIds()
oracle-providers.ts	Provider-specific oracle metadata
swap.ts	Swap types, SwapperMode enum, SwapApiQuote, RoutingConfig
token.ts	Token types
account.ts	AccountBorrowPosition, AccountDepositPosition interfaces
permit2.ts	Permit2 types and helpers
merkl.ts	Merkl reward types
reul.ts	rEUL (Euler locked token) types
brevis.ts	Brevis reward types
reward-campaign.ts	Reward campaign types
saHooksSDK.ts	Standalone Account hooks SDK integration
intrinsic-apy.ts	IntrinsicApy types
lend-discovery.ts	MarketGroup, CuratorGroup, MarketGroupMetrics types
tuning-constants.ts	Performance constants — batch sizes (BATCH_SIZE_VAULT_FETCH, BATCH_SIZE_PARALLEL_ROUNDS, BATCH_SIZE_RPC_CALLS), cache TTLs (15s, 5min)
evc-error-signatures.ts	EVC revert error 4-byte selector → message map
country-constants.ts	SANCTIONED_COUNTRIES, EU_COUNTRIES, EEA_COUNTRIES, EFTA_COUNTRIES, COUNTRY_GROUPS
6. Composables (74 files)
Config Layer
Composable	Purpose
useEnvConfig	Single source of truth for API URLs + app metadata. Resolution: window.__APP_CONFIG__ (runtime injection) → Nuxt runtimeConfig (build-time) → hardcoded defaults. Cached after first call
useDeployConfig	Feature flags, social URLs, labels repo config, all NUXT_PUBLIC_CONFIG_* vars. Merges useEnvConfig + useChainConfig
useChainConfig	Derives enabledChainIds[] and subgraphUris{} from RPC_URL_HTTP_* and NUXT_PUBLIC_SUBGRAPH_URI_* env vars. Reads from window.__CHAIN_CONFIG__ on client
useEulerConfig	Combines all config into final URLs: labels base URL, all API URLs, EVM_PROVIDER_URL (→ /api/rpc/<chainId>), SUBGRAPH_URL per chain
useEulerAddresses	Fetches Euler protocol addresses (EVC, lens contracts, periphery) from the euler-interfaces chains JSON; exposes chainId, eulerLensAddresses, eulerCoreAddresses, eulerPeripheryAddresses
Labels & Vault Discovery
Composable	Purpose
useEulerLabels	The vault filter. Fetches products.json, entities.json, points.json (and optionally earn-vaults.json) from the configured GitHub labels repo. Populates verifiedVaultAddresses[] — vaults not in this list are invisible. Also exposes products, entities, points, oracleAdapters. 5-min TTL cache
useEulerProductOfVault	Returns the product a vault belongs to (reactive)
useEulerEntitiesOfVault	Returns entities associated with a vault
useEulerPointsOfVault	Returns points programs for a vault
Vault State
Composable	Purpose
useVaults	Central vault loading orchestrator. loadVaults() coordinates Phase 1 (factory fetch), Phase 2 (parallel EVK + Earn + Escrow fetch), generation counters for stale data prevention on chain switch. Also getVault(), getBorrowVaultPair(), getEarnVault(), getEscrowVault(), getSecuritizeVault(), isVaultGovernorVerified(), isEarnVaultOwnerVerified()
useVaultRegistry	In-memory registry of loaded vaults keyed by address. set(), get(), getOrFetch(), getAll(), getVerifiedEvkVaults(), isKnownEscrowAddress(), etc. Separation between 'evk', 'earn', 'securitize' types
useVaultSearch	Fuzzy vault search by name/symbol/address
useVaultWarnings	Vault warning logic (deprecated, blocked, restricted by country)
useMarketGroups	Groups vaults into MarketGroup[] using 3 steps: (1) product-label groups from labels repo, (2) augment with collateral graph links, (3) BFS cluster orphans by collateral relationships. Async TVL resolution via getAssetUsdValueOrZero. Also computes curatorGroups
Account & Portfolio
Composable	Purpose
useEulerAccount	Top-level user account composable. Watches wallet + lens readiness, debounces updatePositions(). Handles chain switching (clears stale positions). Exposes borrowPositions, depositPositions, portfolioAddress, refreshAllPositions, getPositionBySubAccountIndex
useAccountPositions	Lower-level position loading. updateBorrowPositions() — fetches from subgraph entries, calls AccountLens with optional Pyth simulation, resolves collateral. updateSavingsPositions() — deposit positions, filters out collateral-in-use
useAccountValues	Aggregate totalSuppliedValue, totalBorrowedValue
useAccountPortfolioMetrics	Portfolio ROE and net APY
usePositionIndex	Converts between subaccount addresses and indices
useREULLocks	Manages rEUL (locked Euler token) positions
Pricing
Composable	Purpose
usePriceBackend	Fetches prices from Euler Price API
usePriceInvert	Price inversion utility
useOracleAdapterPrices	Loads oracle adapter metadata per vault
useIntrinsicApy	Fetches intrinsic APY for yield-bearing assets from DefiLlama / Pendle (sources defined in entities/custom.ts)
useRewardsApy	Computes APY from Merkl reward campaigns
useBestNetAPY	Combines supply APY + intrinsic APY + rewards APY
Swap & Operations
Composable	Purpose
useSwapApi	HTTP wrapper for Euler Swap API — getSwapQuotes(), getSwapQuote(), getSwapProviders(), logSwapFailure()
useSwapQuotesParallel	Fetches swap quotes for multiple providers in parallel
useSwapPageLogic	Shared page logic for collateral/debt swap pages
useSwapCollateralOptions	Available collateral assets for swapping
useSwapDebtOptions	Available debt assets for swapping
useMultiplyCollateralOptions	Collateral options for multiply/leverage
useSlippage	Slippage setting with localStorage persistence
useEulerOperations/	Transaction builders: vault.ts (deposit/withdraw/borrow/repay primitives), swaps/ (cross-asset, same-asset, supply-borrow), repay.ts, allowance.ts, permit2.ts, execution.ts, helpers.ts
useTxPlanSimulation	Simulates tx plans via Tenderly
useTenderlySimulation	Lower-level Tenderly API wrapper
useEstimateFees	Gas estimation
Repay Composables (repay/)
Composable	Purpose
useWalletRepay	Repay from wallet balance
useSwapRepayQuotes	Quotes for swap-based repay
useSavingsRepay	Repay from savings/deposit positions
useRepaySwapDetails	Swap details for repay flows
useRepaySwapCore	Core repay-with-swap logic
useRepayHealthMetrics	Health factor impact of repay
useCollateralSwapRepay	Swap collateral then repay
Borrow/Position Composables
Composable	Purpose
borrow/useBorrowForm	Borrow form state and validation
borrow/useMultiplyForm	Leveraged multiply form
position/useCollateralForm	Collateral deposit form
useRepaySavingsOptions	Options for repaying from savings
Wallet & Auth
Composable	Purpose
useWallets	Wallet balances, token balances, isLoaded
useWagmi	Thin wrapper around @wagmi/vue — connected address, chain
useAddressScreen	Calls /api/screen-address to check if wallet is flagged (TRM)
useGeoBlock	Checks user's country against SANCTIONED_COUNTRIES and per-product block lists
useTermsOfUseGate	ToS signature gate (enabled when NUXT_PUBLIC_CONFIG_TOS_MD_URL is set)
useTosData	Fetches ToS markdown content
UX Utilities
Composable	Purpose
useTheme	Dark/light theme toggle with localStorage persistence; sets data-theme on <html>
useUserSettings	User preference persistence
useUrlQuerySync	Bidirectional sync of state to/from URL query params
useCustomFilters	Vault list custom filter state
useTokens	Token list and metadata
useTokenSymbolResolver	Resolves token symbol from address
useCustomTokenResolver	Custom token name overrides
useMerkl	Fetches Merkl reward campaigns
useBrevis	Fetches Brevis incentive data
usePermit2Preference	Permit2 on/off preference
useReactiveMap	Reactive Map wrapper utility
useVaultRegistry	(see above)
7. Pages & Routes
All pages are inside pages/. ssr: false so all rendering is client-side. URL query ?network=<chainId> is required on all routes (enforced by middleware/01.network.global.ts).
Route	File	Purpose
/	index.vue	Redirects to default enabled page (explore→earn→lend→borrow→portfolio)
/explore	explore/index.vue	Market explorer — vault groups by curator/product. Feature-flagged (ENABLE_EXPLORE_PAGE)
/explore/[market]	explore/[market].vue	Individual market detail
/earn	earn/index.vue	EulerEarn aggregated yield vaults list. Feature-flagged (ENABLE_EARN_PAGE)
/earn/[vault]	earn/[vault]/index.vue	EulerEarn vault detail
/earn/[vault]/[subAccount]/withdraw	earn/[vault]/[subAccount]/withdraw.vue	Earn vault withdrawal
/lend	lend/index.vue	Individual lending vaults list. Feature-flagged (ENABLE_LEND_PAGE)
/lend/[vault]	lend/[vault]/index.vue	Lending vault detail — deposit/withdraw
/lend/[vault]/[subAccount]/withdraw	Withdraw flow	
/lend/[vault]/[subAccount]/swap	Collateral swap from lend position	
/borrow	borrow/index.vue	Borrowing pairs list
/borrow/[collateral]/[borrow]	borrow/[collateral]/[borrow]/index.vue	Specific collateral+borrow pair detail
/position/[number]	position/[number]/index.vue	Active position overview (borrow position by subaccount index)
/position/[number]/supply	Supply more collateral	
/position/[number]/withdraw	Withdraw collateral	
/position/[number]/borrow	Borrow more	
/position/[number]/repay	Repay flow	
/position/[number]/multiply	Leverage multiply	
/position/[number]/borrow/swap	Swap debt asset	
/position/[number]/collateral/swap	Swap collateral asset	
/portfolio	portfolio.vue	Portfolio shell/layout
/portfolio (index)	portfolio/index.vue	Positions overview
/portfolio/saving	Deposit/savings positions	
/portfolio/rewards	Merkl + Brevis rewards	
/onboarding	onboarding.vue	Onboarding flow (chain setup, wallet connect)
/ui	ui.vue	Internal UI component playground/storybook
8. Components
base/ — Layout Primitives
Component	Purpose
BasePageHeader	Page-level header with title/subtitle
BaseModalWrapper	Generic modal container
BaseLoadingBar	Top-of-page loading bar
BaseLoadableContent	Skeleton/loading state wrapper
BaseBackButton	Back navigation button
BaseAvatar	Generic avatar/icon circle
layout/ — App Shell
Component	Purpose
TheHeader	Top navigation bar with wallet connect, chain selector, theme toggle
TheMenu	Bottom navigation bar (mobile) / side nav — Portfolio, Explore, Earn, Lend, Borrow
ui/ — Headless UI Primitives (SCSS-only, no Tailwind)
UiButton, UiInput, UiSelect, UiSelectModal, UiCheckbox, UiRadio, UiSwitch, UiRange, UiTabs, UiTab, UiModal, UiModals, UiToast, UiToastContainer, UiLoader, UiIcon, UiProgress, UiRadialProgress, UiFootnote, UiFootnoteModal, UiCustomFilterChips, UiCustomFilterModal
UI sub-items:
ui/composables/useToast.ts — Toast notification system
ui/composables/useModal.ts — Modal open/close management
ui/directives/text-fit.ts — Custom Vue directive that auto-scales text to fit container
entities/vault/ — Vault List & Detail Components
Discovery: DiscoveryMarketMatrix, DiscoveryMarketGraph, DiscoveryMarketCard, DiscoveryMarketAccordion — explore page market visualization
Overview modals: VaultOverview, VaultOverviewPair, VaultOverviewEarn, and sub-blocks (Stats, RiskParameters, OracleAdapters, IRM, Addresses) — "Info" modal for vault details
Securitize-specific: SecuritizeVaultOverview, SecuritizeVaultItem, SecuritizeVaultOverviewPair
Form: VaultForm, VaultFormSubmit, VaultFormInfoBlock, VaultFormInfoButton, SummaryRow, SummaryValue, SummaryPriceValue — deposit/borrow form UI
List items: VaultItem (lend), VaultBorrowItem (borrow), VaultEarnItem (earn)
Lists: VaultsList, VaultsBorrowList, VaultsEarnList
Metadata chips: VaultTypeChip, VaultLabelsAndAssets, VaultDisplayName, VaultPoints, VaultWarningIcon, VaultWarningBanner
Modals: VaultSupplyApyModal, VaultBorrowApyModal, VaultNetApyModal, VaultNetApyPairModal, VaultMaxRoeModal, VaultPointsModal, VaultSortTypeModal, ChooseCollateralModal, VaultUnverifiedDisclaimerModal
Controls: VaultSortButton
entities/portfolio/
PortfolioList, PortfolioBorrowItem, PortfolioEarnItem, PortfolioSavingItem, PortfolioRewardItem, PortfolioBrevisRewardItem
entities/operation/
OperationStepsList, OperationReviewModal — multi-step transaction confirmation UI
AcknowledgeTermsModal — ToS gate before operations
entities/swap/
SwapRouteSelector — swap provider/route selection
SlippageSettings, SlippageSettingsModal — slippage configuration
entities/asset/
AssetInput — token amount input with balance display
AssetAvatar — token icon with chain badge
SwapTokenSelector — token picker for swap flows
entities/wallet/
WalletInactiveDisclaimer, WalletDisconnectModal, Permit2Settings
entities/chains/
SelectChainModal — chain switcher modal
entities/security/
BlockedAddressModal — shown when wallet is flagged by TRM
entities/reward/
RewardUnlockList, RewardUnlockItem, RewardUnlockConfirmModal — rEUL unlock flow
entities/settings/
SettingsModal — slippage, permit2, theme preferences
9. Plugins
File	Order	Purpose
node.ts	—	Polyfills globalThis.Buffer for browser (required by viem/web3 libs)
00.wagmi.ts	First	Sets up Wagmi + Reown AppKit. Reads enabledChainIds from useChainConfig(), maps to @reown/appkit/networks. Creates WagmiAdapter, calls createAppKit(). Throws if no chains configured
01.query.ts	Second	Installs @tanstack/vue-query with a fresh QueryClient
directives.ts	—	Registers v-text-fit custom directive globally
theme.client.ts	Client-only	Reads themeHue from entities/custom.ts, sets --brand-hue CSS variable on <html>
10. Middleware
Client Route Middleware (middleware/)
File	Purpose
01.network.global.ts	Runs on every navigation. Ensures ?network=<chainId> is always present in the URL. Reads from: query param → localStorage chainId → current wagmi chainId → fallback 1. Redirects to inject if missing
ensure-vault.global.ts	On routes with [vault] param, validates the vault address is checksummed and the vault can be loaded. If not found, shows toast + redirects to default page. Also handles chain-switch re-validation
Server Middleware (server/middleware/)
File	Purpose
security-headers.ts	Sets X-Frame-Options: DENY, X-Content-Type-Options: nosniff, Referrer-Policy, Permissions-Policy, HSTS (non-dev only)
geo-gate.ts	Blocks /api/* requests from sanctioned countries (reads x-country-code from Cloudflare header). Logs VPN/proxy flags but doesn't block
cors.ts	CORS handling for /api/*. In dev, auto-allows localhost:3000–3003. In prod, allows CORS_ALLOWED_ORIGINS or falls back to NUXT_PUBLIC_APP_URL
body-limit.ts	Limits request body size for /api/* to prevent large payload attacks
11. Server API Routes
Route	File	Purpose
POST /api/rpc/[chainId]	api/rpc/[chainId].ts	RPC proxy. Validates JSON-RPC 2.0 format. Whitelist of 17 allowed methods. Batch support (max 100). Rate limit: 2000 req/min. 30s upstream timeout. Resolves RPC_URL_HTTP_<chainId> server-side (never exposed to client)
POST /api/screen-address	api/screen-address.post.ts	Wallet screening via TRM API. Proxies to WALLET_SCREENING_URI. Rate limit: 100/min. Fail-open (returns false on error/timeout)
POST /api/tenderly/simulate	api/tenderly/simulate.post.ts	Proxies transaction simulation to Tenderly
GET /api/tenderly/status	api/tenderly/status.get.ts	Returns whether Tenderly simulation is configured
Server Plugins (server/plugins/)
File	Purpose
app-config.ts	Reads APP_TITLE, APP_DESCRIPTION, API URLs from process.env at startup. Injects window.__APP_CONFIG__ = {...} into HTML head. Also patches <title>, og:title, twitter:title, description meta tags in the HTML
chain-config.ts	Scans RPC_URL_HTTP_* and NUXT_PUBLIC_SUBGRAPH_URI_* env vars. Injects window.__CHAIN_CONFIG__ = {enabledChainIds, subgraphUris} into HTML head
csp.ts	Sets Content-Security-Policy header with appropriate connect-src allowlist (Euler APIs, Goldsky, GitHub raw, Pyth, Merkl, etc.) + CSP_EXTRA_CONNECT_SRC override
12. Services
File	Purpose
pricing/priceProvider.ts	High-level price resolution: getAssetUsdValueOrZero(), getCollateralUsdPrice(). Abstracts oracle on-chain prices + backend price API
pricing/backendClient.ts	HTTP client for Euler Price API
pricing/index.ts	Re-exports
intrinsicApy/defillamaProvider.ts	Fetches pool APY from DefiLlama Yields API by poolId
intrinsicApy/pendleProvider.ts	Fetches PT implied yield from Pendle API by pendleMarket
vpn.ts	Checks VPN status from headers
trm.ts	TRM wallet screening client
country.ts	Country detection utilities
13. Utils (29 files)
File	Purpose
vault-utils.ts	Vault-specific utilities (formatting, calculations)
tx-errors.ts	Parses revert errors from transactions
time-utils.ts	Time formatting (luxon wrappers)
swapRouteItems.ts	Formats swap route steps for display
swapQuotes.ts	Swap quote comparison/ranking
swap-validation.ts	Validates swap input parameters
subgraph.ts	GraphQL queries to Goldsky subgraph — fetchAccountPositions() returns all borrow + deposit entries for a wallet
string-utils.ts	String formatting (truncation, address shortening)
stepDecoding.ts	Decodes EVC batch step calldata for display in OperationStepsList
safe-assign.ts	Deep-merges reactive objects without breaking reactivity
repayUtils.ts	Repay flow calculations
race-guard.ts	createRaceGuard() — generation counter utility for cancelling stale async operations
pyth.ts	executeLensWithPythSimulation() — fetches fresh Pyth prices, encodes update calldata, simulates lens call with state override
public-client.ts	Creates viem publicClient from RPC URL
normalizeAddress.ts	Address normalization (checksummed, lowercase)
multicall.ts	batchLensCalls() — batches multiple lens contract reads via EVM multicall
leverage.ts	Leverage/multiply calculations
fixed-point.ts	FixedPoint class — arbitrary-precision fixed-point arithmetic for financial calculations
evc-converter.ts	Converts between EVC sub-account indices and addresses
eulerLabelsUtils.ts	normalizeProducts(), normalizeEntities(), getProductByVault(), getEntitiesByVault(), getPointsByVault(), isVaultFeatured(), applyVaultOverrides() — all label data transformation logic
eulerLabelsState.ts	Reactive state store for labels data — products, entities, points, verifiedVaultAddresses, oracleAdapters as Vue reactive objects shared across composables
errorHandling.ts	logWarn(), isAbortError(), error normalization
discoveryCalculations.ts	Market discovery TVL/APY calculations
crypto-utils.ts	valueToNano() and other crypto math utilities
collateralOptions.ts	Computes available collateral options for borrow pairs
collateral-cleanup.ts	Handles collateral position cleanup on repay
block-explorer.ts	Generates block explorer URLs per chain
autoLink.ts	Converts URLs in text to <a> tags
accountPositionHelpers.ts	Lens result parsing helpers — LensAccountInfo, LensVaultAccountInfo, toBigInt(), hasPythOracles(), resolvePositionCollaterals()
14. Types
File	Purpose
types/index.ts	Shared TS types not specific to any domain
15. Public Assets
public/├── favicons/favicon.svg├── entities/              ← 40+ entity SVG logos (alphagrowth.svg present; cork.svg absent)│   ├── alphagrowth.svg│   ├── euler.svg│   └── ... (gauntlet, mev-capital, resolv, etc.)└── oracles/               ← 15 oracle provider logos (chainlink, pyth, chronicle, etc.)
Fonts are in public/fonts/ (referenced by fonts.scss but not in glob results).
16. Documentation (docs/)
12 markdown files covering: README, architecture, project-structure, getting-started, development-guide, data-flow, pricing-system, portfolio-logic, vault-labels-and-verification, transaction-building, pyth-oracle-handling, intrinsic-apy, geo-blocking.
17. Notable Architectural Patterns
Config injection pattern: Server plugins inject window.__APP_CONFIG__ and window.__CHAIN_CONFIG__ at request time (picking up Doppler-injected env vars). Client composables read these synchronously before Nuxt runtimeConfig fallback. This lets Docker image env vars take effect without a rebuild.
Vault discovery flow: useEulerLabels → verifiedVaultAddresses[] → useVaults.loadVaults() → fetchVaults() (fetcher.ts) → useVaultRegistry. Nothing outside verifiedVaultAddresses can appear in the UI.
Generation counters for stale data: Both useVaults (vault loading) and useAccountPositions (position loading) use generation counters (loadGeneration, createRaceGuard) that increment on chain switch. Any async operation that finds a stale generation silently discards its results.
Pyth oracle simulation: For vaults using Pyth price feeds, the app fetches fresh signed price updates from Hermes, then runs the lens call as a state-override simulation (injecting price data) rather than a direct eth_call. This happens transparently in useAccountPositions and useVaults.
Labels repo as the single source of vault truth: The GitHub products.json file is the only thing that makes a vault visible. Zero products = zero vaults shown. This enables the AG white-label pattern — point at a different labels repo and the UI shows only that partner's vaults.