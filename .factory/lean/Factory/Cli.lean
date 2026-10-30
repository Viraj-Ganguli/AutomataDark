import Lean.Data.Json
import Factory.PathGate
import Factory.Red
import Factory.JUnit
import Factory.Rubric
import Factory.Workflow

/-!
# The `factory` command line

Input/output around the proved decision functions. Every pass/fail below
comes from `PathGate.acceptPaths`, `Red.redOk`, or `Rubric.pass`, the
functions the theorems are about. This file only reads files, converts
JSON, and formats messages.
-/

namespace Factory.Cli
open Lean

def fail (msg : String) : IO UInt32 := do IO.eprintln msg; return 2

def readJson (path : String) : IO (Except String Json) := do
  try
    return Json.parse (← IO.FS.readFile path)
  catch e => return .error s!"{path}: {e}"

def configPath : IO String := do
  return (← IO.getEnv "ORCHESTRATOR_CONFIG").getD ".factory/orchestrator.config.json"

def strArray (j : Json) : List String :=
  match j.getArr? with
  | .ok a => a.toList.filterMap (fun x => x.getStr?.toOption)
  | .error _ => []

def readLines (s : String) : List String :=
  (s.splitOn "\n").map (fun l => (l.trimAscii).toString) |>.filter (· != "")

def loadScope (stage : String) : IO (Except String PathGate.Scope) := do
  let cfg ← configPath
  match ← readJson cfg with
  | .error e => return .error e
  | .ok j =>
    let paths := j.getObjValD "paths"
    let s : PathGate.Scope :=
      { allowed := strArray (paths.getObjValD stage), protect := strArray (paths.getObjValD "protected") }
    if s.allowed.isEmpty then
      return .error s!"factory paths: no .paths.{stage} in {cfg}; refusing to allow every path"
    match (s.allowed ++ s.protect).find? (!PathGate.validPrefix ·) with
    | some p => return .error s!"factory paths: prefix '{p}' in {cfg} must end in '/'"
    | none => return .ok s

def bullets (ps : List String) : String := "\n".intercalate (ps.map (s!"- `{·}`"))

/-- `factory describe <stage>`: the write scope as markdown, for the agent's prompt. -/
def describe (stage : String) : IO UInt32 := do
  match ← loadScope stage with
  | .error e => fail e
  | .ok s =>
    IO.println s!"## Write scope (enforced by CI)

You may create or edit files only under:

{bullets s.allowed}

You must never modify (the job fails if you do):

{bullets s.protect}
- anything else outside the paths above

Record open questions by appending to `{PathGate.notes}`. CI moves them into the
PR description for a human, and they are not committed."
    return 0

/-- `factory paths <stage>`: changed paths on stdin, one per line. -/
def paths (stage : String) : IO UInt32 := do
  match ← loadScope stage with
  | .error e => fail e
  | .ok s =>
    let changed := readLines (← (← IO.getStdin).readToEnd)
    if PathGate.acceptPaths s changed then
      IO.println s!"All changes are inside the {stage} write scope."
      return 0
    if changed.isEmpty then
      IO.println s!"The {stage} agent made no product changes."
    else
      IO.println s!"The {stage} agent touched paths outside its write scope ({" ".intercalate s.allowed}):"
      for f in PathGate.violations s changed do IO.println s!"  {f}"
    return 1

def normalize (root f : String) : String :=
  let f := if root != "" && f.startsWith (root ++ "/") then (f.drop (root.length + 1)).toString else f
  if f.startsWith "./" then (f.drop 2).toString else f

/-- `factory red <junit.xml> <changed.txt>`: is the suite red for the right reason? -/
def red (report changedFile : String) : IO UInt32 := do
  let xml ← try IO.FS.readFile report catch _ =>
    IO.println s!"No JUnit report at {report}. Check product.testReport in the config writes to $FACTORY_JUNIT."
    return 1
  let root := (← IO.currentDir).toString
  let cases := (JUnit.parse xml).toList.map fun c => { c with file := normalize root c.file }
  let changed := readLines (← IO.FS.readFile changedFile)
  if Red.redOk changed cases then
    let n := (Red.failedInside changed cases).length
    IO.println s!"Suite is red for the right reason: {n} failing test(s), all in files the QA agent changed ({cases.length} test cases in the report)."
    return 0
  IO.println "Suite is red for the wrong reason:"
  for p in Red.problems changed cases do IO.println s!"  - {p}"
  return 1

