#!/usr/bin/env bash
#
# proofs.test.sh -- the proof-obligation gate must accept the honest feed
# example and reject every way an agent could fake or weaken it.
#
# Each case copies examples/feed (without its build cache), rewrites
# Impl/Plan.lean the way a cheating agent might, and runs proofs.sh.
#
# Usage: bash .factory/lean/scripts/proofs.test.sh

set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
EXAMPLE="$ROOT/.factory/lean/examples/feed"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT


PASS=0; FAIL=0
# run_case <name> <want: accept|reject> <python that edits the string `s`>
run_case() {
  local dir="$WORK/case$((PASS + FAIL))"
  rsync -a --exclude .lake "$EXAMPLE/" "$dir/"
  python3 - "$dir/Impl/Plan.lean" "$3" <<'PY'
import sys
p, code = sys.argv[1], sys.argv[2]
s = open(p).read()
exec(code)
open(p, "w").write(s)
PY
  local out got
  out=$(bash "$ROOT/.factory/scripts/proofs.sh" "$dir" 2>&1)
  if [ $? -eq 0 ]; then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1)); echo "  ok    $1"
    # Show why it was rejected, so a rejection for the wrong reason is visible.
    [ "$got" = reject ] && echo "$out" | grep -E '^  - |error:|must match|not found' | head -2 | sed 's/^ */        /'
  else FAIL=$((FAIL + 1)); echo "  FAIL  $1 (want $2, got $got)"; echo "$out" | tail -5 | sed 's/^/        /'; fi
}

PROOF='theorem feedPlan_correct : PlanCorrect feedPlan := by
  intro db h
  simp [feedPlan, feed, newestFirst_eq_reverse _ h]'

echo "proof obligations"
run_case "honest proofs are accepted" accept 'pass'
run_case "sorry in a proof" reject "s = s.replace('''$PROOF''', 'theorem feedPlan_correct : PlanCorrect feedPlan := by sorry')"
run_case "weakened statement (plan equals itself)" reject "s = s.replace('''$PROOF''', 'theorem feedPlan_correct : ∀ db, feedPlan db = feedPlan db := fun _ => rfl')"
run_case "extra hypothesis (assumes False)" reject "s = s.replace('''$PROOF''', 'theorem feedPlan_correct (h : False) : PlanCorrect feedPlan := h.elim')"
run_case "custom axiom" reject "s = s.replace('''$PROOF''', 'axiom cheat : PlanCorrect feedPlan\ntheorem feedPlan_correct : PlanCorrect feedPlan := cheat')"
run_case "native_decide (trusts the compiler)" reject "s = s.replace('''$PROOF''', '''theorem size20 : feedSize = 20 := by native_decide
theorem feedPlan_correct : PlanCorrect feedPlan := by
  have _h := size20
  intro db h
  simp [feedPlan, feed, newestFirst_eq_reverse _ h]''')"
run_case "implemented_by swaps the runtime code" reject "s = s.replace('def feedPlan (db : Db) : List Post := db.posts.reverse.take feedSize', '''def feedPlanFast (db : Db) : List Post := []
@[implemented_by feedPlanFast]
def feedPlan (db : Db) : List Post := db.posts.reverse.take feedSize''')"
run_case "theorem renamed (obligation missing)" reject "s = s.replace('theorem feedPlan_correct :', 'theorem feedPlan_ok :')"
run_case "proof about a different implementation" reject "s = s.replace('''$PROOF''', '''def feedPlan2 (db : Db) : List Post := feed db
theorem feedPlan_correct : PlanCorrect feedPlan2 := fun _ _ => rfl''')"
run_case "implementation replaced by sorry (proof no longer builds)" reject "s = s.replace('def feedPlan (db : Db) : List Post := db.posts.reverse.take feedSize', 'def feedPlan (db : Db) : List Post := sorry')"
run_case "shadowed predicate (spec not imported)" reject "s = '''namespace Spec
def PlanCorrect (_ : Nat) : Prop := True
def CheckSound (_ : Nat) : Prop := True
def InsertPreserves (_ : Nat) : Prop := True
end Spec
namespace Impl
def feedPlan : Nat := 0
def checkInv : Nat := 0
def insertOk : Nat := 0
theorem feedPlan_correct : Spec.PlanCorrect feedPlan := trivial
theorem checkInv_sound : Spec.CheckSound checkInv := trivial
theorem insertOk_preserves : Spec.InsertPreserves insertOk := trivial
end Impl
'''"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
