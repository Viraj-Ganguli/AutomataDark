#!/usr/bin/env bash
#
# local-run.test.sh -- end-to-end test of `factory.sh run` (local-run.sh) with
# a scripted stand-in for the agent (FACTORY_AGENT_CMD), on a tiny product
# written in plain shell, so it needs no model, no subscription, and no
# language toolchain. Checks that an honest run gets through every gate to a
# passing review, and that a coder who edits the tests is stopped before
# anything is committed.
#
# Usage: bash .factory/scripts/tests/local-run.test.sh

set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=../factory-bin.sh
. "$ROOT/.factory/scripts/factory-bin.sh"
export FACTORY_BIN FACTORY_WORKTREES="$WORK/runs"

PROD="$WORK/product"
mkdir -p "$PROD/src" "$PROD/tests/golden"
cd "$PROD" || exit 1
git init -q
rsync -a --exclude .lake "$ROOT/.factory" "$ROOT/.gitignore" .

# The product: src/calc.sh, and a test runner that writes JUnit XML.
printf 'add() { echo $(( $1 + $2 )); }\n' > src/calc.sh
printf '# shared harness (protected)\n' > tests/golden/README.md
printf '. src/calc.sh\n[ "$(add 1 2)" = 3 ]\n' > tests/test_add.sh
cat > tests/run.sh <<'EOF'
#!/usr/bin/env bash
# Runs tests/test_*.sh; with $1, writes a JUnit report there.
fail=0; cases=""
for t in tests/test_*.sh; do
  if bash "$t" >/dev/null 2>&1; then cases="$cases<testcase name=\"$t\" file=\"$t\"/>"
  else fail=1; cases="$cases<testcase name=\"$t\" file=\"$t\"><failure/></testcase>"; fi
done
[ -n "${1:-}" ] && echo "<testsuite>$cases</testsuite>" > "$1"
exit $fail
EOF
jq '.product.test = "bash tests/run.sh" | .product.testReport = "bash tests/run.sh \"$FACTORY_JUNIT\""' \
  "$ROOT/.factory/orchestrator.config.json" > .factory/orchestrator.config.json
git add -A && git -c user.email=t@t -c user.name=t commit -qm "product + factory"

cat > "$WORK/agent.sh" <<'EOF'
#!/usr/bin/env bash
# Stand-in agent: does each stage's job. CHEAT=1 makes the coder edit the tests;
# on model "fast" the coder writes a wrong mul (so the ladder has to escalate).
echo "${FACTORY_LOCAL_MODEL:-default}" >> "$MODELS_SEEN"
case $1 in
  qa) printf '. src/calc.sh\n# AC-1\n[ "$(mul 2 3)" = 6 ]\n' > tests/test_mul.sh
      echo "- AC-1: negative numbers? (assumed any integers)" >> .factory/ambiguity-checklist.md ;;
  coder) if [ "${FACTORY_LOCAL_MODEL:-}" = fast ]; then printf 'mul() { echo 0; }\n' >> src/calc.sh
         else printf 'mul() { echo $(( $1 * $2 )); }\n' >> src/calc.sh; fi
         [ "${CHEAT:-}" = 1 ] && printf 'true\n' > tests/test_mul.sh ;;
  review) jq '{criteria: ([.dimensions[].criteria[].id] | map({(.): {score: 90, comment: "ok"}}) | add)}' \
            .factory/rubric.json > .factory/review-result.json ;;
esac
EOF
chmod +x "$WORK/agent.sh"
export MODELS_SEEN="$WORK/models-seen.txt"
printf '# Add mul\n\n## Acceptance Criteria\n- AC-1: `mul 2 3` prints 6.\n' > "$WORK/spec.md"

PASS=0; FAIL=0
check() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); echo "  ok    $1"; else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; fi; }

echo "local run"
OUT=$(FACTORY_AGENT_CMD="$WORK/agent.sh" bash .factory/factory.sh run "$WORK/spec.md" 2>&1)
STATUS=$?
check "honest run completes" "$STATUS"
echo "$OUT" | grep -q "Suite is red for the right reason"; check "QA's tests pass the red check" $?
echo "$OUT" | grep -q "Rubric: 90 / 100 (PASS)"; check "review is scored" $?
echo "$OUT" | grep -q "negative numbers?"; check "agents' open questions are reported" $?
BRANCH=$(git for-each-ref --format='%(refname:short)' 'refs/heads/agent/local-*' | head -1)
[ "$(git log --oneline "$BRANCH" | wc -l | tr -d ' ')" = 3 ]; check "branch has the QA and coder commits" $?
[ -z "$(git status --porcelain)" ] && [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; check "your checkout is untouched" $?
! git log --stat "HEAD..$BRANCH" | grep -q ambiguity-checklist; check "run notes are not committed" $?

OUT=$(CHEAT=1 FACTORY_AGENT_CMD="$WORK/agent.sh" bash .factory/factory.sh run "$WORK/spec.md" 2>&1)
STATUS=$?
[ "$STATUS" != 0 ] && echo "$OUT" | grep -q "touched paths outside its write scope"; check "a coder that edits the tests is stopped" $?

rm -f "$MODELS_SEEN"
OUT=$(FACTORY_LOCAL_MODEL=reviewer FACTORY_LOCAL_CODER_MODELS=fast,strong FACTORY_AGENT_CMD="$WORK/agent.sh" bash .factory/factory.sh run "$WORK/spec.md" 2>&1)
STATUS=$?
[ "$STATUS" = 0 ] && [ "$(paste -sd, - < "$MODELS_SEEN")" = reviewer,fast,strong,reviewer ] \
  && echo "$OUT" | grep -q "Coder attempts: fast,strong"; check "a red fast attempt escalates to the strong model; other stages keep theirs" $?

A=$(FACTORY_AGENT_CMD="$WORK/agent.sh" FACTORY_STAGES=qa bash .factory/factory.sh run "$WORK/spec.md" 2>&1 | sed -n 's/^  branch    //p')
B=$(FACTORY_AGENT_CMD="$WORK/agent.sh" FACTORY_STAGES=qa bash .factory/factory.sh run "$WORK/spec.md" 2>&1 | sed -n 's/^  branch    //p')
[ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ]; check "back-to-back runs of one spec get separate branches" $?

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
