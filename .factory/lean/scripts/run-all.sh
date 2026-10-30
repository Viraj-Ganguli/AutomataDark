#!/usr/bin/env bash
#
# run-all.sh -- build the Lean gates (which checks every proof and runs the
# build-time tests), then check the config and plumbing around them.
# Usage: bash .factory/lean/scripts/run-all.sh   (or .factory/factory.sh verify)

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LEAN="$ROOT/.factory/lean"
LAKE=$(command -v lake || echo "$HOME/.elan/bin/lake")
BIN="$LEAN/.lake/build/bin/factory"

echo "== lake build (fails on any unproved theorem or failing build-time test)"
(cd "$LEAN" && "$LAKE" build)
if grep -rnE '\bsorry\b|^\s*axiom\b' "$LEAN/Factory" "$LEAN/Main.lean"; then
  echo ".factory/lean: sorry or axiom found -- every theorem must be proved" >&2
  exit 1
fi

echo "== rubric.json is the rubric the theorems are about"
"$BIN" check-rubric "$ROOT/.factory/rubric.json"
echo "== orchestrator.yml matches the Pipeline model"
"$BIN" workflow "$ROOT/.github/workflows/orchestrator.yml"
echo "== path gate plumbing vs model"
FACTORY_BIN="$BIN" bash "$LEAN/scripts/diff-gate.sh" "${GATE_CASES:-150}"
echo "== gate end-to-end tests"
FACTORY_BIN="$BIN" bash "$ROOT/.factory/scripts/tests/gates.test.sh"
