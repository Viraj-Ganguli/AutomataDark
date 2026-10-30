/-!
# Path gate (`factory paths`, called by `.factory/scripts/check-paths.sh`)

The factory/product boundary check that runs after the QA and coder stages.
`check-paths.sh` does the git plumbing: it stages everything, lists every
changed path with `git diff --name-only --no-renames`, and takes out the run
notes. It then pipes that list to `factory paths`, which decides with
`acceptPaths` below. The proofs are about the function that runs in CI.

Two layers:

* `acceptPaths` decides on a list of changed paths. This is what ships.
* `accept` takes what the agent *did* (a list of file operations) and checks
  `acceptPaths` on every path those operations touch, counting both sides of a
  rename. `scripts/diff-gate.sh` runs random operations through the real git
  plumbing and checks that the shipped gate agrees with `accept`, which is what
  ties `git diff`'s reporting to the operations.

The main results:

* `acceptPaths_sound`: an accepted list has only allowed, unprotected paths.
* `accept_no_protected`: no protected path is created, edited, deleted, or
  renamed (in either direction).
* `nameOnly_unsound`: the earlier `git diff --name-only` behavior, which
  reported only a rename's destination, accepts a move out of `tests/golden/`.
-/

namespace Factory.PathGate

/-- One file operation performed by an agent. -/
inductive Op where
  | edit (path : String)
  | add (path : String)
  | delete (path : String)
  | rename (src dst : String)
  deriving Repr, DecidableEq

/-- Every path an operation changes. A rename changes both of its paths. -/
def Op.touched : Op → List String
  | .edit p | .add p | .delete p => [p]
  | .rename s d => [s, d]

/-- One stage's write scope, from `.paths` in `orchestrator.config.json`. -/
structure Scope where
  allowed : List String
  protect : List String
  deriving Repr

/-- A prefix must name a directory. Without the trailing `/`, an allowed
`server` would also allow `server-evil/`. `factory paths` refuses a config
that breaks this. -/
def validPrefix (p : String) : Bool := p.endsWith "/" && p != "/"

def Scope.valid (s : Scope) : Bool := !s.allowed.isEmpty && (s.allowed ++ s.protect).all validPrefix

/-- The run-notes file. Its changes are harvested into the run record and
reverted, so the gate does not count them. -/
def notes : String := ".factory/ambiguity-checklist.md"

def underAny (prefixes : List String) (f : String) : Bool :=
  prefixes.any (fun p => f.startsWith p)

/-- A path is fine if some allowed prefix covers it and no protected prefix does. -/
def pathOk (s : Scope) (f : String) : Bool :=
  underAny s.allowed f && !underAny s.protect f

/-- The paths `factory paths` reports as out of scope. -/
def violations (s : Scope) (changed : List String) : List String :=
  changed.filter (fun f => !pathOk s f)

/-- The shipped decision. It fails when nothing changed, or when any changed
path is out of scope. -/
def acceptPaths (s : Scope) (changed : List String) : Bool :=
  !changed.isEmpty && changed.all (pathOk s)

theorem acceptPaths_sound {s : Scope} {changed : List String}
    (h : acceptPaths s changed = true) {f : String} (hf : f ∈ changed) :
    pathOk s f = true := by
  simp only [acceptPaths, Bool.and_eq_true, List.all_eq_true] at h
  exact h.2 f hf

theorem acceptPaths_no_protected {s : Scope} {changed : List String}
    (h : acceptPaths s changed = true) {f : String} (hf : f ∈ changed)
    {p : String} (hp : p ∈ s.protect) : f.startsWith p = false := by
  have h' := acceptPaths_sound h hf
  simp only [pathOk, underAny, Bool.and_eq_true, Bool.not_eq_true',
    List.any_eq_false] at h'
  simpa using h'.2 p hp

/-- The reported violations are exactly why a non-empty change is rejected. -/
theorem acceptPaths_iff {s : Scope} {changed : List String} :
    acceptPaths s changed = true ↔ changed ≠ [] ∧ violations s changed = [] := by
  simp [acceptPaths, violations, List.filter_eq_nil_iff, List.all_eq_true]

/-- The paths the gate checks: everything touched, except the run notes. -/
def changed (ops : List Op) : List String :=
  (ops.flatMap Op.touched).filter (· != notes)

/-- The gate, on what the agent did. -/
def accept (s : Scope) (ops : List Op) : Bool := acceptPaths s (changed ops)

theorem mem_changed {ops : List Op} {op : Op} {f : String}
    (hop : op ∈ ops) (hf : f ∈ op.touched) (hn : f ≠ notes) : f ∈ changed ops := by
  simp only [changed, List.mem_filter, List.mem_flatMap, bne_iff_ne, ne_eq]
  exact ⟨⟨op, hop, hf⟩, hn⟩

/-- An accepted change touches only allowed, unprotected paths. -/
theorem accept_sound {s : Scope} {ops : List Op} (h : accept s ops = true)
    {op : Op} (hop : op ∈ ops) {f : String} (hf : f ∈ op.touched) (hn : f ≠ notes) :
    pathOk s f = true :=
  acceptPaths_sound h (mem_changed hop hf hn)

/-- An accepted change never touches a protected path: not by editing,
adding, or deleting it, and not as either side of a rename. -/
theorem accept_no_protected {s : Scope} {ops : List Op} (h : accept s ops = true)
    {op : Op} (hop : op ∈ ops) {f : String} (hf : f ∈ op.touched) (hn : f ≠ notes)
    {p : String} (hp : p ∈ s.protect) : f.startsWith p = false :=
  acceptPaths_no_protected h (mem_changed hop hf hn) hp

/-- In particular, moving a file out of a protected prefix is rejected. -/
theorem rename_out_rejected {s : Scope} {ops : List Op} {src dst p : String}
    (hop : Op.rename src dst ∈ ops) (hp : p ∈ s.protect)
    (hsrc : src.startsWith p = true) (hn : src ≠ notes) :
    accept s ops = false := by
  cases h : accept s ops with
  | false => rfl
  | true =>
    have := accept_no_protected h hop (by simp [Op.touched]) hn hp
    simp [hsrc] at this

/-- An accepted change always changes something. -/
theorem accept_nonempty {s : Scope} {ops : List Op} (h : accept s ops = true) :
    changed ops ≠ [] :=
  (acceptPaths_iff.mp h).1

/-! ## The bug this replaced

Without `--no-renames`, `git diff --name-only` reports a rename only by its
destination. Modelling that report, the same gate accepts a move out of
`tests/golden/`. -/

def Op.reportedNameOnly : Op → List String
  | .rename _ d => [d]
  | op => op.touched

def acceptNameOnly (s : Scope) (ops : List Op) : Bool :=
  acceptPaths s ((ops.flatMap Op.reportedNameOnly).filter (· != notes))

/-- The QA scope from `orchestrator.config.json`. -/
def qaScope : Scope := { allowed := ["tests/"], protect := ["tests/golden/"] }

/-- Checked with `native_decide` (`String.startsWith` does not reduce in the
kernel), so this one example trusts the compiler. The general theorems above
don't. -/
theorem nameOnly_unsound :
    acceptNameOnly qaScope [.rename "tests/golden/app.js" "tests/app.js"] = true ∧
    accept qaScope [.rename "tests/golden/app.js" "tests/app.js"] = false := by
  native_decide

end Factory.PathGate
