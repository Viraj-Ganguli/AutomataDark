#!/usr/bin/env bash
#
# check-paths.sh -- enforce the factory/product boundary after an agent stage.
#
# The boundary is declared once, in .factory/orchestrator.config.json:
#
#   "paths": {
#     "protected": ["tests/golden/"],          never writable by any agent
#     "qa":        ["tests/"],                 what the QA agent may change
#     "coder":     ["src/"]                    what the coder agent may change
#   }
#
# Usage:
#   check-paths.sh <stage> <base-sha> <run-dir>   harvest run notes, then enforce
#   check-paths.sh --describe <stage>             print the write scope as markdown
#                                                 (injected into the agent's prompt)
#
# This script does the git plumbing; the decision is `factory paths`, the Lean
# function PathGate.acceptPaths, which is proved never to accept a protected
# or out-of-scope path (.factory/lean/Factory/PathGate.lean).
#
# Enforce mode:
#   1. Stages everything and diffs against <base-sha> (the commit before the
#      agent ran), so changes are caught even if the agent committed itself.
#   2. Harvests the agent's run notes -- lines it appended to
#      .factory/ambiguity-checklist.md -- into <run-dir>/ambiguities-<stage>.md,
#      then restores that file. Run notes travel in the run record (artifact +
#      PR body), never in the product branch.
#   3. Lists every changed path (a rename counts as both of its paths) and
#      fails unless `factory paths` accepts the list -- including when nothing
#      changed at all.
#   4. Fails if a change adds anything shaped like an OpenRouter key.

set -euo pipefail

NOTES=".factory/ambiguity-checklist.md"
# shellcheck source=factory-bin.sh
. "$(dirname "$0")/factory-bin.sh"

if [ "${1:-}" = "--describe" ]; then
  exec "$FACTORY_BIN" describe "${2:?usage: check-paths.sh --describe <stage>}"
fi

STAGE="${1:?usage: check-paths.sh <stage> <base-sha> <run-dir>}"
BASE_SHA="${2:?usage: check-paths.sh <stage> <base-sha> <run-dir>}"
RUN_DIR="${3:?usage: check-paths.sh <stage> <base-sha> <run-dir>}"
mkdir -p "$RUN_DIR"

git add -A

# 2. Harvest run notes, then take them back out of the product change.
if ! git diff --cached --quiet "$BASE_SHA" -- "$NOTES"; then
  git diff --cached "$BASE_SHA" -- "$NOTES" | grep -E '^\+[^+]' | sed -E 's/^\+//' \
    > "$RUN_DIR/ambiguities-$STAGE.md" || true
  echo "Harvested $(wc -l < "$RUN_DIR/ambiguities-$STAGE.md" | tr -d ' ') line(s) of run notes from $NOTES."
  git reset -q "$BASE_SHA" -- "$NOTES"
  git checkout -q "$BASE_SHA" -- "$NOTES"
fi

# 3. Enforce. --no-renames lists a move as delete + add, so both sides are
# checked -- otherwise moving a file out of a protected prefix shows only the
# (allowed) destination and passes.
CHANGED=$(git diff --name-only --no-renames --cached "$BASE_SHA")
if [ -n "$CHANGED" ]; then
  echo "Changed files:"
  echo "$CHANGED" | sed 's/^/  /'
  echo "$CHANGED" > "$RUN_DIR/changed-$STAGE.txt"
fi

# 4. A key in product files would be pushed to a (possibly public) branch.
# Report file names only -- never echo the matching line.
LEAKS=$(git diff --cached --name-only --no-renames -G 'sk-or-[A-Za-z0-9]+-[A-Za-z0-9_-]{16,}' "$BASE_SHA" || true)
if [ -n "$LEAKS" ]; then
  echo "The $STAGE agent added something shaped like an OpenRouter key to:"
  echo "$LEAKS" | sed 's/^/  /'
  echo "Refusing to commit. Nothing was pushed."
  exit 1
fi

printf '%s\n' "$CHANGED" | "$FACTORY_BIN" paths "$STAGE"
