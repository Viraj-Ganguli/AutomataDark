/-
check-proofs.lean -- the proof-obligation gate.

Run from a product's proofs package, after `lake build`, as
  lake env lean --run check-proofs.lean check <obligations.json>
  lake env lean --run check-proofs.lean audit <Module> <Namespace>

It loads the built environment (the kernel already checked every proof
while building it) and fails unless, for every obligation in the protected
obligations file:
  * the named theorem exists and is a theorem (not an axiom, opaque, or def);
  * its statement is *exactly* `Predicate arg1 arg2 ...`: syntactic equality,
    no unfolding, so it can't be weakened, generalised, or swapped;
  * the predicate is defined in a protected spec module, so the agent can't
    shadow it with a weaker one of the same name;
  * the theorem, and every implementation it is about, use only Lean's three
    standard axioms (propext, Classical.choice, Quot.sound): no `sorry`, no
    custom axiom, no `native_decide` / compiler trust;
and no constant in the package's own modules is an axiom, or swaps in
different runtime code with `@[implemented_by]` / `@[extern]` (other than
the `partial def` machinery), so the code that runs is the code that was
proved.

`audit` applies the axiom and implemented_by checks to every theorem in a
namespace: the factory runs it on its own gates.

This is the `#print axioms` + challenge-statement level of
https://lean-lang.org/doc/reference/latest/ValidatingProofs/ . Agent code
still runs during `lake build`; for a sandboxed rebuild, use `comparator`.
-/
import Lean
open Lean Meta

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def moduleOf (env : Environment) (n : Name) : Option Name :=
  (env.getModuleIdxFor? n).map fun idx => env.header.moduleNames[idx.toNat]!

def underAny (roots : List Name) (m : Name) : Bool := roots.any (·.isPrefixOf m)

/-- `@[implemented_by]` / `@[extern]` problems among the package's own constants. -/
def swapProblems (env : Environment) (roots : List Name) : List String :=
  env.constants.fold (init := []) fun acc n ci =>
    match moduleOf env n with
    | some m =>
      if !underAny roots m then acc else
      let acc := if ci matches .axiomInfo _ then acc ++ [s!"{n}: axiom declared in {m}"] else acc
      let acc := match Compiler.getImplementedBy? env n with
        | some impl => if impl == n ++ `_unsafe_rec then acc
                       else acc ++ [s!"{n}: @[implemented_by {impl}] runs different code than was proved"]
        | none => acc
      if isExtern env n then acc ++ [s!"{n}: @[extern] runs foreign code instead of the Lean definition"] else acc
    | none => acc

def axiomProblems (n : Name) : CoreM (List String) := do
  let axs ← collectAxioms n
  return (axs.toList.filter (!allowedAxioms.contains ·)).map fun a =>
    if a == ``sorryAx then s!"{n}: uses sorry" else s!"{n}: depends on axiom {a}"

def strArr (j : Json) (k : String) : List String :=
  match j.getObjValD k |>.getArr? with
  | .ok a => a.toList.filterMap (·.getStr?.toOption)
  | .error _ => []

def checkObligation (env : Environment) (specRoots : List Name) (o : Json) : CoreM (List String) := do
  let thm := (o.getObjValD "theorem").getStr?.toOption.getD "" |>.toName
  let pred := (o.getObjValD "predicate").getStr?.toOption.getD "" |>.toName
  let args := (strArr o "args").map String.toName
  let some ci := env.find? thm | return [s!"{thm}: not found (the obligation must be proved under exactly this name)"]
  unless ci matches .thmInfo _ do return [s!"{thm}: is not a theorem"]
  let some pci := env.find? pred | return [s!"{pred}: predicate not found"]
  let mut problems : List String := []
  match moduleOf env pred with
  | some m => unless underAny specRoots m do
      problems := problems ++ [s!"{pred}: defined in {m}, not in a protected spec module"]
  | none => problems := problems ++ [s!"{pred}: not defined in an imported module"]
  for a in args do
    if (env.find? a).isNone then problems := problems ++ [s!"{a}: implementation not found"]
  if !pci.levelParams.isEmpty then
    problems := problems ++ [s!"{pred}: universe-polymorphic predicates aren't supported"]
  if problems.isEmpty then
    let expected := mkAppN (mkConst pred) (args.toArray.map mkConst)
    if ci.type.consumeMData != expected then
      problems := problems ++ [s!"{thm}: statement is not exactly `{pred} {" ".intercalate (args.map toString)}`"]
  problems := problems ++ (← axiomProblems thm)
  for a in args do
    if (env.find? a).isSome then problems := problems ++ (← axiomProblems a)
  return problems

def runCore (env : Environment) (x : CoreM α) : IO α := do
  let (a, _) ← x.toIO { fileName := "<check-proofs>", fileMap := default } { env }
  return a

def loadEnv (mods : List Name) : IO Environment := do
  initSearchPath (← findSysroot)
  importModules (mods.toArray.map fun m => { module := m }) {}

def report (title : String) (problems : List String) (okMsg : String) : IO UInt32 := do
  if problems.isEmpty then
    IO.println okMsg
    return 0
  IO.println title
  for p in problems do IO.println s!"  - {p}"
  return 1

def main : List String → IO UInt32
  | ["check", manifestPath] => do
    let j ← match Json.parse (← IO.FS.readFile manifestPath) with
      | .ok j => pure j
      | .error e => IO.eprintln s!"{manifestPath}: {e}"; return 2
    let imports := (strArr j "import").map String.toName
    let specRoots := (strArr j "specModules").map String.toName
    let obligations := (j.getObjValD "obligations").getArr?.toOption.getD #[]
    if imports.isEmpty || specRoots.isEmpty || obligations.isEmpty then
      IO.eprintln s!"{manifestPath}: needs non-empty \"import\", \"specModules\" and \"obligations\""
      return 2
    let env ← loadEnv imports
    let roots := (imports ++ specRoots).map (·.getRoot)
    let mut problems := swapProblems env roots
    for o in obligations do
      problems := problems ++ (← runCore env (checkObligation env specRoots o))
    report "Proof obligations not met:" problems
      s!"All {obligations.size} proof obligation(s) are proved, with exactly the approved statements and only standard axioms."
  | ["audit", m, ns] => do
    let env ← loadEnv [m.toName]
    let nsName := ns.toName
    let thms := env.constants.fold (init := #[]) fun acc n ci =>
      if nsName.isPrefixOf n && (ci matches .thmInfo _) && !n.isInternal then acc.push n else acc
    let mut problems := swapProblems env [nsName.getRoot]
    for t in thms do problems := problems ++ (← runCore env (axiomProblems t))
    report s!"Audit of {ns} failed:" problems
      s!"audit: {thms.size} theorems in {ns} use only standard axioms; no implemented_by/extern swaps or axioms in {ns}."
  | _ => do
    IO.eprintln "usage: check-proofs.lean check <obligations.json> | audit <Module> <Namespace>"
    return 2
