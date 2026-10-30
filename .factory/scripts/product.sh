#!/usr/bin/env bash
#
# product.sh -- run the product's own commands, as declared in the "product"
# block of .factory/orchestrator.config.json. This is the only place the
# factory touches the product's stack: the factory itself assumes no
# language, package manager, or test framework.
#
#   "product": {
#     "setup":      "pip install -r requirements.txt",
#     "test":       "pytest",
#     "testReport": "pytest -o junit_family=xunit1 --junitxml=\"$FACTORY_JUNIT\"",
#     "env":        { "DATABASE_URL": "postgres://..." }
#   }
#
# Usage: product.sh setup | test | test-report | env | tool-pattern | configured | show <key>
#
#   setup         install toolchain/dependencies, start services, migrate
#   test          run the suite; exit status is the verdict
#   test-report   run the suite writing JUnit XML to $FACTORY_JUNIT (for `factory red`)
#   env           print product.env as KEY=VALUE lines (for $GITHUB_ENV)
#   tool-pattern  the harness permission for the test command, e.g. Bash(pytest*)
#   configured    exit 0 if product.test is set
#   show <key>    print product.<key>
#
# Commands run with the factory's key material removed from their environment:
# agent-written code runs here.

set -euo pipefail

CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"
export FACTORY_JUNIT="${FACTORY_JUNIT:-${RUNNER_TEMP:-/tmp}/factory-junit.xml}"

get() { jq -r --arg k "$1" '.product[$k] // ""' "$CONFIG"; }

need() {
  local cmd; cmd=$(get "$1")
  if [ -z "$cmd" ]; then
    echo "product.sh: product.$1 is not set in $CONFIG -- see README \"Plug in your product\"" >&2
    exit 2
  fi
  printf '%s' "$cmd"
}

run() { env -u FACTORY_KEY_PASSPHRASE -u OPENROUTER_KEY_CIPHER -u OPENROUTER_API_KEY bash -c "$1"; }

case "${1:-}" in
  setup)
    cmd=$(get setup)
    if [ -z "$cmd" ]; then echo "product.setup is empty; nothing to set up."; exit 0; fi
    run "$cmd" ;;
  test) cmd=$(need test) || exit 2; run "$cmd" ;;
  test-report)
    cmd=$(need testReport) || exit 2
    rm -f "$FACTORY_JUNIT"
    run "$cmd" ;;
  env) jq -r '.product.env // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG" ;;
  tool-pattern) cmd=$(need test) || exit 2; printf 'Bash(%s*)' "$cmd" ;;
  configured) [ -n "$(get test)" ] ;;
  show) get "${2:?usage: product.sh show <key>}" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
