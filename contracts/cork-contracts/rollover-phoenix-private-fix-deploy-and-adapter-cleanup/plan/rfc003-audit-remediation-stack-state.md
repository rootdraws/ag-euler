# RFC 003 Audit Remediation — Stack State

> Single source of truth across compaction and resume. Orchestrator (`deliver-stacked-prs-cork`) writes this after every sub-step. On conflict with TaskCreate dashboard, this file wins.

## Metadata

- **Project slug:** `rfc003-audit-remediation`
- **Plan path:** `plan/rfc003-audit-remediation-plan.md`
- **Test spec path:** `plan/rfc003-audit-remediation-test-spec.md`
- **Plan amendment commit:** `959bb4a` (on `main`, pushed)
- **Starting base:** `main` @ `959bb4abd1e9810934d1fa641b02b9a81ad115b8`
- **Run ID:** `rfc003x`
- **Pipeline dir:** `/tmp/cork-pipeline/deliver-stacked-prs-cork/rfc003x/`
- **Target issues:** 21 (#37, #41, #42, #43, #44, #45, #46, #47, #48, #49, #53, #54, #55, #56, #57, #58, #60, #61, #63, #64, #39)
- **Out of scope:** #35, #40, #59, #62
- **Already closed by PR #65 (dropped from scope):** #36, #38, #50, #51, #52
- **Gate type (all PRs):** `green`
- **Permissions:** `{push: verified_dry_run, force_push: unknown}`

## Current position

- **current_pr:** `1`
- **current_step:** `1f`
- **status:** `fixing`
- **agent_runs:** `4`
- **token_approx_k:** `~4`

## Stack topology

| # | Branch | Base | Closes | Tasks | Status |
|---|---|---|---|---|---|
| 1 | `fix/as19-as21-ingress-gates` | `main` | #37, #45 | 1–4 | pending |
| 2 | `fix/compute-order-digest-identity` | `fix/as19-as21-ingress-gates` | #41 | 5–7 | pending |
| 3 | `fix/terminal-and-settler-symmetry` | `fix/compute-order-digest-identity` | #42, #53 | 8–10 | pending |
| 4 | `refactor/filler-pair-split` | `fix/terminal-and-settler-symmetry` | #43 | 11–15 | pending |
| 5 | `fix/token-quirk-defence` | `refactor/filler-pair-split` | #39 | 16–19 | pending |
| 6 | `feat/stranded-value-rescue` | `fix/token-quirk-defence` | #44 | 20–23 | pending |
| 7 | `fix/seam-as10-phase0` | `feat/stranded-value-rescue` | #58 | 24–27 | pending |
| 8 | `fix/seam-cei-premium-leg` | `fix/seam-as10-phase0` | #60 | 28–30 | pending |
| 9 | `feat/seam-state-parity-assertion` | `fix/seam-cei-premium-leg` | #61, #63 | 31–35 | pending |
| 10 | `feat/order-attribution-event` | `feat/seam-state-parity-assertion` | #47, #46 | 36–39 | pending |
| 11 | `docs/filler-trust-boundary` | `feat/order-attribution-event` | #49, #64 | 40–42 | pending |
| 12 | `fix/deploy-and-adapter-cleanup` | `docs/filler-trust-boundary` | #54, #55, #56, #57 | 43–46 | pending |
| 13 | `docs/cork-knowledge-rfc-amendment` (cross-repo, non-blocking) | `cork-knowledge:rfc/uw-intent-rollover-003` | #41 (RFC side), #48 | 47–50 | pending |

## Completed PRs

_None yet._

## Per-PR log

### PR 1 — `fix/as19-as21-ingress-gates`

- **Step:** `1e` (cycle-2 review dispatching)
- **Cycles:** 1 complete, 2 in progress
- **Commit SHAs:** `ac69266`, `8cd5977` (head = `8cd5977`)
- **PR URL:** https://github.com/Cork-Technology/rollover-phoenix-private/pull/66
- **Gate result cycle 1:** all PASS (687/687 tests, 52/52 invariants, Exact 19,633; Partial 21,537; limit 24,576)
- **Cycle-1 review:** 2 Blockers, 5 Concerns, 4 Nitpicks, verdict changes-requested
- **Cycle-1 fix:** B1, B2, C2, C3, C4, plan amendment (§1g.5 ENDORSE, AS-20/22 split), nitpicks — all applied in `8cd5977`
- **Deferred to PR 2:** C5 (5 digest-identity sketches — will be flipped by PR 2 digest expansion)
- **Impl summary:** `/tmp/cork-pipeline/deliver-stacked-prs-cork/rfc003x/pr-1-impl-summary.md`
- **Cycle-1 review:** `/tmp/cork-pipeline/deliver-stacked-prs-cork/rfc003x/pr-1-review-cycle1.md`
- **Cycle-1 fix summary:** `/tmp/cork-pipeline/deliver-stacked-prs-cork/rfc003x/pr-1-fix-cycle1-summary.md`

## Deferred concerns

_None yet._

## Trivial fixes applied

_None yet._

## Plan amendments during run

| PR | Commit | Reviewer verdict | Section | Reason |
|---|---|---|---|---|
| 1 | _pending_ | ENDORSE (C1, cycle 1) | PR 1 Task 2 — AS-20 split | Reviewer cited RFC §6.2 modulo check; user chose option (c) — implement both gates as distinct. AS-20 = RFC's modulo (DecimalTruncates). AS-22 = plan's original residual (ResidualTruncates). Amendment lands on-branch in `fix/as19-as21-ingress-gates`. |

## Tool-layer handoffs

_None yet._

## Resume notes

If orchestrator session restarts, read this file first. Jump to `current_pr` + `current_step`. Run pre-flight (skill §0.2) before any subagent dispatch. Never overwrite this file without reading it first.
