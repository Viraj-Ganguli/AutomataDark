#!/usr/bin/env bash
#
# prompt.sh -- assemble each stage's agent prompt. The one source of prompt
# text for both the orchestrator (CI) and local runs (local-run.sh).
#
# Usage:
#   prompt.sh qa <issue.md> <ref>
#   prompt.sh coder <issue.md> <ref> [qa-ambiguities.md]
#   prompt.sh coder-retry <coder-prompt.md> <test-output> <attempt>
#   prompt.sh review <ref> <changed-files.txt> <full-diff.txt> <base-name>
#
#   issue.md   the NLSpec: "# Title" then the body
#   ref        how to name the issue in prompts, e.g. "#12" or "local: add-likes"
#
# Env: ORCHESTRATOR_CONFIG (default .factory/orchestrator.config.json), and
# TEST_CMD (default: product.test from the config). Prints to stdout.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"
TEST_CMD="${TEST_CMD:-$(bash "$HERE/product.sh" show test)}"

sep() { echo; echo "---"; echo; }

case "${1:-}" in
  qa)
    ISSUE="${2:?issue.md}"; REF="${3:?ref}"
    cat .factory/qa.nlspec.md
    sep
    echo "## Issue $REF"
    echo
    cat "$ISSUE"
    sep
    echo "The shared, read-only test harness lives under: $(jq -r '.paths.protected | map("`" + . + "`") | join(", ")' "$CONFIG"). Read its README, if it has one, for the interface."
    sep
    bash "$HERE/check-paths.sh" --describe qa
    sep
    echo "## Action required"
    echo
    echo "Write the failing tests for issue $REF right now."
    echo "Use your Write or Edit tools to create test file(s) inside your write scope."
    echo "Do NOT describe what you will do — call the tools and write the files."
    echo "When done, run \`$TEST_CMD\` to confirm the new tests fail for the right reason."
    ;;

  coder)
    ISSUE="${2:?issue.md}"; REF="${3:?ref}"; AMBIG="${4:-}"
    cat .factory/coder.nlspec.md
    sep
    bash "$HERE/check-paths.sh" --describe coder
    echo
    echo "---"
    if [ -n "$AMBIG" ] && [ -s "$AMBIG" ]; then
      echo
      echo "## Open questions the QA agent recorded"
      echo
      echo "These are unresolved. Don't guess past them silently; if one blocks you, append to the checklist too."
      echo
      cat "$AMBIG"
      echo
      echo "---"
    fi
    echo
    echo "## Issue $REF"
    echo
    cat "$ISSUE"
    sep
    echo "## Failing tests"
    echo
    echo "The QA agent already committed failing tests. Run \`$TEST_CMD\` to see the current failures, then iterate (read -> edit -> re-run) until it exits 0. Do not edit the tests or anything else outside your write scope."
    sep
    echo "## Action required"
    echo
    echo "Start now: run \`$TEST_CMD\`, read the failures, edit the application source, and repeat until green."
    echo "Do NOT describe what you will do — call the tools and fix the code."
    ;;

  coder-retry)
    BASE="${2:?coder-prompt.md}"; OUT="${3:?test-output}"; N="${4:?attempt}"
    cat "$BASE"
    sep
    echo "## Previous attempt $N left the suite red"
    echo
    echo "Your earlier edits are still in the working tree. This is the tail of \`$TEST_CMD\`:"
    echo
    echo '```'
    tail -c 8000 "$OUT"
    echo '```'
    echo
    echo "Fix the remaining failures in application code. Do not edit the tests; if a test is unsatisfiable, record it in .factory/ambiguity-checklist.md."
    ;;

  review)
    REF="${2:?ref}"; CHANGED="${3:?changed-files}"; DIFF="${4:?full-diff}"; BASENAME="${5:?base-name}"
    DIFF_LIMIT=80000
    echo "# Review agent"
    echo
    echo "Score the cumulative diff for issue $REF (changes since"
    echo "$BASENAME, listed and shown below) against every criterion in the rubric"
    echo "below. For each criterion, give an integer score from 0 to 100 and a one-sentence"
    echo "comment justifying it."
    echo
    echo "When done, write your results to \`.factory/review-result.json\`"
    echo "(create it -- it does not exist yet) with exactly this shape:"
    echo
    echo '```json'
    echo '{'
    echo '  "criteria": {'
    echo '    "<criterion-id>": { "score": 0-100, "comment": "..." },'
    echo '    "...": { "score": 0-100, "comment": "..." }'
    echo '  }'
    echo '}'
    echo '```'
    echo
    echo "Include every criterion id from the rubric's dimensions[].criteria[].id."
    echo "Do not create, edit, or delete any other file -- in particular, never"
    echo "modify any test or anything under the protected paths."
    sep
    echo "## Rubric (.factory/rubric.json)"
    echo
    echo '```json'
    cat .factory/rubric.json
    echo '```'
    sep
    echo "## Changed files (vs $BASENAME)"
    echo
    echo '```'
    cat "$CHANGED"
    echo '```'
    sep
    echo "## Full diff (vs $BASENAME, lockfiles excluded)"
    echo
    echo '```diff'
    head -c "$DIFF_LIMIT" "$DIFF"
    echo '```'
    if [ "$(wc -c < "$DIFF")" -gt "$DIFF_LIMIT" ]; then
      echo
      echo "The diff above is truncated at $DIFF_LIMIT bytes. Run \`git diff $BASENAME...HEAD -- <file>\` for the files it doesn't cover before scoring."
    fi
    ;;

  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
