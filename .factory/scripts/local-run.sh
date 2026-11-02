#!/usr/bin/env bash
#
# local-run.sh -- run the whole QA -> Coder -> Review pipeline on your machine,
# on your Claude Code or Codex subscription. Same prompts (prompt.sh), same
# gates (path gate, red check, tests, rubric score) as the
# orchestrator in CI; no GitHub Actions, no OpenRouter, no API keys.
#
# Usage (from the product repo):
#   .factory/factory.sh run <nlspec.md>     an NLSpec file: "# Title", then the body
#   .factory/factory.sh run <issue-number>  a GitHub issue (needs gh)
#
# Options (env):
#   FACTORY_LOCAL_HARNESS=claude|codex   which CLI (default: config harness / whatever is installed)
#   FACTORY_LOCAL_MODEL=...              model override for that CLI
#   FACTORY_STAGES=qa,coder,review       which stages to run (default all three)
#   FACTORY_LOCAL_CODER_MODELS=a,b,...   model per coder attempt, e.g. "haiku,opus":
#                                        a fast model first, a strong one if the
#                                        suite is still red (the last one repeats;
#                                        attempts = max(maxAttempts, list length)).
#                                        Each attempt builds on the previous edits.
#
# The run happens in a new git worktree on branch agent/local-<slug>-<time>,
# created from your current commit, so your checkout is never touched. The run
# record (prompts, agent output, notes, scores) goes next to it in
# <worktree>.record/ and is never committed. Nothing is pushed: the summary
# prints the commands to open a PR or throw the run away.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
SRC=.factory/scripts
STAGES=",${FACTORY_STAGES:-qa,coder,review},"
INPUT="${1:?usage: factory.sh run <nlspec.md | issue-number>}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------

bash "$SRC/local-agent.sh" --check || die "Fix the login above, then re-run."
bash "$SRC/product.sh" configured \
  || die "Set product.test (and product.testReport for the red check) in .factory/orchestrator.config.json -- see README 'Plug in your product'."
[ -z "$(git status --porcelain)" ] \
  || echo "Note: you have uncommitted changes; the run starts from your last commit ($(git rev-parse --short HEAD)) and won't see them."

# The gate binary: build it once if needed (needs elan: https://github.com/leanprover/elan).
if [ -z "${FACTORY_BIN:-}" ] && [ ! -x .factory/lean/.lake/build/bin/factory ]; then
  LAKE=$(command -v lake || echo "$HOME/.elan/bin/lake")
  [ -x "$LAKE" ] || die "Install elan (the Lean toolchain manager) first: curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh"
  say "Building the factory gates (first run only; checks every proof)"
  (cd .factory/lean && "$LAKE" build 2>&1 | tail -3) || die "Building the gates failed."
fi
. "$SRC/factory-bin.sh"

