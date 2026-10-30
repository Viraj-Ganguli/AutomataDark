import Factory.Pipeline

/-!
# Workflow conformance (`factory workflow`)

`Factory.Pipeline` proves properties of a model of `orchestrator.yml`. This
check fails if the YAML has drifted from what that model assumes:

* every job's `needs:` and job-level `if:` match `Pipeline.jobTable`;
* in the qa and coder jobs, each gate step exists, runs the gate command,
  comes before the push, and has no `if:` or `continue-on-error:`; the push
  step has no `if:` either. `Pipeline.run` takes these step-level facts as
  given (`qaPushed` and `coderPushed`).

It is a line-based reader for the YAML layout this repo uses (jobs at 2-space
indent, job keys at 4, steps at `      - `), not a YAML parser. Anything it
doesn't recognise makes the check fail, not pass.
-/

namespace Factory.Workflow

structure Job where
  name : String
  needs : List String := []
  cond : String := ""
  steps : Array (List String) := #[]
  deriving Inhabited

def indent (l : String) : Nat := (l.toList.takeWhile (· == ' ')).length

def strip (l : String) : String := (l.trimAscii).toString

def afterKey (l key : String) : Option String :=
  let t := strip l
  if t.startsWith key then some (strip (t.drop key.length).toString) else none

def isJobLine (l : String) : Bool :=
  indent l == 2 && (strip l).endsWith ":" && !(strip l).contains ' ' && !(strip l).startsWith "#"

def parseJobs (yml : String) : Array Job := Id.run do
  let mut jobs : Array Job := #[]
  let mut inJobs := false
  for l in yml.splitOn "\n" do
    if strip l == "jobs:" && indent l == 0 then
      inJobs := true
      continue
    if !inJobs then continue
    if indent l == 0 && !(strip l).isEmpty then break
    if isJobLine l then
      jobs := jobs.push { name := ((strip l).dropEnd 1).toString }
    else if jobs.size > 0 then
      let j := jobs.back!
      if indent l == 6 && (strip l).startsWith "- " then
        jobs := jobs.pop.push { j with steps := j.steps.push [l] }
      else if indent l ≥ 7 && j.steps.size > 0 then
        jobs := jobs.pop.push { j with steps := j.steps.pop.push (j.steps.back! ++ [l]) }
      else if indent l == 4 then
        if let some v := afterKey l "needs:" then
          let inner := ((v.dropWhile (· == '[')).dropEndWhile (· == ']')).toString
          let needs := (inner.splitOn ",").map strip |>.filter (· != "")
          jobs := jobs.pop.push { j with needs }
        else if let some v := afterKey l "if:" then
          jobs := jobs.pop.push { j with cond := v }
  return jobs

def stepName (st : List String) : String :=
  match st.head? with
  | some l => ((afterKey l "- name:").getD "")
  | none => ""

def stepHas (st : List String) (s : String) : Bool := st.any (fun l => (l.splitOn s).length > 1)

def stepGuarded (st : List String) : Bool :=
  st.any fun l =>
    let t := strip l
    t.startsWith "if:" || t.startsWith "- if:" || t.startsWith "continue-on-error:"

/-- For each job: (gate step name, command it must run) in order, then the push step's name. -/
def stepRules : List (String × List (String × String) × String) :=
  [ ("qa", [("Enforce QA write scope (factory/product boundary)", "check-paths.sh qa \""),
            ("Run test suite (expect red, for the right reason)", "factory red ")],
      "Commit and push QA tests"),
    ("coder", [("Enforce coder write scope (factory/product boundary)", "check-paths.sh coder \""),
               ("Run test suite (must be green)", "product.sh test")],
      "Commit and push coder changes") ]

def check (yml : String) : List String := Id.run do
  let jobs := parseJobs yml
  let mut problems : List String := []
  let actual := jobs.toList.map fun j => (j.name, j.needs, j.cond)
  for e in Pipeline.jobTable do
    if !actual.contains e then
      problems := problems ++ [s!"model only: {e.1}|{",".intercalate e.2.1}|{e.2.2}"]
  for a in actual do
    if !Pipeline.jobTable.contains a then
      problems := problems ++ [s!"yaml only:  {a.1}|{",".intercalate a.2.1}|{a.2.2}"]
  for (jobName, gates, pushName) in stepRules do
    match jobs.find? (·.name == jobName) with
    | none => problems := problems ++ [s!"{jobName}: job not found"]
    | some j =>
      let steps := j.steps.toList
      match steps.findIdx? (fun st => stepName st == pushName) with
      | none => problems := problems ++ [s!"{jobName}: no step named '{pushName}'"]
      | some pushAt =>
        if !stepHas steps[pushAt]! "git push" then
          problems := problems ++ [s!"{jobName}: '{pushName}' doesn't run git push"]
        if stepGuarded steps[pushAt]! then
          problems := problems ++ [s!"{jobName}: '{pushName}' has an if:/continue-on-error"]
        let mut prev := 0
        for (gate, cmd) in gates do
          match steps.findIdx? (fun st => stepName st == gate) with
          | none => problems := problems ++ [s!"{jobName}: no step named '{gate}'"]
          | some idx =>
            if !stepHas steps[idx]! cmd then
              problems := problems ++ [s!"{jobName}: '{gate}' doesn't run `{cmd}`"]
            if idx > pushAt then
              problems := problems ++ [s!"{jobName}: '{gate}' runs after the push"]
            if idx < prev then
              problems := problems ++ [s!"{jobName}: '{gate}' is out of order"]
            if stepGuarded steps[idx]! then
              problems := problems ++ [s!"{jobName}: '{gate}' has an if:/continue-on-error"]
            prev := idx
  return problems

end Factory.Workflow
