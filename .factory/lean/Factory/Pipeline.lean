/-!
# Orchestrator pipeline (`.github/workflows/orchestrator.yml`)

A model of the job graph under GitHub Actions' job semantics:

* no `if:`, or `if: <expr>` without a status function, means
  `success() && <expr>`: the job runs only when every job it `needs` succeeded,
  and is skipped otherwise;
* `always() && <expr>` runs whatever happened upstream;
* `failure() && <expr>` runs when some needed job failed.

What each job's steps do is an input (`Inputs`). Every success, failure, and
model answer is possible, so the theorems hold however the agents behave.
`jobTable` records the `needs:` and `if:` the model assumes, and
`factory workflow` (`Factory.Workflow`) fails if the YAML has drifted from it.

The main results:

* `pr_requires_gates`: a PR is opened only if the QA path gate and red check,
  the coder path gate and tests, and the review clean-tree check all passed.
* `push_requires_gate`: each push to the agent branch follows that stage's
  path gate. With `PathGate.accept_no_protected`, no commit on the branch
  changes `tests/golden/`.
* `merge_requires_pass`: auto-merge requires `autoMerge` *and* a passing rubric.
* `key_revoked`: once a key is minted, the revoke job runs.
* `failure_reported`: if a job fails on an issue-triggered run, the issue is told.
-/

namespace Factory.Pipeline

inductive Status where
  | success | failure | skipped
  deriving DecidableEq, Repr

/-- What each job's own steps would do, if the job ran. -/
structure Inputs where
  guardOk : Bool
  proceed : Bool          -- guard: label/issue checks say "build"
  hasIssue : Bool         -- guard: issue_number != ''
  mintOk : Bool
  keyMinted : Bool        -- mint-key: key_hash output is non-empty
  setupOk : Bool
  qaAgentOk : Bool
  qaPathsOk : Bool        -- check-paths.sh qa
  qaRedOk : Bool          -- `factory red`, or strictRedCheck off
  coderAgentOk : Bool
  coderTestsOk : Bool     -- npm test, after up to maxAttempts tries
  coderPathsOk : Bool     -- check-paths.sh coder
  reviewAgentOk : Bool
  reviewTreeClean : Bool  -- "Enforce review write-scope"
  rubricPass : Bool       -- `factory score` `pass`
  prOk : Bool
  autoMerge : Bool
  revokeOk : Bool
  deriving Repr

/-- A job with no status function in its `if:` (`success() && extra`). -/
def gated (needs : List Status) (extra ok : Bool) : Status :=
  if needs.all (· == .success) && extra then (if ok then .success else .failure) else .skipped

/-- A job whose `if:` uses `always()` or `failure()`. -/
def runIf (cond ok : Bool) : Status :=
  if cond then (if ok then .success else .failure) else .skipped

structure Run where
  guard : Status
  mintKey : Status
  setup : Status
  qa : Status
  coder : Status
  review : Status
  pr : Status
  reportFailure : Status
  revokeKey : Status
  /-- The QA job reached its push step (after check-paths and check-red). -/
  qaPushed : Bool
  /-- The coder job reached its push step (after tests and check-paths). -/
  coderPushed : Bool
  /-- The pr job ran `gh pr merge`. -/
  merged : Bool

def run (i : Inputs) : Run :=
  let guard := runIf true i.guardOk
  let mintKey := gated [guard] i.proceed i.mintOk
  let setup := gated [guard] i.proceed i.setupOk
  let qaRuns := gated [guard, mintKey, setup] true true == .success
  let qa := gated [guard, mintKey, setup] true (i.qaAgentOk && i.qaPathsOk && i.qaRedOk)
  let coderRuns := gated [guard, mintKey, setup, qa] true true == .success
  let coder := gated [guard, mintKey, setup, qa] true
    (i.coderAgentOk && i.coderTestsOk && i.coderPathsOk)
  let review := gated [guard, mintKey, setup, qa, coder] true (i.reviewAgentOk && i.reviewTreeClean)
  let prRuns := gated [guard, setup, qa, coder, review] true true == .success
  let pr := gated [guard, setup, qa, coder, review] true i.prOk
  let reportFailure :=
    runIf ([guard, mintKey, setup, qa, coder, review, pr].any (· == .failure) && i.hasIssue) true
  -- A skipped job has empty outputs, so key_hash is set only if mint-key ran.
  let keyHash := mintKey != .skipped && i.keyMinted
  { guard, mintKey, setup, qa, coder, review, pr, reportFailure,
    revokeKey := runIf keyHash i.revokeOk
    qaPushed := qaRuns && i.qaAgentOk && i.qaPathsOk && i.qaRedOk
    coderPushed := coderRuns && i.coderAgentOk && i.coderTestsOk && i.coderPathsOk
    merged := prRuns && i.autoMerge && i.rubricPass }

