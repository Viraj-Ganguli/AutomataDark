<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

<!--
DRAFT — starter content, revise me.
The section below is project-convention documentation for the autonomous
agent workflow (QA agent, coder agent, and any future orchestrator/judge).
-->

## Project conventions for autonomous agents

This repo hosts a learning lab: a throwaway "club events" CRUD app
(`client/` + `server/`) that serves as the guinea pig for an agent workflow,
plus factory scaffolding under `.factory/` and `.github/` that defines how
agents operate on it.

### Sources of authority

When an agent (QA, coder, or otherwise) is working a task, only the
following are authoritative, in this order:

1. **The body of the GitHub issue** that triggered the work — specifically
   one created from `.github/ISSUE_TEMPLATE/nlspec.md` (Context, User Story,
   Acceptance Criteria, API/Data Contract, Edge Cases, Out of Scope,
   Non-Functional Constraints).
2. **The `.factory/` NLSpecs** — `.factory/qa.nlspec.md` and
   `.factory/coder.nlspec.md` define each agent's role, allowed/forbidden
   paths, and required workflow. `.factory/rubric.json` defines the
   code-review bar; `.factory/ambiguity-checklist.md` is where open questions
   are recorded.

Anything not covered by these sources should be treated as undefined, not
inferred — record it in `.factory/ambiguity-checklist.md` rather than
guessing.

### The one hard rule: never modify `tests/golden/`

`tests/golden/` is a hand-written test harness that every other test suite
under `tests/**` builds on. **No agent — QA, coder, or otherwise — may create,
edit, or delete any file under `tests/golden/`**, for any reason, including
"fixing" a failing test or harness bug. If something there appears wrong,
record it in `.factory/ambiguity-checklist.md` and stop.

### App layering (`server/`)

Follow the existing `routes -> services -> data-access` layering:

- `server/src/routes/**` — HTTP parsing/response shaping only. No SQL, no
  business rules.
- `server/src/services/**` — validation and business logic. No `req`/`res`.
- `server/src/data-access/**` — parameterized SQL only, via the shared pool
  in `server/src/db/pool.js`.

Errors should be thrown as `AppError` subclasses (`server/src/errors.js`) and
handled by the central error middleware (`server/src/middleware/error.js`),
not via ad-hoc `res.status(...)` calls scattered through services.

### Orchestration

`.github/workflows/orchestrator.yml` drives the QA → Coder → Review → PR
pipeline described above, invoking an agent CLI in CI per
`.factory/qa.nlspec.md` / `.factory/coder.nlspec.md` / `.factory/rubric.json`.
Each stage runs through `.factory/scripts/run-agent.sh`, which installs the
configured harness (`claude-code`, `opencode`, or `codex`) and points it at
OpenRouter, so the harness and model can differ per stage. See the README's
"Agent orchestrator" section for the trigger, configuration
(`.factory/orchestrator.config.json`), and one-time setup steps.
