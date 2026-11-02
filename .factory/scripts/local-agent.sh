#!/usr/bin/env bash
#
# local-agent.sh -- run one stage's prompt through the Claude Code or Codex
# CLI you are logged into, on your subscription. The local counterpart of
# run-agent.sh (which points harnesses at OpenRouter in CI). No API keys, no
# OpenRouter, no extra spend.
#
# Usage:
#   local-agent.sh <stage> <prompt-file> <tool-profile>
#   local-agent.sh --check            verify the CLI is logged in with a subscription
#
# Env:
#   FACTORY_LOCAL_HARNESS  claude | codex (default: the config's harness if it
#                          is one of these, else whichever CLI is installed)
#   FACTORY_LOCAL_MODEL    optional model, e.g. "opus" / "sonnet" for Claude
#                          Code or a Codex model name (default: the CLI's own)
#   FACTORY_AGENT_CMD      testing only: run this command instead of a CLI,
#                          as `$FACTORY_AGENT_CMD <stage> <prompt-file>`
#   FACTORY_USAGE_LOG      optional file; Claude Code runs append one JSON line
#                          per session (stage, model, turns, seconds, and the
#                          list-price cost the CLI reports -- not billed on a
#                          subscription, but a fair measure of compute used)
#
# Billing guard: API-key variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, ...) are
# removed from the agent's environment, and the run refuses to start unless
# the CLI reports a subscription login (Claude Code: claude.ai; Codex:
# ChatGPT). Set FACTORY_ALLOW_API_BILLING=1 to run on an API login anyway.

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

harness() {
  if [ -n "${FACTORY_LOCAL_HARNESS:-}" ]; then echo "$FACTORY_LOCAL_HARNESS"; return; fi
  case "$(jq -r '.harness // ""' "$CONFIG" 2>/dev/null)" in
    claude-code) command -v claude >/dev/null && { echo claude; return; } ;;
    codex) command -v codex >/dev/null && { echo codex; return; } ;;
  esac
  if command -v claude >/dev/null; then echo claude
  elif command -v codex >/dev/null; then echo codex
  else echo none; fi
}

HARNESS=$(harness)

check_login() {
  [ -n "${FACTORY_AGENT_CMD:-}" ] && { echo "local-agent: using test agent ($FACTORY_AGENT_CMD)"; return 0; }
  case "$HARNESS" in
    claude)
      local method
      method=$(scrubbed claude auth status 2>/dev/null | jq -r '.authMethod // "none"' 2>/dev/null || echo none)
      if [ "$method" = "claude.ai" ]; then echo "local-agent: Claude Code, subscription login (claude.ai)"; return 0; fi
      echo "local-agent: Claude Code isn't logged in with a Claude subscription (auth method: $method). Run: claude auth login" >&2 ;;
    codex)
      if scrubbed codex login status 2>&1 | grep -q ChatGPT; then echo "local-agent: Codex, subscription login (ChatGPT)"; return 0; fi
      echo "local-agent: Codex isn't logged in with ChatGPT. Run: codex login" >&2 ;;
    *) echo "local-agent: neither the claude nor the codex CLI is installed" >&2; return 1 ;;
  esac
  if [ "${FACTORY_ALLOW_API_BILLING:-}" = 1 ]; then
    echo "local-agent: FACTORY_ALLOW_API_BILLING=1 -- continuing on an API login (this costs money)" >&2
    return 0
  fi
  return 1
}

if [ "${1:-}" = "--check" ]; then check_login; exit $?; fi

STAGE="${1:?usage: local-agent.sh <stage> <prompt-file> <tool-profile>}"
PROMPT="${2:?prompt file}"
TOOLS="${3:?tool profile}"
MAX_TURNS=$(bash "$HERE/run-agent.sh" --get "$STAGE" maxTurns 2>/dev/null || true)
[ -n "$MAX_TURNS" ] && [ "$MAX_TURNS" != null ] || MAX_TURNS=30
# Subscription runs have no per-token cost, so give the agent room; the
# config's maxTurns is tuned for paid CI runs. FACTORY_LOCAL_MAX_TURNS overrides.
MAX_TURNS="${FACTORY_LOCAL_MAX_TURNS:-$(( MAX_TURNS < 30 ? 30 : MAX_TURNS ))}"

if [ -n "${FACTORY_AGENT_CMD:-}" ]; then
  scrubbed $FACTORY_AGENT_CMD "$STAGE" "$PROMPT"
  exit $?
fi

case "$HARNESS" in
  claude)
    MODEL_ARGS=(); [ -n "${FACTORY_LOCAL_MODEL:-}" ] && MODEL_ARGS=(--model "$FACTORY_LOCAL_MODEL")
    OUT=$(mktemp)
    STATUS=0
    scrubbed claude -p "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "$TOOLS" \
      --permission-mode acceptEdits \
      --output-format json \
      < "$PROMPT" > "$OUT" || STATUS=$?
    jq -r '.result // empty' "$OUT" 2>/dev/null || cat "$OUT"
    if [ -n "${FACTORY_USAGE_LOG:-}" ]; then
      jq -c --arg stage "$STAGE" '{stage: $stage, models: (.modelUsage // {} | map_values(.costUSD)),
          turns: .num_turns, seconds: ((.duration_ms // 0) / 1000 | round),
          listCostUsd: .total_cost_usd, error: (if .is_error then .subtype else null end)}' \
        "$OUT" >> "$FACTORY_USAGE_LOG" 2>/dev/null || true
    fi
    rm -f "$OUT"
    exit "$STATUS" ;;
  codex)
    # Codex has no per-tool allowlist; its workspace-write sandbox plus the
    # factory's path gate contain it, as in CI.
    MODEL_ARGS=(); [ -n "${FACTORY_LOCAL_MODEL:-}" ] && MODEL_ARGS=(-m "$FACTORY_LOCAL_MODEL")
    scrubbed codex exec --skip-git-repo-check "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" \
      --sandbox workspace-write \
      -c 'approval_policy="never"' \
      -c 'sandbox_workspace_write.network_access=true' \
      - < "$PROMPT" ;;
  *) echo "local-agent: no supported CLI (claude or codex) found" >&2; exit 1 ;;
esac
