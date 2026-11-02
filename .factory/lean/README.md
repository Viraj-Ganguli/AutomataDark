# .factory/lean — the factory's gates, written and proved in Lean 4

The agents in this factory are untrusted: LLMs with write access, one of which
scores its own stage. What keeps them honest is a small set of
**deterministic gates**. This directory *is* those gates. It builds one
binary, `factory`, that the orchestrator calls for every pass/fail decision,
and the theorems are about the exact functions that binary runs.

```sh
.factory/factory.sh build    # lake build: fails on any unproved theorem or failing build-time test
.factory/factory.sh verify   # build + conformance + differential + end-to-end tests (what CI runs)
```

Needs [elan](https://github.com/leanprover/elan). The toolchain is pinned in
`lean-toolchain`. Core Lean only, no Mathlib; the binary is self-contained
and has no runtime dependencies.

## Commands

| Command | Used by | Decision function |
| --- | --- | --- |
| `factory paths <stage>` | `check-paths.sh`, after every agent stage | `PathGate.acceptPaths` |
| `factory describe <stage>` | prompt assembly | — (prints the write scope) |
| `factory red <junit.xml> <changed.txt>` | QA job (`strictRedCheck`) | `Red.redOk` over `JUnit.parse` |
| `factory score <rubric> <review> <out>` | review job | `Rubric.pass` |
| `factory check-rubric <rubric.json>` | `verify` | rubric.json = `Rubric.current` |
| `factory workflow <orchestrator.yml>` | `verify` | YAML matches `Pipeline.jobTable` + step rules |
| `factory model-gate` | `scripts/diff-gate.sh` | `PathGate.accept` (operations level) |
| `check-proofs.lean check` (via `.factory/scripts/proofs.sh`) | coder job, if `product.proofs` is set | the product's own proofs, see [Proof obligations](#proof-obligations) |
| `check-proofs.lean audit Factory Factory` | `verify` | every theorem here uses only the standard axioms |

`Factory/Cli.lean` only reads files, converts JSON, and formats messages.

## What is proved

| Module | Theorem | Says |
| --- | --- | --- |
| `PathGate` | `acceptPaths_sound`, `acceptPaths_no_protected` | An accepted list of changed paths has only allowed, unprotected paths. |
| | `acceptPaths_iff` | The reported violations are exactly why a non-empty change is rejected. |
| | `accept_no_protected`, `rename_out_rejected` | On what the agent *did*: no protected path is edited, added, deleted, or renamed in **either** direction. |
| | `nameOnly_unsound` | For every scope: reporting renames by destination only (`git diff --name-only` without `--no-renames`) accepts any move out of a protected path that the real gate rejects (a real bug, fixed). |
| `Red` | `redOk_sound` | Accepted ⇒ a test in a file QA changed fails on an assertion, nothing errored, no test outside QA's files fails, and every test is attributed to a file. |
| | `problems_nil_iff` | The printed problem list is empty exactly when the check passes. |
| `Rubric` | `scaled_le`, `overall_le_100` | For **any** review output (forged, negative, huge, non-numeric scores) the overall stays ≤ 100. |
| | `threshold_above_100_never_passes`, `scaled_mono` | A threshold over 100 never passes; raising any score never lowers the result. |
| | `lone_criterion_fails` | On the current rubric, no single criterion can pass a review, whatever value it holds. |
| | `unsanitized_forgery_passes` | Without the validity filter, one score of 10^6 passes (a real bug, fixed). |
| | `two_security_zeros_pass` | **Design finding:** zeros on two of the four security criteria still pass. |
| `Pipeline` | `pr_requires_gates` | The pr job runs at all (so a PR can exist) only if the QA path gate and red check, the coder path gate, tests and proof obligations, and the review clean-tree check all passed. |
| | `push_requires_gate` | Every push to the agent branch comes right after that stage's path gate. |
| | `merge_requires_pass` | Auto-merge requires `autoMerge` **and** a passing rubric. |
| | `key_revoked`, `failure_reported` | A minted key is always revoked; a failed job always comments on its issue. |

`push_requires_gate` and `accept_no_protected` together give the factory's
hard rule: no commit an agent pushes changes `paths.protected`.

The rubric is computed exactly: JSON numbers are decimals, so weights and the
threshold are read as exact fractions (`0.35 = 35/100`), and pass/fail is a
cross-multiplied comparison of natural numbers. A fractional score is
rounded down; anything outside [0, 100], or not a number, counts as 0.

Scope entries are directories (ending in `/`, covering everything under
them) or exact file paths (covering that file only), so single files such as
a lakefile or `package.json` can be protected without covering siblings.

## Proof obligations

The factory can also hold the *product* to proofs. This follows the pattern
of the Lean entry to the [$12 server challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/153):
an obviously-correct model, a fast plan proved equal to it under a data
invariant, and a runtime check proved to establish that invariant (with a
fallback when it doesn't hold).

Set `product.proofs` to a Lean package directory laid out like
[`examples/feed`](examples/feed):

| Path | Who writes it | Contents |
| --- | --- | --- |
| `Spec/` | a human (protected) | the model (`feed`), the invariant (`Inv`), and each obligation as a predicate on an implementation (`PlanCorrect plan := ∀ db, Inv db → plan db = feed db`) |
| `Spec/obligations.json` | a human (protected) | which theorem must prove which predicate about which implementation constant |
| `Impl/` | the coder agent | the implementations (`feedPlan`, `checkInv`, `insertOk`) and their proofs |
| `lakefile.toml`, `lean-toolchain` | a human (protected) | the toolchain must match `.factory/lean/lean-toolchain` |

The human approves *statements*, which are short; the agent does the proving,
which is long. That split is the point: a proof can't be faked, but a
statement can be too weak, so whoever writes the statements is the control
([Lean's guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/)
treats unreviewed AI proofs as adversarial).

`proofs.sh` rebuilds the package from source in a clean copy (ignoring any
`.lake/`, which could hold forged compiled proofs) and runs
`check-proofs.lean`, which fails unless every obligation's theorem

- exists under exactly its name and is a theorem;
- has *syntactically* the statement `Predicate impl` (no unfolding, so it
  can't be weakened, given extra hypotheses, or pointed at another function);
- uses a predicate defined in a protected spec module (so it can't be
  shadowed);
- and, with each implementation it's about, uses only `propext`,
  `Classical.choice`, and `Quot.sound` (no `sorry`, custom axioms, or
  `native_decide`);

and no constant in the package is an axiom or swaps in different runtime
code with `@[implemented_by]`/`@[extern]`. `scripts/proofs.test.sh` checks
the honest example passes and ten ways of cheating are each rejected for the
right reason.

What it does not do: sandbox the build (agent-written Lean runs during
`lake build`; Lean's `comparator` does that, and is the upgrade path), or
prove the product's non-Lean code matches the Lean model. For that, use the
compiled model as an oracle in differential tests, or have Lean emit the hot
path as the challenge entry does.

## How the proofs reach the shipped behavior

- **The gates are the proved functions.** No separate implementation exists
  to drift from the model.
- **Build-time tests** (`Factory/Tests.lean`) run during `lake build`, so a
  failing test fails the build like an unproved theorem. They include the
  JUnit parser against real pytest and jest-junit reports
  (`tests/fixtures/`).
- **`scripts/diff-gate.sh`** checks the one piece of plumbing outside Lean:
  how `check-paths.sh` turns git state into a path list. It performs random
  file operations (edit, add, delete, rename, run notes) in throwaway repos,
  and compares the shipped gate with `PathGate.accept` on the operations
  themselves. That is the test that would have caught the rename bug.
- **`factory check-rubric`** and **`factory workflow`** fail when
  `rubric.json` or `orchestrator.yml` stop matching what the concrete
  theorems assume.

## Assumptions and limits

- **Not proved:** the JUnit tag scanner (tested against real reports), JSON
  and file I/O, and `check-paths.sh`'s git plumbing (differential-tested).
- **Pipeline:** the model uses GitHub Actions' documented job semantics
  (default `success()`, skipped needs propagate, `always()`/`failure()`).
  Steps inside a job are summarized by a Bool per gate; `factory workflow`
  checks the gate steps exist, run the right command, come before the push,
  and can't be skipped or ignored. `Pipeline.run` is written by hand to
  match `jobTable`.
- **Inputs agents can influence.** The gates decide correctly on their
  inputs, but agent-written code runs while some of those inputs are made:
  the coder can edit product files that define how tests run, and
  agent-written tests run while the JUnit report is written. Keep test
  configuration under `paths.protected` where you can.
- **`qaRedOk`** in the pipeline model stands for "`factory red` passed, or
  `strictRedCheck` is off".
- **Key revocation** assumes `key_hash` is set whenever a key exists; the
  key's TTL is the backstop.
- No theorem here uses `native_decide` or any non-standard axiom; `verify`
  audits this on every run.

## Next

- A spec stage: an agent drafts `Spec/` from the issue's acceptance criteria
  and a human approves it before the coder runs.
- Differential tests of the product against the compiled Lean model.
- `comparator` (sandboxed rebuild, statement check against a challenge file)
  and `lean4checker --fresh` in CI.
- The coder's retry loop and concurrent runs on one issue, in TLA+.
