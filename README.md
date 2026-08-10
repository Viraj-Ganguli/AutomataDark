# AutomataDark


This repo currently contains two things:

1. **A throwaway "club events" CRUD app** (`client/` + `server/`) — a
   conventional, well-layered React + Express + Postgres app that serves as
   the guinea pig the agent workflow operates on. It's disposable; don't get
   attached to it.
2. **An autonomous build pipeline** (`.factory/`, `.github/workflows/orchestrator.yml`,
   `.github/ISSUE_TEMPLATE/nlspec.md`, `.github/PULL_REQUEST_TEMPLATE/gatekeeper.md`) —
   a GitHub Actions workflow that takes a human-filed NLSpec issue and drives
   it through QA → Coder → Review → PR using Claude Code in CI, with a
   configurable merge gate. See [Agent orchestrator](#agent-orchestrator)
   below.

## App architecture

```
client/   React (Vite) frontend
server/   Express + Node API, layered as routes -> services -> data-access
tests/    tests/golden/ (hand-written harness, see below) + per-feature
          suites the QA agent adds under tests/<feature>/
```

See `server/src/` for the layering convention: routes parse HTTP and call
services; services hold validation/business logic; data-access modules hold
SQL only.

## Prerequisites

- Node.js 18+
- Docker (for local Postgres via `docker-compose.yml`)

## Quickstart

```bash
# 1. Install dependencies for both client and server
npm run install:all

# 2. Start Postgres
npm run db:up

# 3. Copy env files and adjust if needed
cp .env.example .env
cp server/.env.example server/.env

# 4. Run migrations
npm run migrate

# 5. Seed an admin user + sample events
npm run seed

# 6. Start both the API and the frontend dev server
npm run dev
```

- Frontend: http://localhost:5173 (Vite dev server, proxies `/api` to the backend)
- Backend: http://localhost:4000

The seed script creates an admin account using `SEED_ADMIN_EMAIL` /
`SEED_ADMIN_PASSWORD` from `server/.env` (defaults: `admin@example.com` /
`admin123`). Log in with those credentials to access `/admin`.

## Useful scripts (run from repo root)

| Script              | Description                                  |
| ------------------- | --------------------------------------------- |
| `npm run dev`        | Run client + server together                 |
| `npm run db:up`      | Start Postgres via docker-compose             |
| `npm run db:down`    | Stop Postgres                                 |
| `npm run migrate`    | Run pending database migrations               |
| `npm run migrate:down` | Roll back the most recent migration         |
| `npm run seed`       | Seed an admin user + sample events            |
| `npm test`           | Run the server test suite (Jest)              |

## Tests

`npm test` runs Jest, configured via `server/jest.config.js`, which looks for
tests under both `server/src` and the repo-level `tests/` directory
(`maxWorkers: 1`, since all suites share one Postgres database).

`tests/golden/` is a hand-written, **immutable** shared harness (`app.js`,
`db.js`, `auth.js`, `fixtures.js` — see `tests/golden/README.md` for the full
exported interface: `createTestApp()`, `resetDb()`, `seedAdmin()`/`seedUser()`,
`loginAs()`, and canonical fixtures). Every other suite under `tests/**`
imports these helpers instead of duplicating setup.

**No agent — QA, coder, or otherwise — may create, edit, or delete anything
under `tests/golden/`, for any reason.** This is enforced both by convention
(`CLAUDE.md`, `.factory/qa.nlspec.md`) and by the orchestrator's review job,
which fails the run if `tests/golden/**` appears in the diff vs `main`.

## Agent orchestrator

`.github/workflows/orchestrator.yml` drives a human-filed NLSpec issue
(`.github/ISSUE_TEMPLATE/nlspec.md`) through an autonomous pipeline:

```
issue labeled "build" (by a collaborator)
  or workflow_dispatch (issue_number, optional model override)
        │
        ▼
  guard ──▶ setup ──▶ qa ──▶ coder ──▶ review ──▶ pr
        (any failure) ──▶ report-failure (comments on the issue)
```

- **guard** — for label events, checks the label matches the configured
  trigger label and the user who applied it is a repo collaborator (so
  outside actors can't spend the API key or push code). For
  `workflow_dispatch`, always proceeds for the given `issue_number`.
- **setup** — creates (or reuses) branch `agent/issue-<n>-<slug>` and posts a
  "build started" comment on the issue.
- **qa** — Claude (per `.factory/qa.nlspec.md` + the issue body) writes
  failing tests under `tests/<feature>/`, importing the `tests/golden/`
  harness. A path-allowlist step fails the job if anything outside
  `tests/**` (excluding `tests/golden/**`) or `.github/workflows/**` was
  touched, and `npm test` must be **red** before continuing.
- **coder** — Claude (per `.factory/coder.nlspec.md`) edits `client/**` and
  `server/**`, iterating internally (`npm test` → fix → re-run) until the
  suite is **green**. A path-allowlist step fails the job if anything outside
  `client/**`/`server/**` was touched.
- **review** — Claude scores the cumulative diff vs `main` against every
  criterion in `.factory/rubric.json`, writing
  `.factory/review-result.json`; `.factory/scripts/score-rubric.js` computes
  the weighted pass/fail and posts the report as an issue comment. Also fails
  if `tests/golden/**` is in the diff.
- **pr** — opens a PR from the gatekeeper template
  (`.github/PULL_REQUEST_TEMPLATE/gatekeeper.md`) with the rubric score
  injected and linked to the issue. If `autoMerge` is `true` *and* the rubric
  passed, squash-merges immediately; otherwise leaves it for a human
  gatekeeper and comments accordingly.

### Triggering a run

- **Normal use**: as a repo collaborator, apply the configured label (default
  `build`) to an NLSpec issue.
- **Manual / one-off**: Actions tab → "Agent Orchestrator" → *Run workflow* →
  provide `issue_number` and (optionally) a `model` override for that single
  run.

### Configuration (`.factory/orchestrator.config.json`)

Human-maintained — agents are forbidden from editing `.factory/**`, so this
file is a safe place for orchestrator-only tuning:

| Key | Meaning |
| --- | --- |
| `label` | Issue label that triggers a run (default `"build"`). |
| `autoMerge` | If `true`, the `pr` job squash-merges automatically when the rubric passes. Default `false` (human-gated). |
| `qaMaxTurns` / `coderMaxTurns` / `reviewMaxTurns` | `--max-turns` passed to each stage's Claude invocation. |
| `model` | Default Claude model id for every stage (e.g. `claude-sonnet-4-6`). |
| `stageModels` | Optional per-stage overrides, e.g. `{"coder": "claude-opus-4-8"}`. Stages not listed fall back to `model`. |

**Plug-and-play models**: every stage's `--model` comes from this config (or
the `workflow_dispatch` `model` input). The workflow never hardcodes or
validates against a fixed model list — any valid Claude model id works with
no edits to the YAML.

### Model selection & rate limits

`anthropics/claude-code-action@v1` makes internal Haiku API calls (~3K
tokens/invocation) to drive its own tooling. These count against the same
"Claude Haiku Active" rate-limit bucket as your main model calls. On a
new/low-spend Anthropic account the hard limit is **10K input tokens/minute**
per model family. Using Haiku as the `model` in config means both the
action's internal calls and your 9K-token prompts compete for that same 10K
bucket — practically guaranteed 429s before Claude touches a file.

**Recommendation: use `claude-sonnet-4-6` as `model` on any new account.**
Sonnet calls go into the "Claude Sonnet Active" bucket; the action's internal
Haiku calls stay in the "Claude Haiku Active" bucket. Both stay under 10K/min
independently.

| Model | Works on new account | Approx. cost/run | Notes |
| --- | --- | --- | --- |
| `claude-sonnet-4-6` | ✅ yes | ~$0.05–0.35 | **Recommended default.** Fast, capable, separate rate bucket from action internals. |
| `claude-opus-4-8` | ✅ yes | ~$0.50–2.00 | Best quality; use `stageModels` to apply only to the coder stage. |
| `claude-haiku-4-5-20251001` | ⚠️ only if TPM ≥ 20K | ~$0.01–0.05 | Cheapest, but action's own Haiku overhead + your prompt exceeds the default 10K/min limit. |

Cost per run is proportional to `coderMaxTurns` — that is the most token-heavy
stage because it loops `npm test` → read → edit multiple times. Reducing
`coderMaxTurns` from 8 to 5–6 is the single biggest cost lever.

To use Haiku (or any model at lower cost) reliably, request a rate limit
increase at [console.anthropic.com/settings/limits](https://console.anthropic.com/settings/limits).
A Haiku limit of ≥ 20K input TPM is sufficient to clear the overhead.

**Per-stage override example** — heavy model for coding, light model for QA
and review:

```json
{
  "model": "claude-haiku-4-5-20251001",
  "stageModels": {
    "coder": "claude-sonnet-4-6"
  }
}
```

**One-off model override** — no config edit needed; use the `workflow_dispatch`
`model` input in the Actions tab to try a different model on a single run.

### One-time setup

1. Add the `ANTHROPIC_API_KEY` repo secret: `gh secret set ANTHROPIC_API_KEY`.
2. Create the trigger label (default `build`): `gh label create build`.
3. Settings → Actions → General → Workflow permissions: enable "Read and
   write permissions" and "Allow GitHub Actions to create and approve pull
   requests" (the `setup`/`qa`/`coder` jobs push commits and the `pr` job
   opens PRs).
4. **Validate the spine first**: manually dispatch
   `.github/workflows/spine-test.yml` once. It spins up the same Postgres
   service container, installs/migrates, has Claude make a one-line edit, and
   runs `npm test`. Confirm it's green and pushes a commit to a scratch
   `agent/spine-test-<run id>` branch, then delete that branch and the
   workflow file. This is a `workflow_dispatch`-only check — the first real
   orchestrator run via issue label exercises a different (issue-event) code
   path in `claude-code-action`, so treat that first labeled run as a
   confirm-on-first-use step too.
5. File an NLSpec issue (`.github/ISSUE_TEMPLATE/nlspec.md`) and apply the
   `build` label as a collaborator, or use `workflow_dispatch` as above.

### Known limits

- The `review` job's prompt (including the full diff vs `main`) is passed
  through a `$GITHUB_OUTPUT` heredoc, which has a ~1 MB ceiling. Fine at this
  lab's scale; very large diffs could exceed it.
- Each stage runs against a fresh Postgres service container with migrations
  applied — no seed data persists between jobs beyond what's in the repo.

## Factory scaffolding (`.factory/`, issue & PR templates)

`.factory/qa.nlspec.md` and `.factory/coder.nlspec.md` define the QA and coder
agents' roles, allowed/forbidden paths, and workflow — these are the prompts
the orchestrator feeds Claude. `.factory/rubric.json` defines the review bar;
`.factory/ambiguity-checklist.md` is where agents record open questions
instead of guessing. See the root `CLAUDE.md` for the full authority rules.

---

## Adapting factory-lab for your own project

The pipeline (orchestrator workflow, agent NLSpecs, rubric, issue/PR
templates) is fully portable. The app (`client/`, `server/`, `tests/golden/`,
`CLAUDE.md`) is factory-lab-specific and gets replaced with your own project.

### Quickest path — GitHub template

factory-lab is configured as a GitHub Template Repository. Create a new repo
from it in one command:

```bash
gh repo create my-project --template virajganguli/factory-lab --private
cd my-project
```

This gives you a clean copy of everything with no git history. Then follow the
customization checklist below.

Alternatively, copy only the factory layer into an existing repo:

```bash
# Run from inside your existing project repo
FACTORY=https://github.com/virajganguli/factory-lab

# Copy the portable factory files
gh repo clone virajganguli/factory-lab /tmp/factory-lab-src
cp -r /tmp/factory-lab-src/.factory              .
cp -r /tmp/factory-lab-src/.github/workflows/orchestrator.yml  .github/workflows/
cp -r /tmp/factory-lab-src/.github/ISSUE_TEMPLATE .github/
cp -r /tmp/factory-lab-src/.github/PULL_REQUEST_TEMPLATE .github/
rm -rf /tmp/factory-lab-src
```

### What to keep vs. what to replace

| Layer | Keep as-is | Replace / adapt |
| --- | --- | --- |
| `.github/workflows/orchestrator.yml` | ✅ keep | Only edit if your test command differs from `npm test` — change the two `npm test` invocations and the `npm run install:all` / `npm run migrate` setup steps. |
| `.factory/orchestrator.config.json` | ✅ keep | Update `model`, `autoMerge`, turn limits to taste. |
| `.factory/qa.nlspec.md` | ✅ keep structure | Update the **Allowed paths** / **Forbidden paths** sections for your repo layout, and the test-layer guidance (Supertest, pytest, etc.) for your stack. |
| `.factory/coder.nlspec.md` | ✅ keep structure | Update **Allowed paths** and the step-3 layering bullet points (`routes→services→data-access` etc.) to match your app's architecture. |
| `.factory/rubric.json` | ✅ keep | Adjust criterion weights/descriptions to match your quality bar. |
| `.github/ISSUE_TEMPLATE/nlspec.md` | ✅ keep as-is | No changes needed. |
| `.github/PULL_REQUEST_TEMPLATE/gatekeeper.md` | ✅ keep as-is | No changes needed. |
| `CLAUDE.md` | 🔄 replace | Rewrite to describe your project's architecture, layering conventions, and the one hard rule: never touch `tests/golden/`. |
| `tests/golden/` | 🔄 replace | Write a new shared test harness for your app (your framework's equivalent of `createTestApp()`, `resetDb()`, fixtures). This is the one human-authored bootstrap the QA agent imports. |
| `client/`, `server/` | 🔄 replace | Your application source. |

### Customization checklist

After copying the factory files into your project:

- [ ] **Rewrite `CLAUDE.md`** — describe your project's layering, conventions,
  and the `tests/golden/` immutability rule. The agents use this as their
  primary style guide.
- [ ] **Update path lists in the NLSpecs** — `qa.nlspec.md` lists what the QA
  agent may write (`tests/**`); `coder.nlspec.md` lists what the coder may
  touch (`client/**`, `server/**`, or equivalent for your stack). Edit both to
  reflect your repo layout.
- [ ] **Update the test layer guidance** — the QA NLSpec references Supertest
  and the Express `app` export. Replace with your framework's integration-test
  idiom (e.g. pytest + httpx for FastAPI, RSpec + rack-test for Rails).
- [ ] **Write `tests/golden/`** — at minimum: a test-app factory, a DB reset
  helper, and a fixtures file. This is the shared harness every QA-generated
  suite will import.
- [ ] **Adapt the orchestrator workflow** — if your test command isn't
  `npm test`, find the two `npm test` invocations and the
  `npm run install:all` / `npm run migrate` lines and replace them. The
  Postgres service container block can be removed entirely for non-Postgres
  projects.
- [ ] **One-time setup** (same as factory-lab's): add `ANTHROPIC_API_KEY`
  secret, create the `build` label, enable read/write workflow permissions.

### Non-Node stacks

The orchestrator is language-agnostic — it just runs shell commands in a
Linux runner. Typical substitutions:

| factory-lab (Node/Express/Postgres) | Python/FastAPI/Postgres | Ruby/Rails |
| --- | --- | --- |
| `npm run install:all` | `pip install -r requirements.txt` | `bundle install` |
| `npm run migrate` | `alembic upgrade head` | `rails db:migrate` |
| `npm test` | `pytest` | `rails test` or `rspec` |
| `postgres:16-alpine` service | same | same |

Everything else (branch management, git path enforcement, review scoring,
PR creation) is identical regardless of stack.
