/-!
# Red check (`factory red`)

After the QA agent writes tests, the suite must be red *for the right reason*
(`.factory/qa.nlspec.md`, required behavior 4):

* something failed as an assertion, in a test file the QA agent changed;
* nothing errored (a syntax error, bad import, or broken fixture means the
  failure isn't pointing at missing behavior);
* no test in a file the QA agent didn't touch fails (QA must not break the
  existing suite);
* every test case can be attributed to a file. If it can't, the previous rule
  can't be checked, so the gate fails closed.

The input is any JUnit XML report (`Factory.JUnit` parses it), so this works
for any test runner that can write one: pytest, jest-junit, go-junit-report,
cargo-nextest, Maven Surefire, RSpec, and so on.

The main result is `redOk_sound`.
-/

namespace Factory.Red

inductive Outcome where
  | passed | failed | errored | skipped
  deriving DecidableEq, Repr

structure Case where
  /-- Repo-relative test file, or `""` if the report doesn't say. -/
  file : String
  name : String
  outcome : Outcome
  deriving Repr

def unattributed (cases : List Case) : List Case := cases.filter (·.file == "")

def errored (cases : List Case) : List Case := cases.filter (·.outcome == .errored)

def failedOutside (changed : List String) (cases : List Case) : List Case :=
  cases.filter (fun c => c.outcome == .failed && !changed.contains c.file)

def failedInside (changed : List String) (cases : List Case) : List Case :=
  cases.filter (fun c => c.outcome == .failed && changed.contains c.file)

/-- The shipped decision. -/
def redOk (changed : List String) (cases : List Case) : Bool :=
  (unattributed cases).isEmpty && (errored cases).isEmpty &&
    (failedOutside changed cases).isEmpty && !(failedInside changed cases).isEmpty

/-- What `factory red` prints when the check fails. -/
def problems (changed : List String) (cases : List Case) : List String :=
  (unattributed cases).map (fun c =>
    s!"{c.name}: the report doesn't say which file this test is in, so the check fails closed (enable the file attribute in your JUnit reporter)") ++
  (errored cases).map (fun c =>
    s!"{c.file}: {c.name}: errored (not an assertion failure): fix the load/setup error") ++
  (failedOutside changed cases).map (fun c =>
    s!"{c.file}: {c.name}: a test the QA agent didn't touch now fails: QA must not break the existing suite") ++
  (if (failedInside changed cases).isEmpty then
    ["no test assertion failed in the files the QA agent changed: the new tests are not red"]
  else [])

theorem redOk_sound {changed : List String} {cases : List Case}
    (h : redOk changed cases = true) :
    (∃ c ∈ cases, c.outcome = .failed ∧ c.file ∈ changed) ∧
    (∀ c ∈ cases, c.outcome ≠ .errored) ∧
    (∀ c ∈ cases, c.outcome = .failed → c.file ∈ changed) ∧
    (∀ c ∈ cases, c.file ≠ "") := by
  simp only [redOk, Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_iff,
    List.isEmpty_eq_false_iff] at h
  obtain ⟨⟨⟨hu, he⟩, ho⟩, hi⟩ := h
  refine ⟨?_, ?_, ?_, ?_⟩
  · obtain ⟨c, hc⟩ := List.exists_mem_of_ne_nil _ hi
    simp only [failedInside, List.mem_filter, Bool.and_eq_true, beq_iff_eq,
      List.contains_iff_mem] at hc
    exact ⟨c, hc.1, hc.2.1, hc.2.2⟩
  · intro c hc
    simpa using List.filter_eq_nil_iff.mp he c hc
  · intro c hc hf
    have := List.filter_eq_nil_iff.mp ho c hc
    simp_all
  · intro c hc
    simpa using List.filter_eq_nil_iff.mp hu c hc

/-- And the problem list is empty exactly when the check passes. -/
theorem problems_nil_iff {changed : List String} {cases : List Case} :
    problems changed cases = [] ↔ redOk changed cases = true := by
  simp only [problems, redOk, List.append_eq_nil_iff, List.map_eq_nil_iff,
    Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_iff, List.isEmpty_eq_false_iff]
  constructor
  · rintro ⟨⟨⟨hu, he⟩, ho⟩, hi⟩
    refine ⟨⟨⟨hu, he⟩, ho⟩, ?_⟩
    intro hnil
    simp [hnil] at hi
  · rintro ⟨⟨⟨hu, he⟩, ho⟩, hi⟩
    exact ⟨⟨⟨hu, he⟩, ho⟩, by simp [hi]⟩

end Factory.Red