/-- The YAML shape the model assumes: job, `needs:`, `if:`. -/
def jobTable : List (String × List String × String) :=
  [ ("guard", [], ""),
    ("mint-key", ["guard"], "needs.guard.outputs.proceed == 'true'"),
    ("setup", ["guard"], "needs.guard.outputs.proceed == 'true'"),
    ("qa", ["guard", "mint-key", "setup"], ""),
    ("coder", ["guard", "mint-key", "setup", "qa"], ""),
    ("review", ["guard", "mint-key", "setup", "qa", "coder"], ""),
    ("pr", ["guard", "setup", "qa", "coder", "review"], ""),
    ("report-failure", ["guard", "mint-key", "setup", "qa", "coder", "review", "pr"],
      "failure() && needs.guard.outputs.issue_number != ''"),
    ("revoke-key", ["guard", "mint-key", "setup", "qa", "coder", "review", "pr", "report-failure"],
      "always() && needs.mint-key.outputs.key_hash != ''") ]

theorem gated_success {needs : List Status} {extra ok : Bool} :
    gated needs extra ok = .success ↔ (∀ s ∈ needs, s = .success) ∧ extra = true ∧ ok = true := by
  unfold gated
  split <;> (try split) <;> simp_all <;> grind

theorem gated_true_success {needs : List Status} {extra : Bool} :
    (gated needs extra true == .success) = true ↔ (∀ s ∈ needs, s = .success) ∧ extra = true := by
  simp [beq_iff_eq, gated_success]

theorem runIf_ne_skipped {cond ok : Bool} : runIf cond ok ≠ .skipped ↔ cond = true := by
  unfold runIf
  split <;> (try split) <;> simp_all <;> grind

theorem gated_ne_skipped {needs : List Status} {extra ok : Bool} :
    gated needs extra ok ≠ .skipped ↔ (∀ s ∈ needs, s = .success) ∧ extra = true := by
  unfold gated
  split <;> (try split) <;> simp_all <;> grind

/-- No PR is opened unless every deterministic gate passed. This holds whenever
the pr job *runs*, not only when it succeeds: the PR exists from the
`gh pr create` step on, even if a later step fails. -/
theorem pr_requires_gates (i : Inputs) (h : (run i).pr ≠ .skipped) :
    i.proceed ∧ i.qaPathsOk ∧ i.qaRedOk ∧ i.coderTestsOk ∧ i.coderPathsOk ∧
      i.reviewTreeClean := by
  simp only [run, gated_ne_skipped, gated_success, List.mem_cons, List.not_mem_nil, or_false,
    forall_eq_or_imp, forall_eq, Bool.and_eq_true] at h
  simp_all

/-- Every push to the agent branch comes right after that stage's path gate
passed (for the coder, after QA's had passed too). -/
theorem push_requires_gate (i : Inputs) :
    ((run i).qaPushed → i.qaPathsOk ∧ i.qaRedOk) ∧
    ((run i).coderPushed → i.coderPathsOk ∧ i.coderTestsOk ∧ i.qaPathsOk) := by
  constructor
  · intro h
    simp only [run, Bool.and_eq_true] at h
    exact ⟨h.1.2, h.2⟩
  · intro h
    simp only [run, Bool.and_eq_true, gated_true_success, gated_success, List.mem_cons,
      List.not_mem_nil, or_false, forall_eq_or_imp, forall_eq] at h
    simp_all

/-- Auto-merge needs both the config flag and a passing rubric, on top of every gate. -/
theorem merge_requires_pass (i : Inputs) (h : (run i).merged) :
    i.autoMerge ∧ i.rubricPass ∧ i.qaPathsOk ∧ i.coderPathsOk ∧ i.reviewTreeClean := by
  simp only [run, Bool.and_eq_true, gated_true_success, gated_success, List.mem_cons,
    List.not_mem_nil, or_false, forall_eq_or_imp, forall_eq] at h
  simp_all

/-- A minted key is always revoked, whatever happened in between. -/
theorem key_revoked (i : Inputs) (h : (run i).mintKey ≠ .skipped) (hk : i.keyMinted) :
    (run i).revokeKey ≠ .skipped := by
  simp only [run]
  rw [runIf_ne_skipped]
  simp only [run] at h
  simp [h, hk]

/-- If a job fails on an issue-triggered run, the issue gets a failure comment. -/
theorem failure_reported (i : Inputs) (hi : i.hasIssue)
    (h : (run i).qa = .failure ∨ (run i).coder = .failure ∨ (run i).review = .failure ∨
         (run i).pr = .failure) :
    (run i).reportFailure ≠ .skipped := by
  simp only [run] at h ⊢
  rw [runIf_ne_skipped]
  simp only [List.any_cons, List.any_nil, Bool.and_eq_true, hi, and_true]
  rcases h with h | h | h | h <;> simp [h]

end Factory.Pipeline