/-- A JSON number as `(numerator, exponent)`: value = m / 10^e. -/
def numParts (j : Json) : Option (Int × Nat) :=
  match j with
  | .num n => some (n.mantissa, n.exponent)
  | _ => none

/-- A review score, as the `Int` that `Rubric.sanitize` expects. A number in
[0, 100] is rounded down; anything else becomes -1, so `sanitize` counts it as 0. -/
def scoreOf (j : Json) : Int :=
  match numParts j with
  | some (m, e) => if 0 ≤ m && m ≤ 100 * ((10 ^ e : Nat) : Int) then m / ((10 ^ e : Nat) : Int) else -1
  | none => -1

structure RubricDim where
  id : String
  label : String
  weight : Int × Nat
  criteria : List String

structure LoadedRubric where
  dims : List RubricDim
  /-- Weight numerators over `W`. -/
  weights : List Nat
  W : Nat
  tn : Nat
  tden : Nat
  threshold : Json

def loadRubric (path : String) : IO (Except String LoadedRubric) := do
  match ← readJson path with
  | .error e => return .error e
  | .ok j =>
    let dimsJ := (j.getObjValD "dimensions").getArr?.toOption.getD #[]
    let dims := dimsJ.toList.map fun d =>
      { id := (d.getObjValD "id").getStr?.toOption.getD "",
        label := (d.getObjValD "label").getStr?.toOption.getD "",
        weight := (numParts (d.getObjValD "weight")).getD (-1, 0),
        criteria := ((d.getObjValD "criteria").getArr?.toOption.getD #[]).toList.map
          (fun c => (c.getObjValD "id").getStr?.toOption.getD "") : RubricDim }
    let E := dims.foldl (fun acc d => max acc d.weight.2) 0
    let ws : List Int := dims.map fun d => d.weight.1 * ((10 ^ (E - d.weight.2) : Nat) : Int)
    let thr := j.getObjValD "passThreshold"
    let bad := "rubric weights must be >= 0 and sum to 1, every dimension needs a criterion, and passThreshold must be in [0, 100]"
    match numParts thr with
    | none => return .error bad
    | some (tm, te) =>
      if dims.isEmpty || ws.any (· < 0) || ws.foldl (· + ·) 0 != ((10 ^ E : Nat) : Int) ||
          dims.any (·.criteria.isEmpty) || tm < 0 || tm > 100 * ((10 ^ te : Nat) : Int) then
        return .error bad
      return .ok { dims, weights := ws.map Int.toNat, W := 10 ^ E,
                   tn := tm.toNat, tden := 10 ^ te, threshold := thr }

def fmt1 (tenths : Nat) : String := s!"{tenths / 10}.{tenths % 10}"

def tenthsJson (tenths : Nat) : Json :=
  if tenths % 10 == 0 then .num ⟨(tenths / 10 : Nat), 0⟩ else .num ⟨tenths, 1⟩

/-- `factory score <rubric.json> <review-result.json> <out-summary.json>`. -/
def score (rubricPath resultPath outPath : String) : IO UInt32 := do
  let r ← match ← loadRubric rubricPath with
    | .ok r => pure r
    | .error e => return ← fail s!"factory score: {e}"
  let result := (← readJson resultPath).toOption.getD Json.null
  let crit := result.getObjValD "criteria"
  let mut lines : Array String := #["## Automated rubric review", ""]
  let mut scores : List (List Int) := []
  let mut dimOut : List (String × Json) := []
  let dims : List Rubric.Dim := r.dims.zip r.weights |>.map fun (d, w) => ⟨w, d.criteria.length⟩
  let D := dims.foldl (fun acc d => acc * d.n) 1
  for (d, dd) in r.dims.zip dims do
    let mut rows : Array String := #[]
    let mut ss : List Int := []
    for cid in d.criteria do
      let entry := crit.getObjVal? cid |>.toOption
      let (s, comment) := match entry with
        | none => ((0 : Int), "_missing from review output_")
        | some e =>
          let raw := e.getObjValD "score"
          let s := scoreOf raw
          let c := (e.getObjValD "comment").getStr?.toOption.getD "_missing from review output_"
          if s < 0 then (s, s!"_invalid score {raw.compress}, counted as 0_ -- {c}") else (s, c)
      ss := ss ++ [s]
      rows := rows.push s!"| `{cid}` | {Rubric.sanitize s} | {comment} |"
    scores := scores ++ [ss]
    let sum := Rubric.dimSum ss
    let avgT := (20 * sum + dd.n) / (2 * dd.n)
    dimOut := dimOut ++ [(d.id, tenthsJson avgT)]
    lines := lines ++ #[s!"### {d.label} (weight {(Json.num ⟨d.weight.1, d.weight.2⟩).compress}, avg {fmt1 avgT})", "",
      "| Criterion | Score | Comment |", "| --- | --- | --- |"] ++ rows ++ #[""]
  let scaled := Rubric.scaled D dims scores
  let pass := Rubric.pass r.tn r.tden r.W D dims scores
  let overallT := (20 * scaled + r.W * D) / (2 * r.W * D)
  lines := lines ++ #[s!"### Overall: {fmt1 overallT} / 100 (pass threshold {r.threshold.compress})", "",
    if pass then "**Result: PASS**" else "**Result: FAIL**"]
  let out := Json.mkObj [("overall", tenthsJson overallT), ("pass", .bool pass),
    ("passThreshold", r.threshold), ("dimensions", Json.mkObj dimOut)]
  IO.FS.writeFile outPath (out.pretty ++ "\n")
  IO.println ("\n".intercalate lines.toList)
  return 0

