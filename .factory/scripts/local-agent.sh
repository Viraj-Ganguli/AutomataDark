#!/usr/bin/env bash
#
# local-agent.sh -- run one stage's prompt through the Claude Code or Codex
# CLI you are logged into, on your subscription. The local counterpart of
# run-agent.sh (which points harnesses at OpenRouter in CI). No API keys, no
# OpenRouter, no extra spend.
#
# Usage:
#   local-agent.sh <stage> <prompt-file> <tool-profile>
#   local-agent.sh --pick <stage> [attempt]   print the harness, then the model, for that attempt
#   local-agent.sh --attempts <stage>         how many attempts the stage gets
#   local-agent.sh --check                    verify every CLI the stages use is logged in with a subscription
#
# Which harness and model: see models.sh. In short, per stage and attempt,
# FACTORY_LOCAL_<STAGE>_MODELS (comma list) > FACTORY_LOCAL_MODEL >
# localModel in the config; each entry is "[claude:|codex:]model", and a
# list is a ladder (attempt n uses entry n, the last repeats). With no
# harness prefix: FACTORY_LOCAL_HARNESS, else the config's harness if it is
# claude-code or codex, else whichever CLI is installed. With no model: the
# CLI's own default.
#
# Env:
#   FACTORY_ATTEMPT        which attempt this is (default 1)
#   FACTORY_AGENT_CMD      testing only: run this command instead of a CLI,
#                          as `$FACTORY_AGENT_CMD <stage> <prompt-file>`, with
#                          FACTORY_LOCAL_HARNESS/FACTORY_LOCAL_MODEL set to the pick
#   FACTORY_USAGE_LOG      optional file; one JSON line per session is
#                          appended (usage.sh: turns, tokens, cost where the
#                          harness reports it)
#
# Billing guard: API-key variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, ...) are
# removed from the agent's environment, and the run refuses to start unless
# each CLI it uses reports a subscription login (Claude Code: claude.ai;
# Codex: ChatGPT). Set FACTORY_ALLOW_API_BILLING=1 to run on an API login anyway.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"

# Never let a stray key in the shell turn a subscription run into a billed one.
scrubbed() {
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL \
      -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL \
      -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u ANTHROPIC_DEFAULT_FABLE_MODEL \
      -u CLAUDE_CODE_SUBAGENT_MODEL -u OPENAI_API_KEY -u OPENAI_BASE_URL \
      -u CODEX_HOME -u OPENROUTER_API_KEY -u FACTORY_KEY_PASSPHRASE -u OPENROUTER_KEY_CIPHER \
      "$@"
}

default_harness() {
  if [ -n "${FACTORY_LOCAL_HARNESS:-}" ]; then echo "$FACTORY_LOCAL_HARNESS"; return; fi
  case "$(jq -r '.harness // ""' "$CONFIG" 2>/dev/null)" in
    claude-code) command -v claude >/dev/null && { echo claude; return; } ;;
    codex) command -v codex >/dev/null && { echo codex; return; } ;;
  esac
  if command -v claude >/dev/null; then echo claude
  elif command -v codex >/dev/null; then echo codex
  else echo none; fi
}

pick() { # pick <stage> <attempt> -- prints the harness (filled in), then the model
  local h m
  { IFS= read -r h; IFS= read -r m; } < <(bash "$HERE/models.sh" pick local "$1" "$2")
  printf '%s\n%s\n' "${h:-$(default_harness)}" "$m"
}

attempts() {
  local n ladder
  n=$(bash "$HERE/run-agent.sh" --get "$1" maxAttempts 2>/dev/null || echo 1)
  [ -n "$n" ] && [ "$n" != null ] || n=1
  ladder=$(bash "$HERE/models.sh" count local "$1")
  echo $(( ladder > n ? ladder : n ))
}

check_one() { # check_one <harness>
  case "$1" in
    claude)
      local method
      method=$(scrubbed claude auth status 2>/dev/null | jq -r '.authMethod // "none"' 2>/dev/null || echo none)
      if [ "$method" = "claude.ai" ]; then echo "local-agent: Claude Code, subscription login (claude.ai)"; return 0; fi
      echo "local-agent: Claude Code isn't logged in with a Claude subscription (auth method: $method). Run: claude auth login" >&2 ;;
    codex)
      if scrubbed codex login status 2>&1 | grep -q ChatGPT; then echo "local-agent: Codex, subscription login (ChatGPT)"; return 0; fi
      echo "local-agent: Codex isn't logged in with ChatGPT. Run: codex login" >&2 ;;
    *) echo "local-agent: no supported CLI for harness '$1' (claude or codex)" >&2; return 1 ;;
  esac
  if [ "${FACTORY_ALLOW_API_BILLING:-}" = 1 ]; then
    echo "local-agent: FACTORY_ALLOW_API_BILLING=1 -- continuing on an API login (this costs money)" >&2
    return 0
  fi
  return 1
}

