#!/usr/bin/env bash
#
# factory.sh -- entry point for working on the factory locally.
#
#   .factory/factory.sh setup    one-time GitHub setup (idempotent)
#   .factory/factory.sh check    report setup status; changes nothing
#   .factory/factory.sh config   show what each stage resolves to
#   .factory/factory.sh models   validate every stage's model slug
#   .factory/factory.sh build    build the Lean gates (checks every proof)
#   .factory/factory.sh test     end-to-end gate tests
#   .factory/factory.sh verify   build + every conformance and gate test (what CI runs)
#
# Needs: bash, git, jq; gh + curl + openssl for setup; elan (Lean) for build/test/verify.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
S=.factory/scripts
LAKE=$(command -v lake || echo "$HOME/.elan/bin/lake")

case "${1:-}" in
  setup) bash "$S/setup.sh" ;;
  check) bash "$S/setup.sh" --check ;;
  config) for s in qa coder review; do bash "$S/run-agent.sh" --resolve "$s"; done ;;
  models) for s in qa coder review; do bash "$S/run-agent.sh" --check "$s"; done ;;
  build) (cd .factory/lean && "$LAKE" build) ;;
  test) (cd .factory/lean && "$LAKE" build) && bash "$S/tests/gates.test.sh" ;;
  verify) bash .factory/lean/scripts/run-all.sh ;;
  *) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
