#!/usr/bin/env bash
#
# run-agent.sh -- harness-agnostic entry point for one orchestrator stage.
#
# Reads harness/model/maxTurns for the given stage from
# .factory/orchestrator.config.json (with workflow_dispatch overrides via
# env), installs that harness's CLI if it isn't already on PATH, points it at
# OpenRouter, and runs the assembled prompt through it.
#
# Usage:
#   run-agent.sh <stage> <prompt-file> <tool-profile>
#
#   stage         qa | coder | review -- selects .stages.<stage> in the config
#   prompt-file   path to the fully assembled prompt (already includes the
#                 NLSpec + issue body + action-required instructions)
#   tool-profile  the Claude Code --allowedTools string for this stage, e.g.
#                 "Read,Write,Edit,Glob,Grep,Bash(npm test*)". Honored by the
#                 claude-code harness only; opencode/codex rely on the
#                 post-agent path allowlist enforced by the calling job.
#
# Required env:
#   OPENROUTER_API_KEY   the repo secret, all three harnesses read it
#
# Optional env (set by the workflow from workflow_dispatch inputs):
#   STAGE_OVERRIDE_HARNESS   overrides .stages.<stage>.harness / .harness
#   STAGE_OVERRIDE_MODEL     overrides .stages.<stage>.model / .model
#
# Config resolution per key: dispatch override > stages.<stage>.<key> >
# top-level <key>. Model/harness values are opaque OpenRouter slugs (or
# harness names) -- never validated against a list, so any OpenRouter model
# works with no edits to this script.

set -euo pipefail

STAGE="${1:?usage: run-agent.sh <stage> <prompt-file> <tool-profile>}"
PROMPT_FILE="${2:?usage: run-agent.sh <stage> <prompt-file> <tool-profile>}"
TOOL_PROFILE="${3:?usage: run-agent.sh <stage> <prompt-file> <tool-profile>}"

CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "run-agent.sh: OPENROUTER_API_KEY is not set" >&2
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "run-agent.sh: prompt file '$PROMPT_FILE' does not exist" >&2
  exit 1
fi

resolve() {
  # resolve <key> <override> -- dispatch override, else stages.<stage>.<key>,
  # else top-level <key>.
  local key="$1" override="$2"
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi
  jq -r --arg stage "$STAGE" --arg key "$key" \
    '.stages[$stage][$key] // .[$key]' "$CONFIG"
}

HARNESS="$(resolve harness "${STAGE_OVERRIDE_HARNESS:-}")"
MODEL="$(resolve model "${STAGE_OVERRIDE_MODEL:-}")"
MAX_TURNS="$(resolve maxTurns "")"

if [ -z "$HARNESS" ] || [ "$HARNESS" = "null" ]; then
  echo "run-agent.sh: no harness resolved for stage '$STAGE' (checked stages.$STAGE.harness and .harness in $CONFIG)" >&2
  exit 1
fi
if [ -z "$MODEL" ] || [ "$MODEL" = "null" ]; then
  echo "run-agent.sh: no model resolved for stage '$STAGE' (checked stages.$STAGE.model and .model in $CONFIG)" >&2
  exit 1
fi

echo "run-agent.sh: stage=$STAGE harness=$HARNESS model=$MODEL max_turns=$MAX_TURNS"

run_claude_code() {
  if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
  fi

  export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
  export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
  # Must be an explicitly empty string, not unset -- otherwise Claude Code
  # may fall back to authenticating against Anthropic directly.
  export ANTHROPIC_API_KEY=""
  # The CLI's own internal tooling calls (fast, cheap "haiku-class" calls it
  # makes to drive itself) also route through ANTHROPIC_BASE_URL. Point them
  # at this stage's model too so they don't request a bare Anthropic model id
  # that OpenRouter's skin has to guess at.
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"

  if [ "$MAX_TURNS" = "null" ] || [ -z "$MAX_TURNS" ]; then
    echo "run-agent.sh: no maxTurns resolved for stage '$STAGE' (claude-code requires one)" >&2
    exit 1
  fi

  claude -p \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$TOOL_PROFILE" \
    --permission-mode acceptEdits \
    --output-format stream-json \
    --verbose \
    < "$PROMPT_FILE"
}

run_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    npm install -g opencode-ai
  fi

  mkdir -p "$HOME/.local/share/opencode"
  # Written fresh each run so the key always matches the current secret.
  cat > "$HOME/.local/share/opencode/auth.json" <<EOF
{
  "openrouter": {
    "type": "api",
    "key": "$OPENROUTER_API_KEY"
  }
}
EOF

  opencode run \
    --model "openrouter/$MODEL" \
    --auto \
    --format json \
    "$(cat "$PROMPT_FILE")"
}

run_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    npm install -g @openai/codex
  fi

  mkdir -p "$HOME/.codex"
  # wire_api = "responses" is mandatory: OpenAI removed the chat/completions
  # path, and a custom provider with wire_api = "chat" (or omitted) fails at
  # startup rather than falling back.
  cat > "$HOME/.codex/config.toml" <<EOF
model_provider = "openrouter"
model = "$MODEL"

[model_providers.openrouter]
name = "openrouter"
base_url = "https://openrouter.ai/api/v1"
wire_api = "responses"

[model_providers.openrouter.auth]
command = "sh"
args = ["-c", "echo \$OPENROUTER_API_KEY"]
EOF

  codex exec \
    --sandbox workspace-write \
    --skip-git-repo-check \
    -m "$MODEL" \
    "$(cat "$PROMPT_FILE")"
}

case "$HARNESS" in
  claude-code) run_claude_code ;;
  opencode) run_opencode ;;
  codex) run_codex ;;
  *)
    echo "run-agent.sh: unknown harness '$HARNESS' for stage '$STAGE' -- valid values: claude-code, opencode, codex" >&2
    exit 1
    ;;
esac