/-- `factory check-rubric <rubric.json>`: the rubric is the one the `Rubric`
theorems (`lone_criterion_fails`, `two_security_zeros_pass`, ...) are about. -/
def checkRubric (path : String) : IO UInt32 := do
  match ← loadRubric path with
  | .error e => fail s!"factory check-rubric: {e}"
  | .ok r =>
    let ws := r.weights.map (· * 100 / r.W)
    let ok := r.weights.all (fun w => w * 100 % r.W == 0) &&
      (ws.zip (r.dims.map (·.criteria.length))) == Rubric.current.map (fun d => (d.weight, d.n)) &&
      r.tn == Rubric.threshold * r.tden
    if ok then
      IO.println "check-rubric: rubric.json matches Factory.Rubric.current."
      return 0
    IO.println "rubric.json no longer matches Factory.Rubric.current. Update the Lean constants and re-prove."
    return 1

/-- `factory workflow <orchestrator.yml>`. -/
def workflow (path : String) : IO UInt32 := do
  let problems := Workflow.check (← IO.FS.readFile path)
  if problems.isEmpty then
    IO.println s!"check-workflow: {(Workflow.parseJobs (← IO.FS.readFile path)).size} jobs and the qa/coder gate steps match the Pipeline model."
    return 0
  IO.println s!"{path} no longer matches what Factory.Pipeline assumes:"
  for p in problems do IO.println s!"  {p}"
  return 1

/-- `factory model-gate`: the operations-level model, for `scripts/diff-gate.sh`.
stdin: `allow P`, `protect P`, `edit P`, `add P`, `delete P`, `rename SRC DST`. -/
def modelGate : IO UInt32 := do
  let mut scope : PathGate.Scope := { allowed := [], protect := [] }
  let mut ops : List PathGate.Op := []
  for l in readLines (← (← IO.getStdin).readToEnd) do
    match (l.splitOn " ").filter (· != "") with
    | ["allow", p] => scope := { scope with allowed := scope.allowed ++ [p] }
    | ["protect", p] => scope := { scope with protect := scope.protect ++ [p] }
    | ["edit", p] => ops := ops ++ [.edit p]
    | ["add", p] => ops := ops ++ [.add p]
    | ["delete", p] => ops := ops ++ [.delete p]
    | ["rename", s, d] => ops := ops ++ [.rename s d]
    | _ => return ← fail s!"bad line: {l}"
  IO.println (if PathGate.accept scope ops then "accept" else "reject")
  return 0

def usage : String := "usage: factory <command>

  paths <stage>                       changed paths on stdin -> exit 0 if in scope
  describe <stage>                    print the stage's write scope (markdown)
  red <junit.xml> <changed.txt>       is the QA suite red for the right reason?
  score <rubric> <review> <out.json>  weighted rubric score; prints a markdown report
  check-rubric <rubric.json>          rubric matches the one the theorems are about
  workflow <orchestrator.yml>         job graph matches the Pipeline model
  model-gate                          operations-level path model (for diff-gate.sh)"

def main : List String → IO UInt32
  | ["paths", stage] => paths stage
  | ["describe", stage] => describe stage
  | ["red", report, changed] => red report changed
  | ["score", r, res, out] => score r res out
  | ["check-rubric", r] => checkRubric r
  | ["workflow", y] => workflow y
  | ["model-gate"] => modelGate
  | _ => fail usage

end Factory.Cli
