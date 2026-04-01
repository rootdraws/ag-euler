# Development Guide

This guide covers the concrete steps and scripts needed to work on this repository.

## Prerequisites

- Node.js 18+
- npm (or yarn/pnpm if you prefer)

## Install and run

```bash
npm install
npm run dev
```

Available scripts (from `package.json`):

- `dev` – start Nuxt in development
- `build` – production build
- `preview` – preview the production build
- `generate` – generate static site
- `lint` – run ESLint on the entire project
- `lint:fix` – run ESLint with auto-fix
- `typecheck` – run Nuxt type checking (`nuxt typecheck`)
- `postinstall` – `nuxt prepare && simple-git-hooks`

## Linting & Pre-commit Hooks

The project uses a production-grade ESLint configuration (`eslint.config.mjs`) with `simple-git-hooks` and `lint-staged` for pre-commit enforcement:

- **Pre-commit hook**: Automatically runs `lint-staged` on staged files before each commit
- **Lint-staged**: Runs `eslint --fix` on staged `.ts`, `.vue`, and `.mjs` files
- **ESLint config**: Flat config format with Vue + TypeScript rules

Run linting manually:

```bash
npm run lint          # Check for lint errors
npm run lint:fix      # Auto-fix lint errors
npm run typecheck     # Type-check the project
```

## End-to-End Testing

The project includes [Playwright](https://playwright.dev/) for E2E testing:

```bash
npx playwright test                # Run all E2E tests
npx playwright test --ui           # Run with interactive UI
npx playwright show-report         # Show last test report
```

## Project configuration

- Nuxt config: `nuxt.config.ts`
  - Modules, SSR disabled, CSS, SVG sprite, runtimeConfig, dev server HTTPS, Vite SCSS additionalData.
- TypeScript config: `tsconfig.json`
- ESLint config: `eslint.config.mjs` (flat config format)
- Playwright config: `playwright.config.ts`
- Git hooks: `simple-git-hooks` + `lint-staged` (configured in `package.json`)

## Environment variables

Configuration is split into two mechanisms:

1. **`useEnvConfig()`** (`composables/useEnvConfig.ts`) — API URLs, Pyth, Reown, wallet screening. Injected at runtime via `server/plugins/app-config.ts` into `window.__APP_CONFIG__`. Accepts both plain names (`EULER_API_URL`) and Doppler-prefixed names (`NUXT_PUBLIC_EULER_API_URL`).

2. **Nuxt `runtimeConfig`** (`useDeployConfig()`) — branding, social links, feature flags. Set via `NUXT_PUBLIC_CONFIG_*` env vars.

3. **Chain config** (`useChainConfig()`) — derived dynamically from `RPC_URL_HTTP_<chainId>` env vars at server startup, injected via `window.__CHAIN_CONFIG__`.

See the [README](../README.md) for the full env var reference.

Dev HTTPS: `HTTPS_KEY`, `HTTPS_CERT` (optional).

## Code layout (high level)

- App entry: `app.vue`
- Pages: `pages/*`
- Components: `components/*`
- Composables: `composables/*`
- Entities (types/helpers/ABI/addresses): `entities/*`
- Public assets: `public/*`
- Styles: `assets/styles/*`

## Conventions

- Vue 3 + Nuxt 3 with Composition API.
- Composables named as `useXxx.ts` and colocated in `composables/`.
- Prefer referencing on-chain data via helpers in `entities/` and state via `composables/`.

## Troubleshooting

- If the app fails to start, ensure Node 18+ and reinstall deps.
- If blockchain calls fail, verify `RPC_URL_HTTP_<chainId>` env vars and check that matching `NUXT_PUBLIC_SUBGRAPH_URI_<chainId>` is set.
- If token logos don't load, verify `EULER_API_URL` (or `NUXT_PUBLIC_EULER_API_URL`) is set.

---

_Next: Explore the [Data Flow and Integrations](./data-flow-and-integrations.md) for protocols, APIs, and SDKs used._