# Snapshot the rules before any agent runs, exactly like CI: editing the
# scripts, config, or gates in the worktree can't change how the run is judged.
SNAP=$(mktemp -d)
cp "$SRC"/*.sh .factory/orchestrator.config.json "$SNAP/"
cp "$FACTORY_BIN" "$SNAP/factory"
export FACTORY_BIN="$SNAP/factory" ORCHESTRATOR_CONFIG="$SNAP/orchestrator.config.json"
S="$SNAP"

# --- the issue -------------------------------------------------------------

ISSUE_MD="$SNAP/issue.md"
if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
  gh issue view "$INPUT" --json title,body --jq '"# " + .title + "\n\n" + .body' > "$ISSUE_MD"
  REF="#$INPUT"
else
  [ -f "$INPUT" ] || die "No such NLSpec file: $INPUT"
  cp "$INPUT" "$ISSUE_MD"
fi
TITLE=$(sed -n 's/^# *//p' "$ISSUE_MD" | head -1)
SLUG=$(echo "${TITLE:-issue}" | tr '[:upper:]' '[:lower:]' | sed -E 's/\[nlspec\]//g; s/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
REF="${REF:-local: $SLUG}"

# --- worktree ----------------------------------------------------------------

STAMP=$(date +%Y%m%d-%H%M%S)
# Two runs of one spec in the same second would collide; number the later one.
n=1; base=$STAMP
while git show-ref -q --verify "refs/heads/agent/local-${SLUG:-issue}-$STAMP"; do n=$((n + 1)); STAMP="$base-$n"; done
BRANCH="agent/local-${SLUG:-issue}-$STAMP"
WT_ROOT="${FACTORY_WORKTREES:-$(dirname "$ROOT")/$(basename "$ROOT")-agent-runs}"
WT="$WT_ROOT/${SLUG:-issue}-$STAMP"
RUN="$WT.record"
mkdir -p "$WT_ROOT" "$RUN"
START=$(git rev-parse HEAD)
git worktree add -q -b "$BRANCH" "$WT" "$START"
cd "$WT"
export FACTORY_JUNIT="$RUN/junit.xml" FACTORY_USAGE_LOG="$RUN/usage.jsonl"
TEST_CMD=$(bash "$S/product.sh" show test); export TEST_CMD
TEST_TOOL=$(bash "$S/product.sh" tool-pattern)
GIT=(git -c core.hooksPath=/dev/null -c user.name="factory (local)" -c user.email="factory@localhost")

echo "Run: $REF"
echo "  branch    $BRANCH"
echo "  worktree  $WT"
echo "  record    $RUN"

say "Product setup"
while IFS= read -r kv; do [ -n "$kv" ] && export "${kv?}"; done < <(bash "$S/product.sh" env)
bash "$S/product.sh" setup

agent() { # agent <stage> <prompt> <tools>
  bash "$S/local-agent.sh" "$1" "$2" "$3" 2>&1 | tee -a "$RUN/agent-$1.log"
}

# --- QA ----------------------------------------------------------------------

if [[ "$STAGES" == *,qa,* ]]; then
  say "QA: write failing tests"
  BASE=$(git rev-parse HEAD)
  bash "$S/prompt.sh" qa "$ISSUE_MD" "$REF" > "$RUN/prompt-qa.md"
  agent qa "$RUN/prompt-qa.md" "Read,Write,Edit,Glob,Grep,$TEST_TOOL,Bash(git status*),Bash(git diff*),Bash(git log*)" || true
  say "QA gates"
  bash "$S/check-paths.sh" qa "$BASE" "$RUN" || die "QA failed the write-scope gate."
  STRICT=$(jq -r 'if .strictRedCheck == false then "false" else "true" end' "$ORCHESTRATOR_CONFIG")
  if [ "$STRICT" = true ]; then
    if bash "$S/product.sh" test-report > "$RUN/qa-tests.txt" 2>&1; then die "The suite is green before the coder has run -- QA's tests aren't red."; fi
    "$FACTORY_BIN" red "$FACTORY_JUNIT" "$RUN/changed-qa.txt" || die "QA's suite is red for the wrong reason (see above)."
  else
    if bash "$S/product.sh" test > "$RUN/qa-tests.txt" 2>&1; then die "The suite is green before the coder has run -- QA's tests aren't red."; fi
    echo "Suite is red."
  fi
  "${GIT[@]}" commit -q -m "test: failing tests for $REF (QA agent, local)"
  echo "Committed QA tests."
fi

# --- Coder -------------------------------------------------------------------

if [[ "$STAGES" == *,coder,* ]]; then
  say "Coder: make the tests pass"
  BASE=$(git rev-parse HEAD)
  bash "$S/prompt.sh" coder "$ISSUE_MD" "$REF" "$RUN/ambiguities-qa.md" > "$RUN/prompt-coder.base.md"
  cp "$RUN/prompt-coder.base.md" "$RUN/prompt-coder.md"
  ATTEMPTS=$(bash "$S/run-agent.sh" --get coder maxAttempts 2>/dev/null || echo 2)
  [ "$ATTEMPTS" != null ] && [ -n "$ATTEMPTS" ] || ATTEMPTS=2
  IFS=, read -r -a LADDER <<< "${FACTORY_LOCAL_CODER_MODELS:-}"
  [ "${#LADDER[@]}" -gt "$ATTEMPTS" ] && ATTEMPTS=${#LADDER[@]}
  MODEL_BEFORE="${FACTORY_LOCAL_MODEL-}"
  GREEN=false
  for i in $(seq 1 "$ATTEMPTS"); do
    if [ "${#LADDER[@]}" -gt 0 ]; then
      n=$(( i <= ${#LADDER[@]} ? i : ${#LADDER[@]} ))
      export FACTORY_LOCAL_MODEL="${LADDER[$((n - 1))]}"
    fi
    echo "-- attempt $i of $ATTEMPTS${FACTORY_LOCAL_MODEL:+ ($FACTORY_LOCAL_MODEL)}"
    echo "$i ${FACTORY_LOCAL_MODEL:-default}" >> "$RUN/coder-attempts.txt"
    agent coder "$RUN/prompt-coder.md" "Read,Write,Edit,Glob,Grep,$TEST_TOOL,Bash(git status*),Bash(git diff*),Bash(git log*)" || true
    if bash "$S/product.sh" test > "$RUN/test-output.txt" 2>&1; then
      GREEN=true; echo "Green after attempt $i."; break
    fi
    echo "Still red after attempt $i."
    [ "$i" -lt "$ATTEMPTS" ] && bash "$S/prompt.sh" coder-retry "$RUN/prompt-coder.base.md" "$RUN/test-output.txt" "$i" > "$RUN/prompt-coder.md"
  done
  [ "${#LADDER[@]}" -gt 0 ] && export FACTORY_LOCAL_MODEL="$MODEL_BEFORE"
  $GREEN || { tail -c 4000 "$RUN/test-output.txt"; die "Suite still red after $ATTEMPTS coder attempt(s)."; }
  say "Coder gates"
  bash "$S/check-paths.sh" coder "$BASE" "$RUN" || die "The coder failed the write-scope gate."
  bash "$S/product.sh" test >/dev/null 2>&1 || die "The suite isn't green."
  "${GIT[@]}" commit -q -m "feat: implement $REF (coder agent, local)"
  echo "Committed the implementation."
fi

# --- Review ------------------------------------------------------------------

PASS=""
if [[ "$STAGES" == *,review,* ]]; then
  say "Review: score against the rubric"
  bash "$S/product.sh" test >/dev/null 2>&1 || die "The suite isn't green on the branch."
  git diff --name-only "$START"...HEAD > "$RUN/changed-files.txt"
  git diff "$START"...HEAD -- . ':(exclude,glob)**/*.lock' ':(exclude,glob)**/package-lock.json' \
    ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/go.sum' > "$RUN/full-diff.txt"
  while IFS= read -r p; do
    if grep -q "^$p" "$RUN/changed-files.txt"; then die "Protected path $p was modified on this branch."; fi
  done < <(jq -r '.paths.protected // [] | .[]' "$ORCHESTRATOR_CONFIG")
  bash "$S/prompt.sh" review "$REF" "$RUN/changed-files.txt" "$RUN/full-diff.txt" "$(git rev-parse --short "$START")" > "$RUN/prompt-review.md"
  REVIEW_HEAD=$(git rev-parse HEAD)
  agent review "$RUN/prompt-review.md" "Read,Write,Glob,Grep,Bash(git diff*),Bash(git log*),$TEST_TOOL" || true
  [ -f .factory/review-result.json ] || die "The review agent didn't write .factory/review-result.json."
  mv .factory/review-result.json "$RUN/review-result.json"
  if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$REVIEW_HEAD" ]; then
    git status --porcelain
    die "The review agent modified the repo (it may only write .factory/review-result.json)."
  fi
  "$FACTORY_BIN" score .factory/rubric.json "$RUN/review-result.json" "$RUN/review-score.json" | tee "$RUN/review-report.md"
  PASS=$(jq -r '.pass' "$RUN/review-score.json")
fi

# --- summary -----------------------------------------------------------------

say "Done"
echo "Branch $BRANCH, in $WT"
[ -s "$RUN/coder-attempts.txt" ] && echo "Coder attempts: $(awk '{print $2}' "$RUN/coder-attempts.txt" | paste -sd, -)"
[ -s "$FACTORY_USAGE_LOG" ] && echo "Compute: $(jq -s '[.[].turns // 0] | add' "$FACTORY_USAGE_LOG") turns, ~\$$(jq -s '[.[].listCostUsd // 0] | add * 100 | round / 100' "$FACTORY_USAGE_LOG") at list price (not billed on a subscription)"
[ -n "$PASS" ] && echo "Rubric: $(jq -r '.overall' "$RUN/review-score.json") / 100 ($( [ "$PASS" = true ] && echo PASS || echo FAIL ))"
[ -s "$RUN/ambiguities-qa.md" ] || [ -s "$RUN/ambiguities-coder.md" ] && {
  echo; echo "Open questions the agents recorded:"; cat "$RUN"/ambiguities-*.md 2>/dev/null; }
cat <<EOF

Look at it:      git -C "$WT" log --stat $(git rev-parse --short "$START")..HEAD
Open a PR:       git -C "$WT" push -u origin $BRANCH && gh pr create --head $BRANCH
Throw it away:   git worktree remove --force "$WT" && git branch -D $BRANCH && rm -rf "$RUN"
EOF
