# AutomataDark

An autonomous build pipeline for **any** codebase. A human files an NLSpec
issue; GitHub Actions drives it through **QA → Coder → Review → PR**, with
any harness (Claude Code, opencode, Codex) and any
[OpenRouter](https://openrouter.ai/models) model on each stage.

- **Stack-agnostic.** The factory assumes no language, package manager, or
  test framework. Your product's setup and test commands live in one config
  block ([Plug in your product](#plug-in-your-product)); the QA gate reads
  JUnit XML, which pytest, Jest, Go, Rust, JVM, Ruby, and .NET runners can
  all write.
- **Gates written and proved in Lean 4.** Every pass/fail decision the
  pipeline makes about an agent — what it may write, whether its tests are
  red for the right reason, whether the review passes — is made by one Lean
  binary whose decision functions are machine-checked
  ([Verified gates](#verified-gates-lean-4)). The CI build fails if any
  proof breaks.
- **Factory only.** This repository holds just the factory (`.factory/`,
  `.github/`). The product it builds lives in your repo, next to a copy of
  it. **To get started, run `.factory/factory.sh setup`.**

## Factory vs. product

A repo using the factory has three zones, and a build never mixes them:

```mermaid
flowchart LR
    subgraph F["Factory: how things get built<br/>(humans edit, agents never do)"]
        F1[".factory/<br/>specs, rubric, config,<br/>Lean gates, scripts"]
        F2[".github/<br/>workflows, templates, actions"]
    end
    subgraph P["Product: what gets built<br/>(the only thing in the PR)"]
        P1["paths.qa (QA agent)"]
        P2["paths.coder (coder agent)"]
        P3["paths.protected<br/>(humans only)"]
    end
    subgraph R["Run record: what happened<br/>(never committed)"]
        R1["prompts, raw agent logs"]
        R2["open questions, rubric scores"]
    end
    F -- "drives agents that change" --> P
    F -- "writes per build" --> R
    R -- "summarized in" --> PR(["Pull request"])
    P -- "diff becomes" --> PR
```

| Zone | Lives in | Who changes it | Where it ends up |
| --- | --- | --- | --- |
| **Factory** | `.factory/`, `.github/` | You | `main`, through normal human PRs |
| **Product** | Whatever `paths` in `.factory/orchestrator.config.json` names (defaults: `tests/` for QA, `src/` for the coder, `tests/golden/` protected) | QA agent → `paths.qa`, coder agent → `paths.coder`, nobody → `paths.protected` | The agent's PR, and nothing else is in it |
| **Run record** | `run-qa` / `run-coder` / `run-review` artifacts on each workflow run | The workflow | Artifacts (90-day retention), the PR's "Factory run" and "Ambiguities" sections, issue comments |

The product boundary is declared once, in the `paths` block of the config.
That same list is injected into each agent's prompt as its write scope, and
the Lean path gate enforces it after every agent stage. Agents write open
questions to `.factory/ambiguity-checklist.md`. The workflow moves those
lines into the run record and restores the file before committing, so the
checklist never changes on an agent branch and parallel builds can't
conflict on it.

This repository has no product of its own: it is the factory, kept as a
template. Development happened against a throwaway guinea-pig app that is
deliberately not tracked. To run the orchestrator, put the factory in a repo
that has a product ([Adapting](#adapting-automatadark-for-your-own-project)).

## Plug in your product

Everything product-specific is in the `product` block of
`.factory/orchestrator.config.json`, run by `.factory/scripts/product.sh`:

```json
"product": {
  "setup":      "pip install -r requirements.txt && docker compose up -d db && alembic upgrade head",
  "test":       "pytest",
  "testReport": "pytest -o junit_family=xunit1 --junitxml=\"$FACTORY_JUNIT\"",
  "env":        { "DATABASE_URL": "postgresql://app:app@localhost:5432/app" }
}
```

| Key | What it does |
| --- | --- |
| `setup` | Runs before every agent stage: toolchain, dependencies, services (Docker is available on the runner, so `docker compose up -d` works for a database), migrations. |
| `test` | The suite. Its exit status is the verdict for the coder and review stages. Keep it one command with no commas: it also becomes the agents' shell permission (`Bash(pytest*)`). |
| `testReport` | The same suite, writing a JUnit XML report to `$FACTORY_JUNIT`. `factory red` reads it to decide whether QA's tests are red for the right reason (`strictRedCheck`). Each test case needs a file attribute (see below). |
| `env` | Extra environment variables for every product command. |

| Stack | `test` | `testReport` |
| --- | --- | --- |
| Python / pytest | `pytest` | `pytest -o junit_family=xunit1 --junitxml="$FACTORY_JUNIT"` |
| Node / Jest | `npx jest` | `JEST_JUNIT_OUTPUT_FILE="$FACTORY_JUNIT" JEST_JUNIT_ADD_FILE_ATTRIBUTE=true JEST_JUNIT_REPORT_TEST_SUITE_ERRORS=true npx jest --reporters=default --reporters=jest-junit` |
| Go | `go test ./...` | `gotestsum --junitfile "$FACTORY_JUNIT" -- ./...` |
| Rust | `cargo nextest run` | `cargo nextest run --profile ci; s=$?; cp target/nextest/ci/junit.xml "$FACTORY_JUNIT"; exit $s` (with `[profile.ci.junit]` enabled) |
| JVM / Ruby / .NET | your usual command | Surefire, `rspec_junit_formatter`, or `JunitXml.TestLogger`, writing to `$FACTORY_JUNIT` |

Notes:

- **File attributes.** The red check has to know which file each test case is
  in, so it can tell QA's new tests from pre-existing ones. A report without
  that information fails closed, with a message saying how to enable it.
  pytest's default `xunit2` format omits it; use `-o junit_family=xunit1`.
- **Ignore build artifacts.** The path gate counts every file the agent's
  run leaves behind that git would commit. Make sure the product's
  `.gitignore` covers caches and build output (`__pycache__/`,
  `node_modules/`, `target/`, …), or a test run inside a protected directory
  fails the gate.
- Set `strictRedCheck: false` if your runner can't produce JUnit XML. QA then
  only has to leave the suite red.

## Verified gates (Lean 4)

The pipeline's agents are untrusted: LLMs with write access, and one of them
scores its own stage. What keeps them honest is a set of **deterministic
gates**. In this factory those gates *are* a Lean 4 program,
`.factory/lean`, built into one `factory` binary. The theorems are about the
very functions the binary runs, not a model of some other implementation.

| Gate | Command | Proved |
| --- | --- | --- |
| Write scope | `factory paths <stage>` (via `check-paths.sh`) | An accepted change touches only allowed, unprotected paths; a rename out of a protected directory is rejected (both of its paths are checked). |
| Red check | `factory red <junit.xml> <changed.txt>` | Accepted ⇒ some test in a file QA changed fails on an assertion, nothing errored, no test outside QA's files fails, and every test is attributed to a file. |
| Rubric | `factory score <rubric> <review> <out>` | For *any* review output — forged, negative, huge, or non-numeric scores — the overall stays ≤ 100; raising a score never lowers it; on the current rubric, no single criterion can pass a review alone. Weights and threshold are read as exact decimals; there is no floating point. |
| Pipeline | `factory workflow <orchestrator.yml>` | A PR exists only after every gate passed; every push follows its stage's path gate; auto-merge needs `autoMerge` *and* a passing rubric; a minted key is always revoked; a failed run always reports on its issue. The command fails if the YAML drifts from the model these are proved about. |

```bash
.factory/factory.sh build    # build the gates; fails on any unproved theorem or failing test
.factory/factory.sh verify   # build + rubric/workflow conformance + differential + end-to-end tests
```

CI runs the same thing (`.github/workflows/verify.yml`) on every change to
`.factory/` or `.github/`, and the orchestrator's setup job builds the
binary from `main` the same way, so a build never runs on unproved gates.
Core Lean only, no Mathlib; the toolchain is pinned in
`.factory/lean/lean-toolchain`. See [`.factory/lean/README.md`](.factory/lean/README.md)
for the theorem list, how proofs are tied to the shipped code, and what the
proofs don't cover.

## Agent orchestrator

`.github/workflows/orchestrator.yml` takes a human-filed NLSpec issue
(`.github/ISSUE_TEMPLATE/nlspec.md`) and drives it through
QA → Coder → Review → PR. Each stage can run on a different harness
(`claude-code`, `opencode`, or `codex`) and any [OpenRouter](https://openrouter.ai/models)
model, so one API key and one credit balance cover every provider.

Everything (QA, coder, review, PR, merge) runs in GitHub Actions. You don't
need a local machine after setup, and you can start, retry or override a
build entirely from GitHub: label the issue, or use Actions → "Agent
Orchestrator" → *Run workflow*. Running `run-agent.sh` locally is optional,
for debugging a prompt.

### Get started in 3 steps

```bash
# 0. In a repo with a product: fill in "product" and "paths" in
#    .factory/orchestrator.config.json (see "Plug in your product").

# 1. One-time GitHub setup: key isolation, labels, workflow permissions,
#    model check. Idempotent -- re-run it any time. (Needs gh, jq, curl,
#    openssl.) It asks for an OpenRouter *management* key
#    (openrouter.ai/settings/management-keys) with echo off.
.factory/factory.sh setup

# 2. Commit and push to the default branch (Actions only sees workflows there),
#    then smoke-test the default harness + model end to end (~2 min, a few
#    cents; it runs on its own throwaway key capped at $1).
gh workflow run spine-test.yml

# 3. File an issue from the "NLSpec" template, then add the `build` label.
```

`.factory/factory.sh check` re-verifies everything without changing anything.
Prefer the browser? Step 1 by hand:
1. Settings → Environments → **New environment** `factory`. Under
   Deployment branches, choose "Selected branches" and add only `main`. Add
   environment secret `OPENROUTER_MANAGEMENT_KEY`.
2. Settings → Secrets and variables → Actions → repo secret
   `FACTORY_KEY_PASSPHRASE`: any long random string (e.g. `openssl rand -hex 32`).
3. Create a `build` label, and set the workflow permissions below.

The pipeline creates its other labels itself, and each run checks the model
slugs before spending anything.
If the setup script can't change workflow permissions (some orgs lock them),
set them by hand: Settings → Actions → General → Workflow permissions →
"Read and write permissions" + "Allow GitHub Actions to create and approve
pull requests".

### How a run flows

```mermaid
flowchart TD
    T(["Issue labeled 'build'<br/>or workflow_dispatch"]) --> G

    subgraph G["guard"]
        G1["collaborator check"] --> G2["preflight: model slugs<br/>exist on OpenRouter?"]
    end

    G --> K["mint-key<br/>throwaway key for this build:<br/>$ cap + expiry"]
    K --> S["setup<br/>build + prove Lean gates<br/>branch agent/issue-N-slug<br/>labels, start comment"]
    S --> QA

    subgraph QA["qa"]
        Q1["agent writes tests<br/>inside paths.qa"] --> Q2{"factory paths:<br/>paths.qa only,<br/>never paths.protected"}
        Q2 --> Q3{"factory red:<br/>red for the right reason?"}
    end

    QA --> CO

    subgraph CO["coder"]
        C1["agent edits<br/>paths.coder"] --> C2{"product.test<br/>green?"}
        C2 -- "no, attempts left:<br/>feed failures back" --> C1
        C2 -- yes --> C3{"factory paths:<br/>paths.coder only"}
    end

    CO --> RV

    subgraph RV["review"]
        R1["agent scores diff vs<br/>.factory/rubric.json"] --> R2["factory score<br/>exact weighted pass/fail"]
    end

    RV --> PR{"autoMerge and<br/>rubric pass?"}
    PR -- yes --> M(["squash-merge"])
    PR -- no --> H(["PR left for human<br/>gatekeeper"])

    QA -. failure .-> F(["report-failure<br/>comments on issue"])
    CO -. failure .-> F
    RV -. failure .-> F
    M --> X(["revoke-key<br/>always runs"])
    H --> X
    F --> X
```

- **guard** checks that the label is the configured trigger label and that
  the person who applied it is a collaborator, so outsiders can't spend your
  OpenRouter credits or push code. It then checks every stage's model slug
  against OpenRouter's catalog. A typo fails here in seconds instead of
  after a five-minute install.
- **setup** builds the Lean gate binary from `main` (which checks every
  proof) and hands it to the agent jobs as an artifact, creates (or reuses)
  branch `agent/issue-<n>-<slug>`, makes sure the `agent:*` status labels
  exist, and comments on the issue.
- **qa** writes failing tests that use the protected harness. The job fails
  if the agent touched anything outside `paths.qa` or inside
  `paths.protected`, or if the suite is green. With `strictRedCheck` on, it
  also fails when the suite is red *for the wrong reason*: a test that errors
  at load or setup time (syntax error, bad import), or a pre-existing test
  the agent broke. That's decided by `factory red` from the JUnit report.
- **coder** edits `paths.coder` until `product.test` is green. Its
  prompt includes any open questions the QA agent recorded. If the suite is
  still red after an attempt, the failing output goes back to the agent for
  another try, up to `maxAttempts`.
- **review** scores the cumulative diff vs `main` against every criterion in
  `.factory/rubric.json`. `factory score` computes the weighted result in
  exact arithmetic and posts it on the issue. The job also fails if any
  `paths.protected` file changed anywhere on the branch.
- **pr** opens the gatekeeper PR with the score, the agents' open
  questions, and a "Factory run" section (harness/model per stage, link to
  the run record), then either squash-merges (`autoMerge: true` and the rubric
  passed) or leaves the PR for a human.

**Safety rails.** Agent jobs check out with `persist-credentials: false`, so
the agent has no push credentials. Only the workflow's commit steps push,
only after the path gate has passed, and with git hooks disabled so an
agent-written `.git/hooks` script can't run while the token is in scope.
The check diffs against the commit from before the agent ran, so an agent
that runs `git commit` itself can't hide changes from it. Builds for the
same issue are serialized (`concurrency`), so two runs never push to one
branch at once.

### Plug in any model or harness

All tuning lives in `.factory/orchestrator.config.json`. The workflow YAML
never hardcodes a model.

```mermaid
flowchart TD
    D["workflow_dispatch input<br/>(harness / model, this run only)"] -->|"if set"| V
    ST["stages.&lt;stage&gt;.&lt;key&gt;<br/>in orchestrator.config.json"] -->|"else if set"| V
    TOP["top-level &lt;key&gt;<br/>in orchestrator.config.json"] -->|"else"| V
    V(["resolved value for this stage"])
```

| Key | Meaning |
| --- | --- |
| `harness` | `claude-code`, `opencode`, or `codex`. |
| `model` | Any slug from [openrouter.ai/models](https://openrouter.ai/models). `~provider/…-latest` aliases (e.g. `~anthropic/claude-sonnet-latest`) always track the newest release. |
| `maxTurns` | Turn cap per stage. Honored by `claude-code` only; the other harnesses are bounded by the step's `timeout-minutes`. |
| `maxAttempts` | How many times a stage runs with the previous failures fed back. Used by `coder` (default `2`). |
| `stages.<qa\|coder\|review>` | Per-stage overrides for any key above. |
| `product` | The product's `setup`, `test`, and `testReport` commands and `env`. See [Plug in your product](#plug-in-your-product). |
| `paths` | The factory/product boundary: `protected`, plus the prefixes each stage may write (`qa`, `coder`). Each must end in `/`. See [Factory vs. product](#factory-vs-product). |
| `label` | Issue label that triggers a run (default `build`). |
| `autoMerge` | `true` = squash-merge when the rubric passes. Default `false` (human-gated). |
| `strictRedCheck` | QA "red for the right reason" gate, from the JUnit report (`product.testReport`). Set `false` if your runner can't write JUnit XML. |
| `runKey` | `{ "limitUsd": 5, "ttlMinutes": 180 }`: spending cap and expiry of each build's throwaway OpenRouter key. Hard ceilings of $50 / 360 min are enforced in the workflow. See [Keeping your OpenRouter key safe](#keeping-your-openrouter-key-safe). |
| `harnessVersions` | Optional npm version pins, e.g. `{"codex": "0.50.0"}`, for reproducible runs. Unlisted harnesses install `@latest`. |

```bash
.factory/factory.sh config   # print what each stage resolves to
.factory/factory.sh models   # check every stage's slug against OpenRouter
```

The examples below show only the keys to change. Merge them into the
existing file rather than replacing it, so `label`, `autoMerge`, and the
rest keep their values. Unset keys fall back safely: `label` defaults to
`build`, and claude-code `maxTurns` defaults to 8.

**Example: independent reviewer.** Coder on Claude, review on a different
model family (see [why](#design-notes-and-research)):

```json
{
  "harness": "claude-code",
  "model": "~anthropic/claude-sonnet-latest",
  "stages": {
    "coder":  { "maxTurns": 8, "maxAttempts": 2 },
    "review": { "harness": "opencode", "model": "~google/gemini-pro-latest" }
  }
}
```

**Example: low budget.** Cheap models everywhere except the coder:

```json
{
  "harness": "opencode",
  "model": "~deepseek/deepseek-flash-latest",
  "stages": {
    "coder": { "harness": "claude-code", "model": "~anthropic/claude-sonnet-latest", "maxTurns": 6 }
  }
}
```

**One-off override.** In the Actions tab, run "Agent Orchestrator" and pick a
harness from the dropdown and/or type a model slug. It applies to every stage
of that run only.

### How each harness reaches OpenRouter

`.factory/scripts/run-agent.sh` is the only place that knows about
harnesses. For each stage it resolves the config, validates the slug,
installs the CLI, writes the harness's config to a temp dir (never your
`$HOME`, never the repo), and runs the prompt.

```mermaid
flowchart LR
    RA["run-agent.sh &lt;stage&gt;"] --> CHK{"slug in OpenRouter catalog<br/>and supports tools?"}
    CHK -- no --> X(["fail with closest matches"])
    CHK -- yes --> H{"harness"}
    H -->|claude-code| CC["claude -p<br/>ANTHROPIC_BASE_URL=openrouter.ai/api<br/>all model tiers pinned to the slug"]
    H -->|opencode| OC["opencode run --auto<br/>generated OPENCODE_CONFIG registers the slug,<br/>tool profile becomes permissions"]
    H -->|codex| CX["codex exec<br/>generated CODEX_HOME config.toml,<br/>wire_api=responses, network on for tests"]
    CC -->|"Anthropic Messages API"| OR[("OpenRouter")]
    OC -->|"OpenAI-compatible API"| OR
    CX -->|"Responses API"| OR
    OR --> P["Anthropic, OpenAI, Google,<br/>DeepSeek, xAI, Moonshot, ..."]
```

| Harness | Best for | Notes |
| --- | --- | --- |
| `claude-code` | Anthropic models (the default). | Uses the tool allowlist natively. OpenRouter notes it "is optimized for Anthropic models and may not work correctly with other providers", and `run-agent.sh` warns if you try one. |
| `opencode` | Any model, especially non-Anthropic, non-OpenAI ones. | The slug is registered in a generated config, so new models work before opencode's bundled catalog knows about them. The Claude-style tool profile becomes opencode `permission` rules (edit allow/deny, bash limited to the same patterns). |
| `codex` | OpenAI models. | Uses OpenRouter's Responses API, the only protocol Codex still supports. No per-tool control, so it runs in `workspace-write` with network access (tests may need services such as a database). The path gate is the backstop. |

Run any stage locally against the same config (it uses your
`$OPENROUTER_API_KEY` and leaves your own harness settings alone):

```bash
bash .factory/scripts/run-agent.sh qa my-prompt.md "Read,Write,Edit,Bash(pytest*)"
```

### Spine test

`.github/workflows/spine-test.yml` is a manual smoke test for a
harness/model pair. It runs `product.setup` (if any), has the agent create a
one-line `spine-test.txt`, runs `product.test` (if configured), and pushes to
a scratch `agent/spine-test-<run id>` branch:

```bash
gh workflow run spine-test.yml -f harness=opencode -f model='~google/gemini-flash-latest'
```

Check [openrouter.ai/activity](https://openrouter.ai/activity) afterward to
confirm which model actually served the request and what it cost. Delete
the scratch branch when you're done.

### Cost levers

- The **coder** stage is the most expensive, since it loops test → read →
  edit. `maxTurns` (claude-code) and `maxAttempts` cap it.
- Put a cheap model on **qa** and **review** and a strong one on **coder**.
- `runKey.limitUsd` is a hard per-build ceiling: each build's key stops
  working once it has spent that much.

### Keeping your OpenRouter key safe

**The rule: your real key never exists anywhere an agent runs.**

Agents execute code on the runner. They write tests that the product's test command runs,
and opencode and codex have a shell. GitHub-hosted runners also give
passwordless `sudo`. Code running in a job can therefore read every secret
that job was given, even from the runner process's memory. That's how the
2025 [tj-actions/changed-files compromise](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3)
stole secrets. Masking and log redaction can't stop that, so the factory
never gives an agent job anything worth stealing:

```mermaid
flowchart LR
    subgraph ENV["'factory' environment (default branch only)"]
        MK[("OPENROUTER_MANAGEMENT_KEY<br/>can mint/delete keys,<br/>can't call models")]
    end
    subgraph RK["run-key.yml (inline script only:<br/>no checkout, no actions)"]
        MINT["mint: new key<br/>limit $5, expires in 3h"]
        DEL["revoke: delete key"]
    end
    MK --> MINT
    MK --> DEL
    MINT -- "AES-256 ciphertext<br/>(safe in public logs)" --> A
    subgraph A["agent jobs: qa / coder / review"]
        DEC["run-agent.sh decrypts,<br/>masks, drops passphrase"] --> AG["agent + harness<br/>see only the run key"]
    end
    A -- "build finished,<br/>pass or fail" --> DEL
```

| Layer | What it guarantees |
| --- | --- |
| Management key in a branch-restricted **environment** | Only jobs that declare `environment: factory` get it, and only on the default branch. Agent jobs never declare it, so the key is never sent to their runner. A workflow edited on some other branch can't reach it. |
| Mint and revoke run as **inline YAML only** (`.github/workflows/run-key.yml`) | Nothing is checked out and no actions run beside the management key. Only code under `.github/workflows/` runs there, and that's the one path a workflow's `GITHUB_TOKEN` can never modify. A compromised agent job can't plant code that later runs next to the key. |
| One **throwaway key per build** | Capped at `runKey.limitUsd` (hard ceiling $50, whatever the config says), expires after `runKey.ttlMinutes` (ceiling 6h), and deleted when the build ends, pass or fail. That key is the only one an agent can ever see. If it leaks, it's worth at most the cap, for at most the rest of that build. |
| **Encrypted** between jobs | Job outputs and step env appear in public logs. The run key leaves `run-key.yml` only as AES-256 ciphertext, and `run-agent.sh` decrypts it, registers a log mask, and unsets the passphrase before the agent starts. |
| **Scrubbed** publish paths | GitHub masks job logs, not files. Everything the factory publishes goes through `scrub.sh` first: run-record artifacts, the review comment, the PR body. It removes anything key-shaped plus the passphrase. Artifacts contain named files only, so whatever else an agent drops in the run directory isn't uploaded. `check-paths.sh` refuses to commit a change that adds a key-shaped string to product code. |
| Key material kept from **agent-run code** | The passphrase and ciphertext are unset before the harness starts, and `product.sh` strips them from the environment of every product command (which runs agent-written code). |
| **Rules snapshot** | Each agent job copies `.factory/scripts`, the config, and the prebuilt `factory` gate binary (built from `main`) before the agent starts, and judges the agent with that copy. Editing `check-paths.sh`, `paths`, or the Lean sources in the working tree changes nothing. |
| **Never on a command line** | Keys reach `curl` on stdin (`-H @-`), so they never show in a process list. `setup.sh` reads the management key with echo off and validates it before storing it. |

**What this guarantees, and what it can't:** your management key never
exists in a job where agent code runs. That part doesn't depend on any agent
behaving. Inside its own job, though, a *deliberately* malicious agent
(say, prompt-injected through an issue body) has root, so it can take
whatever that job holds: this build's run key, the passphrase, and the job's
`GITHUB_TOKEN`. The in-job checks above stop accidents, not a determined
attacker. What bounds a determined attacker:

- **The run key** is worth at most `limitUsd`, and only until the build ends
  (`ttlMinutes` at worst).
- **The passphrase** only unlocks run keys, and ciphertexts appear in public
  logs. If a build ever looks suspicious (unexpected spend on
  [openrouter.ai/activity](https://openrouter.ai/activity), odd commits),
  rotate it: `openssl rand -hex 32 | gh secret set FACTORY_KEY_PASSPHRASE`.
  Rotating it now and then costs nothing.
- **The `GITHUB_TOKEN`** is handled by the branch ruleset below.

Gaps outside the factory's control, and what to do about them:

- **People with write access to `.github/workflows/` on the default branch,
  or repo admins**, can always reach environment secrets; that's how GitHub
  works. Protect the default branch with a ruleset that requires PRs
  (`.factory/factory.sh check` warns if it doesn't), and add a `CODEOWNERS` entry for
  `/.github/` so workflow changes need your review. The ruleset also stops a
  `GITHUB_TOKEN` stolen from an agent job from pushing straight to `main`.
- **Leaks of the management key itself** (your machine during setup, GitHub,
  OpenRouter). Limit the damage: give it an expiry when you create it, run
  the factory from a dedicated OpenRouter workspace or account, and turn off
  auto top-up so total exposure is your balance.
- **Your issue text.** Prompts include the issue body verbatim and are saved
  in the run record, so on a public repo, don't put anything private in an
  NLSpec.

Each build also shows up as a deployment to the `factory` environment in
the repo sidebar. That's expected; it's how GitHub records environment
access.

**Retrying a build:** use *Re-run all jobs* (or re-apply the label). *Re-run
failed jobs* reuses the original key, which was already deleted. Agents
detect that and fail with a message saying so.

### Design notes and research

A few choices in this pipeline come from recent work on coding agents:

- **Review with a different model than the coder.** LLM judges score their
  own outputs higher than equally good outputs from other models, and the
  bias grows with how well a model recognizes its own writing
  ([Panickssery et al., NeurIPS 2024](https://arxiv.org/abs/2404.13076)).
  Per-stage `model` makes a cross-family reviewer a one-line change; see the
  example above.
- **Guard against test gaming.** On tasks where passing the tests requires
  contradicting the spec, frontier models frequently cheat, by special-casing
  tests or editing them, and stronger models do it more
  ([ImpossibleBench, 2025](https://arxiv.org/abs/2510.20270)). This is why
  the coder can't touch the tests (enforced by the Lean path gate, not just
  the prompt), why the rubric has an `architecture.no-test-gaming` criterion,
  and why the agents record conflicts in the ambiguity checklist, which is
  surfaced in the PR, instead of resolving them on their own.
- **Red for the right reason.** A test suite that fails because of a syntax
  error gives the coder nothing to implement against. The strict QA gate
  (`factory red`, from any runner's JUnit report) rejects that, along with
  collateral damage to existing tests, before the coder spends any tokens.
- **Prove the gates, not the agents.** Agent output can't be verified ahead
  of time, but the handful of deterministic checks that judge it can. They're
  small, they're where an exploit pays off (a forged rubric score, a file
  moved out of the protected harness — both real bugs found while writing
  these proofs), and every build depends on them.
- **Feed failures back.** One retry with the concrete test output in context
  (in the style of [Reflexion](https://arxiv.org/abs/2303.11366)) is a cheap
  way to recover from a near miss without a full re-run.
- **Keep context files short.** A 2026 study found that repository context
  files (AGENTS.md / CLAUDE.md) *lowered* task success on average and raised
  cost by over 20%, because agents faithfully follow every extra instruction.
  Its advice is that human-written files should state only minimal
  requirements
  ([Gloaguen et al., 2026](https://arxiv.org/abs/2602.11988)). `CLAUDE.md` is
  the single source of truth (Spec Kit manages a block in it), and
  `AGENTS.md` is a symlink to it so Codex and opencode read the same rules.
  Add to it sparingly.

### Known limits

- `maxTurns` only bounds `claude-code`. For `opencode` and `codex`, the
  agent step's `timeout-minutes` is the backstop.
- `codex` and `opencode` aren't restricted per tool the way `claude-code`
  is. The path gate and `persist-credentials: false` contain them, but they
  can run arbitrary shell commands inside the runner.
- GitHub keeps only one *pending* run per concurrency group. If a build
  is queued behind a running one for the same issue and someone adds an
  unrelated label, the queued build is dropped. Re-apply the label, or
  dispatch it, once the first build finishes.
- Retry with *Re-run all jobs*, not *Re-run failed jobs*. Each build's key
  is deleted when the build ends.
- Each stage runs `product.setup` on a fresh runner. Nothing (services,
  seed data) persists between jobs.
- **Agent-written code runs inside the gates' inputs.** The test command
  runs product files the coder may edit (test scripts, runner config), and
  agent-written tests run while the JUnit report is being written. A
  deliberately adversarial agent could make a red suite look green, or forge
  the report. The proofs say the gates decide correctly *given* their inputs;
  the rubric's `architecture.test-isolation` criterion and the human
  gatekeeper cover the rest. Keeping test configuration inside a protected
  directory closes most of this. Protected entries are directories, so a
  single root file such as `package.json` can't be protected yet.
- Job logs show raw agent output (stream-JSON for claude-code/opencode).
  It's noisy, but it's the actual tool-call trace. The same output, plus the
  exact prompts, is saved in the `run-<stage>` artifacts. Each run's job
  summary lists the resolved harness/model per stage and the rubric report.


## Factory scaffolding

| Path | What it is |
| --- | --- |
| `.factory/qa.nlspec.md`, `.factory/coder.nlspec.md` | The QA and coder agents' roles, scope rules, and workflow. These are the prompts the orchestrator feeds the agents; CI appends the issue, the write scope, and the test command. |
| `.factory/rubric.json` | The review bar. `factory check-rubric` checks it is the rubric the Lean theorems describe. |
| `.factory/orchestrator.config.json` | Harness, models, `product`, `paths`, merge gate, key limits. |
| `.factory/ambiguity-checklist.md` | The inbox where agents record open questions instead of guessing. CI moves those notes into the PR rather than committing them. |
| `.factory/lean/` | The gates: Lean sources, proofs, build-time tests, JUnit fixtures. |
| `.factory/scripts/` | Plumbing: `run-agent.sh` (harness adapter), `check-paths.sh` (git side of the path gate), `product.sh` (product commands), `setup.sh`, `scrub.sh`, `factory-bin.sh`. |
| `.factory/factory.sh` | Local entry point: `setup`, `check`, `config`, `models`, `build`, `test`, `verify`. |
| `.github/workflows/` | `orchestrator.yml` (the pipeline), `run-key.yml` (per-build keys), `spine-test.yml` (harness smoke test), `verify.yml` (proofs and gate tests). |
| `.github/actions/` | `factory-bin` (build the Lean gates, cached), `setup-product` (run `product.setup`). |
| `.github/ISSUE_TEMPLATE/nlspec.md`, `.github/PULL_REQUEST_TEMPLATE/gatekeeper.md` | The issue an agent build starts from, and the human merge checklist. |

---

## Adapting AutomataDark for your own project

### Copy the factory into your repo

```bash
# Run from inside your project repo
gh repo clone Viraj-Ganguli/AutomataDark /tmp/AutomataDark-src
cp -r /tmp/AutomataDark-src/.factory .
mkdir -p .github
cp -r /tmp/AutomataDark-src/.github/workflows /tmp/AutomataDark-src/.github/actions \
      /tmp/AutomataDark-src/.github/ISSUE_TEMPLATE /tmp/AutomataDark-src/.github/PULL_REQUEST_TEMPLATE .github/
rm -rf /tmp/AutomataDark-src
```

Or start a new repo from this one as a template
(`gh repo create my-project --template Viraj-Ganguli/AutomataDark --private`)
and add your product to it.

### Customization checklist

- [ ] **Describe your product** — fill in `product` in
  `.factory/orchestrator.config.json` ([Plug in your product](#plug-in-your-product)).
- [ ] **Set the product boundary** — edit `paths`: what QA may write, what
  the coder may write, what's protected. CI enforces it and injects it into
  the prompts, so the NLSpecs need no edits.
- [ ] **Write the shared test harness** under `paths.protected` (default
  `tests/golden/`): an app/test-client factory, a data reset helper, and
  fixtures, with a short README. Every QA-generated suite imports it.
- [ ] **Write a short agent doc** (`CLAUDE.md`, with `AGENTS.md` as a symlink
  so Codex and opencode read the same file) describing your architecture,
  layering, and the rule that nothing under `paths.protected` may change.
- [ ] **Tune the rubric** — criterion descriptions and weights in
  `.factory/rubric.json`. If you change weights, criterion counts, or the
  threshold, update `Factory.Rubric.current` in `.factory/lean` and re-run
  `.factory/factory.sh verify` (the concrete rubric theorems are about it).
- [ ] **Make sure your `.gitignore` covers build and test artifacts.**
- [ ] **One-time setup**: `.factory/factory.sh setup`, then
  `gh workflow run spine-test.yml`.

Install [elan](https://github.com/leanprover/elan) to build the gates
locally (`.factory/factory.sh build`); CI installs it on its own.
