#!/usr/bin/env bash
#
# run-all.sh -- build the Lean gates (which checks every proof and runs the
# build-time tests), audit its axioms, then check the proof-obligation gate,
# the config, and the plumbing around them.
# Usage: bash .factory/lean/scripts/run-all.sh   (or .factory/factory.sh verify)

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LEAN="$ROOT/.factory/lean"
LAKE=$(command -v lake || echo "$HOME/.elan/bin/lake")
BIN="$LEAN/.lake/build/bin/factory"

echo "== lake build (fails on any unproved theorem or failing build-time test)"
(cd "$LEAN" && "$LAKE" build)

echo "== axiom audit: the factory's own theorems use only Lean's standard axioms"
(cd "$LEAN" && "$LAKE" env lean --run "$ROOT/.factory/scripts/check-proofs.lean" audit Factory Factory)
echo "== proof-obligation gate: accepts the honest example, rejects every cheat"
bash "$LEAN/scripts/proofs.test.sh"
echo "== rubric.json is the rubric the theorems are about"
"$BIN" check-rubric "$ROOT/.factory/rubric.json"
echo "== orchestrator.yml matches the Pipeline model"
"$BIN" workflow "$ROOT/.github/workflows/orchestrator.yml"
echo "== path gate plumbing vs model"
FACTORY_BIN="$BIN" bash "$LEAN/scripts/diff-gate.sh" "${GATE_CASES:-150}"
echo "== local run (factory.sh run) end to end, with a stand-in agent"
FACTORY_BIN="$BIN" bash "$ROOT/.factory/scripts/tests/local-run.test.sh"
echo "== gate end-to-end tests"
FACTORY_BIN="$BIN" bash "$ROOT/.factory/scripts/tests/gates.test.sh"
