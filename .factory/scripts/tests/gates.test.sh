#!/usr/bin/env bash
#
# gates.test.sh -- end-to-end tests for the CI gates, through the same entry
# points the workflow uses: check-paths.sh (git plumbing + `factory paths`),
# `factory red`, and `factory score`. The decisions themselves are proved in
# .factory/lean; these check the plumbing and the command line around them.
#
# Usage: bash .factory/scripts/tests/gates.test.sh   (or .factory/factory.sh test)

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPTS="$ROOT/.factory/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=../factory-bin.sh
. "$SCRIPTS/factory-bin.sh"
export FACTORY_BIN

PASS=0; FAIL=0
expect() {
  # expect <name> <want-exit: 0|nonzero> <got-exit>
  if { [ "$2" = 0 ] && [ "$3" = 0 ]; } || { [ "$2" = nonzero ] && [ "$3" != 0 ]; }; then
    PASS=$((PASS + 1)); echo "  ok    $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $1 (want exit $2, got $3)"
  fi
}

# --- check-paths.sh --------------------------------------------------------

# new_repo <paths-json> -- fresh repo with a golden file, a test, and a server
# file committed; prints nothing, leaves cwd in the repo and BASE set.
new_repo() {
  local dir="$WORK/repo$RANDOM$RANDOM"
  mkdir -p "$dir" && cd "$dir" || exit 1
  git init -q
  mkdir -p tests/golden server .factory
  printf 'a\nb\nc\nd\n' > tests/golden/app.js
  echo 'test' > tests/x.test.js
  echo 'srv' > server/app.js
  touch .factory/ambiguity-checklist.md
  echo "{\"paths\": $1}" > .factory/orchestrator.config.json
  git add -A && git -c user.email=t@t -c user.name=t commit -qm base
  BASE=$(git rev-parse HEAD)
}

gate() { bash "$SCRIPTS/check-paths.sh" "$1" "$BASE" "$WORK/run" >/dev/null 2>&1; echo $?; }

CFG='{"protected":["tests/golden/"],"qa":["tests/"],"coder":["client/","server/"]}'
echo "check-paths.sh"

new_repo "$CFG"; echo more >> tests/x.test.js
expect "qa edits an allowed test" 0 "$(gate qa)"

new_repo "$CFG"; echo hack >> tests/golden/app.js
expect "qa edits a protected file" nonzero "$(gate qa)"

new_repo "$CFG"; git rm -q tests/golden/app.js
expect "qa deletes a protected file" nonzero "$(gate qa)"

new_repo "$CFG"; git mv tests/golden/app.js tests/app.js
expect "qa renames a protected file into its scope" nonzero "$(gate qa)"

new_repo "$CFG"; git mv server/app.js tests/app.js
expect "qa moves a coder file into tests/" nonzero "$(gate qa)"

new_repo "$CFG"; echo x >> server/app.js
expect "qa edits outside its scope" nonzero "$(gate qa)"

new_repo "$CFG"; echo '# note' >> .factory/ambiguity-checklist.md
expect "qa only writes run notes (no product change)" nonzero "$(gate qa)"

new_repo "$CFG"; echo x >> server/app.js; echo '# note' >> .factory/ambiguity-checklist.md
expect "coder edits server/ and writes run notes" 0 "$(gate coder)"

new_repo '{"protected":["tests/golden/"],"qa":["tests"],"coder":["server/"]}'
mkdir -p tests-evil && echo x > tests-evil/a.js
expect "prefix without trailing slash is refused" nonzero "$(gate qa)"

new_repo "$CFG"; echo "k=sk-or-v1-$(printf 'a%.0s' {1..32})" >> tests/x.test.js
expect "qa adds an OpenRouter-shaped key" nonzero "$(gate qa)"

cd "$ROOT" || exit 1

# --- factory red -----------------------------------------------------------

echo "factory red"
FIX="$ROOT/.factory/lean/tests/fixtures"
red() { printf '%s\n' "$2" > "$WORK/changed.txt"; "$FACTORY_BIN" red "$FIX/$1" "$WORK/changed.txt" >/dev/null 2>&1; echo $?; }
expect "pytest: new test fails on an assertion" 0 "$(red pytest-red.xml tests/test_new.py)"
expect "pytest: collection error is not red for the right reason" nonzero "$(red pytest-error.xml tests/test_broken.py)"
expect "pytest: report without file attributes fails closed" nonzero "$(red pytest-xunit2.xml tests/test_new.py)"
expect "jest: new test fails on an assertion" 0 "$(red jest-red.xml tests/new.test.js)"
expect "jest: failure in a file QA didn't touch" nonzero "$(red jest-red.xml tests/ok.test.js)"
expect "jest: suite that failed to run" nonzero "$(red jest-error.xml tests/new.test.js)"
expect "missing report" nonzero "$(red does-not-exist.xml tests/x)"

# --- factory score ---------------------------------------------------------

echo "factory score"

# score <review-json> -- prints "<exit> <pass>"
score() {
  echo "$1" > "$WORK/review.json"
  "$FACTORY_BIN" score "$ROOT/.factory/rubric.json" "$WORK/review.json" "$WORK/out.json" >/dev/null 2>&1
  local code=$?
  echo "$code $(jq -r '.pass' "$WORK/out.json" 2>/dev/null)"
}
all_scores() {
  # all_scores <score> -- every criterion in the real rubric at <score>
  jq -c --argjson s "$1" '{criteria: ([.dimensions[].criteria[].id] | map({(.): {score: $s, comment: "c"}}) | add)}' \
    "$ROOT/.factory/rubric.json"
}
expect_pass() {
  # expect_pass <name> <true|false> <review-json>
  local got; got=$(score "$3")
  if [ "$got" = "0 $2" ]; then PASS=$((PASS + 1)); echo "  ok    $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL  $1 (want '0 $2', got '$got')"; fi
}

FIRST=$(jq -r '.dimensions[0].criteria[0].id' "$ROOT/.factory/rubric.json")
expect_pass "all criteria at 100 passes" true "$(all_scores 100)"
expect_pass "all criteria at 0 fails" false "$(all_scores 0)"
expect_pass "one criterion at 1e6 does not pass" false "{\"criteria\":{\"$FIRST\":{\"score\":1000000}}}"
score "$(all_scores 100 | jq -c ".criteria[\"$FIRST\"].score = -1e9")" >/dev/null
WANT=$(jq '100 - 100 * .dimensions[0].weight / (.dimensions[0].criteria | length)' "$ROOT/.factory/rubric.json")
GOT=$(jq '.overall' "$WORK/out.json")
if [ "$(jq -n "($GOT - $WANT) | fabs < 0.1")" = true ]; then PASS=$((PASS + 1)); echo "  ok    negative score counts as 0, not as a penalty"
else FAIL=$((FAIL + 1)); echo "  FAIL  negative score counts as 0 (want overall $WANT, got $GOT)"; fi
expect_pass "string score counts as 0" false "{\"criteria\":{\"$FIRST\":{\"score\":\"100\"}}}"
expect_pass "missing review output fails" false '{}'
expect_pass "all at 101 does not pass" false "$(all_scores 101)"

jq '.dimensions[0].weight = 5' "$ROOT/.factory/rubric.json" > "$WORK/bad-rubric.json"
all_scores 100 > "$WORK/review.json"
"$FACTORY_BIN" score "$WORK/bad-rubric.json" "$WORK/review.json" "$WORK/out.json" >/dev/null 2>&1
expect "rubric whose weights do not sum to 1 is refused" nonzero $?

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
