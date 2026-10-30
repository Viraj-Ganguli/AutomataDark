#!/usr/bin/env bash
#
# diff-gate.sh -- differential test: the shipped path gate (check-paths.sh's
# git plumbing + `factory paths`) vs the operations-level model
# (Factory.PathGate.accept, via `factory model-gate`).
#
# Each case builds a throwaway repo, performs 1-3 random file operations
# (edit, add, delete, rename, run-notes append), then asks both sides whether
# the change is in scope for a random stage. Any disagreement is a bug in the
# plumbing (how git reports changes) or in the model, and the case is printed.
#
# Usage: diff-gate.sh [cases]   (default 150)
#   CHECK_PATHS=<path>  check a different copy of check-paths.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../scripts/factory-bin.sh
. "$ROOT/.factory/scripts/factory-bin.sh"
export FACTORY_BIN
CHECK_PATHS="${CHECK_PATHS:-$ROOT/.factory/scripts/check-paths.sh}"
CASES="${1:-150}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT


EXISTING=(tests/golden/app.js tests/golden/db.js tests/a.test.js tests/b.test.js
          server/x.js server/y.js client/z.js README.md .github/w.yml tests-evil/e.js)
FRESH=(tests/new1.js tests/golden/new2.js server/new3.js client/new4.js docs/new5.md
       tests-evil/new6.js .factory/new7.json)
NOTES=.factory/ambiguity-checklist.md

pick_existing() { echo "${EXISTING[RANDOM % ${#EXISTING[@]}]}"; }
pick_fresh() { echo "${FRESH[RANDOM % ${#FRESH[@]}]}"; }

MISMATCH=0
for ((n = 1; n <= CASES; n++)); do
  dir="$WORK/c$n"; mkdir -p "$dir"; cd "$dir" || exit 1
  git init -q
  for f in "${EXISTING[@]}"; do
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$f" one two three four five > "$f"
  done
  mkdir -p .factory && touch "$NOTES"
  echo '{"paths":{"protected":["tests/golden/"],"qa":["tests/"],"coder":["client/","server/"]}}' \
    > .factory/orchestrator.config.json
  git add -A && git -c user.email=t@t -c user.name=t commit -qm base
  base=$(git rev-parse HEAD)

  stage=$([ $((RANDOM % 2)) = 0 ] && echo qa || echo coder)
  model_in="$WORK/model$n.txt"
  if [ "$stage" = qa ]; then printf 'allow tests/\n'; else printf 'allow client/\nallow server/\n'; fi > "$model_in"
  echo 'protect tests/golden/' >> "$model_in"

  used=" "
  for ((k = 0; k < 1 + RANDOM % 3; k++)); do
    case $((RANDOM % 5)) in
      0) f=$(pick_existing); [[ $used == *" $f "* ]] && continue
         echo edited >> "$f"; echo "edit $f" >> "$model_in" ;;
      1) f=$(pick_fresh); [[ $used == *" $f "* ]] && continue
         mkdir -p "$(dirname "$f")"; echo "new $f" > "$f"; echo "add $f" >> "$model_in" ;;
      2) f=$(pick_existing); [[ $used == *" $f "* ]] && continue
         git rm -q "$f"; echo "delete $f" >> "$model_in" ;;
      3) f=$(pick_existing); g=$(pick_fresh)
         { [[ $used == *" $f "* ]] || [[ $used == *" $g "* ]]; } && continue
         mkdir -p "$(dirname "$g")"; git mv "$f" "$g"; echo "rename $f $g" >> "$model_in"
         used="$used$g " ;;
      4) f=$NOTES; echo '- note' >> "$f"; echo "edit $f" >> "$model_in" ;;
    esac
    used="$used$f "
  done

  if bash "$CHECK_PATHS" "$stage" "$base" "$WORK/run$n" > "$WORK/out$n.txt" 2>&1; then
    script=accept
  else
    script=reject
  fi
  model=$("$FACTORY_BIN" model-gate < "$model_in")

  if [ "$script" != "$model" ]; then
    MISMATCH=$((MISMATCH + 1))
    echo "MISMATCH case $n ($stage): check-paths.sh=$script model=$model"
    grep -vE '^(allow|protect) ' "$model_in" | sed 's/^/    /'
  fi
done
cd "$ROOT" || exit 1

echo "diff-gate: $CASES cases, $MISMATCH mismatch(es)"
[ "$MISMATCH" -eq 0 ]
