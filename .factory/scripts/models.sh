#!/usr/bin/env bash
#
# models.sh -- which harness and model each stage attempt uses. The one place
# that reads model settings, for CI (run-agent.sh, OpenRouter) and local
# subscription runs (local-agent.sh) alike.
#
# Usage:
#   models.sh pick  <ci|local> <stage> <attempt>   print the harness, then the model, one per line (either may be empty)
#   models.sh count <ci|local> <stage>             how many entries the stage's ladder has (0 if unset)
#   models.sh list  <ci|local> <stage>             the ladder, one entry per line
#
# A stage's model is a string or a list (a ladder). Attempt n uses entry n,
# and the last entry repeats, so ["fast", "strong"] means a fast model first
# and a strong one for every retry. Each entry is "[harness:]model"; the
# harness prefix is optional and switches harness for that attempt, so one
# ladder can mix providers. "harness:" with nothing after it means that
# harness's default model:
#
#   CI     "model" in the config, OpenRouter slugs; harness claude-code | opencode | codex
#          e.g. ["opencode:~google/gemini-flash-latest", "claude-code:~anthropic/claude-opus-latest"]
#          Override: STAGE_OVERRIDE_MODEL (one entry, from workflow_dispatch).
#   local  "localModel" in the config, the CLI's own names; harness claude | codex
#          e.g. ["claude:haiku", "codex:gpt-5.5"]
#          Override: FACTORY_LOCAL_<STAGE>_MODELS (comma list, e.g. FACTORY_LOCAL_CODER_MODELS=haiku,opus),
#          else FACTORY_LOCAL_MODEL (one entry, every stage).
#
# Lookup per stage: override > stages.<stage>.<key> > top-level <key>.

set -euo pipefail

CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"
CMD="${1:-}"; MODE="${2:-}"; STAGE="${3:-}"
case "$CMD:$MODE" in pick:ci|pick:local|count:ci|count:local|list:ci|list:local) ;;
  *) sed -n '/^# Usage:/,/^# *$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
[ -n "$STAGE" ] || { echo "models.sh: stage required" >&2; exit 2; }

ladder() { # the stage's entries, one per line
  local key=model override="${STAGE_OVERRIDE_MODEL:-}"
  if [ "$MODE" = local ]; then
    key=localModel
    local var
    var="FACTORY_LOCAL_$(echo "$STAGE" | tr '[:lower:]' '[:upper:]')_MODELS"
    override="${!var:-${FACTORY_LOCAL_MODEL:-}}"
    if [ -n "$override" ]; then tr ',' '\n' <<<"$override" | sed '/^ *$/d; s/^ *//; s/ *$//'; return; fi
  elif [ -n "$override" ]; then
    echo "$override"; return
  fi
  jq -r --arg stage "$STAGE" --arg key "$key" '
    (.stages[$stage][$key] // .[$key] // empty)
    | if type == "array" then .[] else . end | select(. != "")' "$CONFIG"
}

case "$CMD" in
  list) ladder ;;
  count) ladder | wc -l | tr -d ' ' ;;
  pick)
    N="${4:-1}"
    ENTRIES=()
    while IFS= read -r e; do ENTRIES+=("$e"); done < <(ladder)
    [ "${#ENTRIES[@]}" -gt 0 ] || { printf '\n\n'; exit 0; }
    i=$(( N < ${#ENTRIES[@]} ? N : ${#ENTRIES[@]} ))
    E="${ENTRIES[$((i - 1))]}"
    # Only a known harness name counts as a prefix: model ids can contain ':'
    # themselves (e.g. "openai/gpt-oss-20b:free").
    if [ "$MODE" = ci ]; then known='claude-code|opencode|codex'; else known='claude|claude-code|codex'; fi
    # "codex:" alone means that harness with its default model.
    if [[ "$E" =~ ^($known):(.*)$ ]]; then
      h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
      [ "$MODE" = local ] && [ "$h" = claude-code ] && h=claude
      printf '%s\n%s\n' "$h" "$m"
    else
      printf '\n%s\n' "$E"
    fi ;;
esac
