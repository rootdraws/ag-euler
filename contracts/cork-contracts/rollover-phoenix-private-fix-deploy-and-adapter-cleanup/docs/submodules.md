# Submodule pinning policy

This repo's `lib/` contains:

| Submodule | Role | Pin strategy |
|---|---|---|
| `lib/forge-std` | Foundry std | rollover-owned; bumped independently |
| `lib/openzeppelin-contracts` | OZ contracts | rollover-owned; bumped independently |
| `lib/cellar` | Cork cellar contracts + test helpers | pinned; cellar bumps ship as standalone PRs |

## Cellar submodule bumps

Cellar bumps land as a standalone PR titled `chore(deps): bump lib/cellar to <short-SHA>`. CI caches key on the pinned SHA. Bumps are classified in the PR body as `rollover-affecting` or `rollover-neutral` per `plan/implementation-plan.md` → "Mid-plan submodule bump procedure".

## Current pins

| Submodule | SHA | Pinned on |
|---|---|---|
| `lib/cellar` | `b8c8b9c565c1ec6a0613dbe54d1b3794ec1c30d2` | 2026-04-17 |
| `lib/openzeppelin-contracts` | `5fd1781b1454fd1ef8e722282f86f9293cacf256` (v5.6.1) | 2026-04-16 |
| `lib/forge-std` | `0844d7e1fc5e60d77b68e469bff60265f236c398` (v1.15.0) | — |