check_login() { # every harness any stage attempt will use
  [ -n "${FACTORY_AGENT_CMD:-}" ] && { echo "local-agent: using test agent ($FACTORY_AGENT_CMD)"; return 0; }
  local s i h m seen=" "
  for s in qa coder review; do
    for i in $(seq 1 "$(attempts "$s")"); do
      { IFS= read -r h; IFS= read -r m; } < <(pick "$s" "$i")
      case "$seen" in *" $h "*) continue ;; esac
      seen="$seen$h "
      command -v "$h" >/dev/null || { echo "local-agent: stage $s uses '$h', which isn't installed" >&2; return 1; }
      check_one "$h" || return 1
    done
  done
}

case "${1:-}" in
  --check) check_login; exit $? ;;
  --pick) pick "${2:?stage}" "${3:-1}"; exit 0 ;;
  --attempts) attempts "${2:?stage}"; exit 0 ;;
esac

STAGE="${1:?usage: local-agent.sh <stage> <prompt-file> <tool-profile>}"
PROMPT="${2:?prompt file}"
TOOLS="${3:?tool profile}"
ATTEMPT="${FACTORY_ATTEMPT:-1}"
{ IFS= read -r HARNESS; IFS= read -r MODEL; } < <(pick "$STAGE" "$ATTEMPT")
MAX_TURNS=$(bash "$HERE/run-agent.sh" --get "$STAGE" maxTurns 2>/dev/null || true)
[ -n "$MAX_TURNS" ] && [ "$MAX_TURNS" != null ] || MAX_TURNS=30
# Subscription runs have no per-token cost, so give the agent room; the
# config's maxTurns is tuned for paid CI runs. FACTORY_LOCAL_MAX_TURNS overrides.
MAX_TURNS="${FACTORY_LOCAL_MAX_TURNS:-$(( MAX_TURNS < 30 ? 30 : MAX_TURNS ))}"

OUT=$(mktemp)
START=$(date +%s)
STATUS=0
if [ -n "${FACTORY_AGENT_CMD:-}" ]; then
  FACTORY_LOCAL_HARNESS="$HARNESS" FACTORY_LOCAL_MODEL="$MODEL" \
    scrubbed $FACTORY_AGENT_CMD "$STAGE" "$PROMPT" > "$OUT" || STATUS=$?
  cat "$OUT"
else
  case "$HARNESS" in
    claude)
      MODEL_ARGS=(); [ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")
      scrubbed claude -p "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" \
        --max-turns "$MAX_TURNS" \
        --allowedTools "$TOOLS" \
        --permission-mode acceptEdits \
        --output-format json \
        < "$PROMPT" > "$OUT" || STATUS=$?
      jq -r '.result // empty' "$OUT" 2>/dev/null || cat "$OUT" ;;
    codex)
      # Codex has no per-tool allowlist; its workspace-write sandbox plus the
      # factory's path gate contain it, as in CI.
      MODEL_ARGS=(); [ -n "$MODEL" ] && MODEL_ARGS=(-m "$MODEL")
      scrubbed codex exec --skip-git-repo-check "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" \
        --json \
        --sandbox workspace-write \
        -c 'approval_policy="never"' \
        -c 'sandbox_workspace_write.network_access=true' \
        - < "$PROMPT" > "$OUT" || STATUS=$?
      jq -r -R 'fromjson? | select(.type == "item.completed" and .item.type == "agent_message") | .item.text' "$OUT" ;;
    *) echo "local-agent: no supported CLI (claude or codex) found" >&2; STATUS=1 ;;
  esac
fi
if [ -n "${FACTORY_USAGE_LOG:-}" ]; then
  bash "$HERE/usage.sh" "$HARNESS" "$STAGE" "$ATTEMPT" "$MODEL" "$(( $(date +%s) - START ))" "$OUT" \
    >> "$FACTORY_USAGE_LOG" 2>/dev/null || true
fi
rm -f "$OUT"
exit "$STATUS"
