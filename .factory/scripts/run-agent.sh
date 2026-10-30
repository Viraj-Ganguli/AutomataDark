#!/usr/bin/env bash
#
# run-agent.sh -- harness-agnostic entry point for one orchestrator stage.
#
# Reads harness/model/maxTurns for the given stage from
# .factory/orchestrator.config.json (with workflow_dispatch overrides via
# env), checks the model slug against OpenRouter's catalog, installs that
# harness's CLI if it isn't already on PATH, points it at OpenRouter, and runs
# the assembled prompt through it.
#
# Usage:
#   run-agent.sh <stage> <prompt-file> <tool-profile>   run a stage
#   run-agent.sh --resolve <stage>                      print resolved settings
#   run-agent.sh --get <stage> <key>                    print one resolved key
#   run-agent.sh --check <stage>                        validate the model slug
#
#   stage         qa | coder | review | spine -- selects .stages.<stage>
#   prompt-file   path to the fully assembled prompt (already includes the
#                 NLSpec + issue body + action-required instructions)
#   tool-profile  Claude Code --allowedTools syntax, e.g.
#                 "Read,Write,Edit,Glob,Grep,Bash(make test*)". claude-code
#                 uses it as-is; opencode gets an equivalent permission block
#                 (edit allowed only if Write/Edit are listed, bash limited to
#                 the Bash(...) patterns); codex has no per-tool control and
#                 relies on its sandbox plus the calling job's path allowlist.
#
# Key (run mode only) -- one of:
#   OPENROUTER_KEY_CIPHER + FACTORY_KEY_PASSPHRASE
#                        CI: this build's throwaway key, encrypted by the
#                        workflow's mint-key job. Decrypted here, masked in
#                        the job log, and the passphrase/ciphertext are
#                        dropped from the env before the harness starts.
#   OPENROUTER_API_KEY   local runs: a plain key from openrouter.ai/keys
#
# Optional env:
#   STAGE_OVERRIDE_HARNESS   overrides .stages.<stage>.harness / .harness
#                            ("" or "config" means no override)
#   STAGE_OVERRIDE_MODEL     overrides .stages.<stage>.model / .model
#   ORCHESTRATOR_CONFIG      config path (default .factory/orchestrator.config.json)
#   SKIP_MODEL_CHECK=1       skip the OpenRouter catalog lookup
#   FACTORY_RUN_DIR          if set, the prompt and the agent's raw output are
#                            appended to <dir>/prompts-<stage>.md and
#                            <dir>/agent-<stage>.log (the run record that CI
#                            uploads as an artifact)
#
# Config resolution per key: dispatch override > stages.<stage>.<key> >
# top-level <key>. Model slugs are opaque -- any id from
# https://openrouter.ai/models works with no edits to this script.

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# *$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

MODE=run
case "${1:-}" in
  --resolve) MODE=resolve; shift ;;
  --get) MODE="get"; shift ;;
  --check) MODE=check; shift ;;
  -h|--help|"") usage ;;
esac

STAGE="${1:-}"
[ -n "$STAGE" ] || usage

CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"
if [ ! -f "$CONFIG" ]; then
  echo "run-agent.sh: config '$CONFIG' not found (run from the repo root, or set ORCHESTRATOR_CONFIG)" >&2
  exit 1
fi

# "config" is the workflow_dispatch dropdown's "use the config file" choice.
[ "${STAGE_OVERRIDE_HARNESS:-}" = "config" ] && STAGE_OVERRIDE_HARNESS=""

resolve() {
  # resolve <key> [override] -- override, else stages.<stage>.<key>, else
  # top-level <key>. Prints "" when unset.
  local key="$1" override="${2:-}"
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi
  jq -r --arg stage "$STAGE" --arg key "$key" \
    '.stages[$stage][$key] // .[$key] // empty' "$CONFIG"
}

HARNESS="$(resolve harness "${STAGE_OVERRIDE_HARNESS:-}")"
MODEL="$(resolve model "${STAGE_OVERRIDE_MODEL:-}")"
MAX_TURNS="$(resolve maxTurns)"
MAX_ATTEMPTS="$(resolve maxAttempts)"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-1}"
# Optional npm version pin per harness, e.g. "harnessVersions": {"codex": "0.50.0"}.
HARNESS_VERSION="$(jq -r --arg h "$HARNESS" '.harnessVersions[$h] // "latest"' "$CONFIG")"

case "$MODE" in
  resolve)
    printf 'stage=%s harness=%s model=%s maxTurns=%s maxAttempts=%s harnessVersion=%s\n' \
      "$STAGE" "$HARNESS" "$MODEL" "${MAX_TURNS:-none}" "$MAX_ATTEMPTS" "$HARNESS_VERSION"
    exit 0
    ;;
  get)
    KEY="${2:?usage: run-agent.sh --get <stage> <key>}"
    case "$KEY" in
      harness) echo "$HARNESS" ;;
      model) echo "$MODEL" ;;
      maxTurns) echo "$MAX_TURNS" ;;
      maxAttempts) echo "$MAX_ATTEMPTS" ;;
      *) resolve "$KEY" ;;
    esac
    exit 0
    ;;
esac

if [ -z "$HARNESS" ]; then
  echo "run-agent.sh: no harness resolved for stage '$STAGE' (checked stages.$STAGE.harness and .harness in $CONFIG)" >&2
  exit 1
fi
if [ -z "$MODEL" ]; then
  echo "run-agent.sh: no model resolved for stage '$STAGE' (checked stages.$STAGE.model and .model in $CONFIG)" >&2
  exit 1
fi
case "$HARNESS" in
  claude-code|opencode|codex) ;;
  *)
    echo "run-agent.sh: unknown harness '$HARNESS' for stage '$STAGE' -- valid values: claude-code, opencode, codex" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Preflight: is the slug a real OpenRouter model that supports tool calling?
# Catches typos and retired ids in seconds instead of after a 5-minute
# install/migrate. Network failures only warn -- OpenRouter is the judge.
# ---------------------------------------------------------------------------
check_model() {
  # Claude Code's "[1m]" context-window suffix isn't part of the slug.
  local slug="${MODEL%\[1m\]}"

  case "$HARNESS:$slug" in
    claude-code:anthropic/*|claude-code:~anthropic/*) ;;
    claude-code:*)
      echo "run-agent.sh: WARNING: '$slug' on claude-code -- Claude Code is tuned for Anthropic models; opencode is the safer harness for other providers." >&2 ;;
    codex:openai/*|codex:~openai/*) ;;
    codex:*)
      echo "run-agent.sh: WARNING: '$slug' on codex -- Codex speaks the Responses API and is tuned for OpenAI models; opencode is the safer harness for other providers." >&2 ;;
  esac

  [ "${SKIP_MODEL_CHECK:-}" = "1" ] && return 0

  local catalog
  if ! catalog="$(curl -fsS --max-time 20 https://openrouter.ai/api/v1/models 2>/dev/null)"; then
    echo "run-agent.sh: WARNING: couldn't fetch the OpenRouter model catalog; skipping slug check." >&2
    return 0
  fi

  local found
  found="$(jq -r --arg s "$slug" \
    '[.data[] | select(.id == $s or .canonical_slug == $s)][0]
     | if . == null then "missing"
       elif ((.supported_parameters // []) | index("tools")) then "ok"
       else "no-tools" end' <<<"$catalog")"

  case "$found" in
    ok)
      echo "run-agent.sh: model '$slug' found on OpenRouter (tool calling supported)." ;;
    no-tools)
      echo "run-agent.sh: model '$slug' exists on OpenRouter but does not support tool calling, which every agent harness needs. Pick another model." >&2
      return 1 ;;
    *)
      echo "run-agent.sh: model '$slug' is not in OpenRouter's catalog." >&2
      local hint="${slug#\~}"; hint="${hint%%/*}"
      echo "  Closest ids from provider '$hint' (full list: https://openrouter.ai/models):" >&2
      jq -r --arg p "$hint/" --arg tp "~$hint/" \
        '[.data[].id | select(startswith($p) or startswith($tp)) | select(contains(":") | not)] | .[:12][] | "    " + .' \
        <<<"$catalog" >&2 || true
      return 1 ;;
  esac
}

if [ "$MODE" = check ]; then
  echo "run-agent.sh: stage=$STAGE harness=$HARNESS model=$MODEL"
  check_model
  exit $?
fi

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------
PROMPT_FILE="${2:?usage: run-agent.sh <stage> <prompt-file> <tool-profile>}"
TOOL_PROFILE="${3:?usage: run-agent.sh <stage> <prompt-file> <tool-profile>}"

if [ -n "${OPENROUTER_KEY_CIPHER:-}" ]; then
  if [ -z "${FACTORY_KEY_PASSPHRASE:-}" ]; then
    echo "run-agent.sh: FACTORY_KEY_PASSPHRASE secret is missing -- run: .factory/factory.sh setup" >&2
    exit 1
  fi
  if ! OPENROUTER_API_KEY="$(printf '%s\n' "$OPENROUTER_KEY_CIPHER" \
        | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -a -A \
            -pass env:FACTORY_KEY_PASSPHRASE 2>/dev/null)" || [ -z "$OPENROUTER_API_KEY" ]; then
    echo "run-agent.sh: couldn't decrypt this build's key (was FACTORY_KEY_PASSPHRASE rotated mid-run?)" >&2
    exit 1
  fi
  # Register the mask before anything can print the key.
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$OPENROUTER_API_KEY"
  export OPENROUTER_API_KEY
  unset FACTORY_KEY_PASSPHRASE OPENROUTER_KEY_CIPHER
fi

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "run-agent.sh: no key -- set OPENROUTER_API_KEY for local runs (https://openrouter.ai/keys); in CI the mint-key job provides one" >&2
  exit 1
fi
if [ ! -f "$PROMPT_FILE" ]; then
  echo "run-agent.sh: prompt file '$PROMPT_FILE' does not exist" >&2
  exit 1
fi

openrouter_key_info() {
  # Prints the HTTP status; key info JSON goes to $1. The key is fed to curl
  # on stdin (-H @-) so it never appears in a process list.
  printf 'Authorization: Bearer %s\n' "$OPENROUTER_API_KEY" \
    | curl -sS --max-time 20 -o "$1" -w '%{http_code}' -H @- https://openrouter.ai/api/v1/key 2>/dev/null \
    || echo 000
}

KEY_INFO="$(mktemp)"
case "$(openrouter_key_info "$KEY_INFO")" in
  200)
    echo "run-agent.sh: key OK ($(jq -r '.data | "spent $\(.usage // 0) of \(if .limit then "$\(.limit)" else "no limit" end)"' "$KEY_INFO" 2>/dev/null))" ;;
  401|403)
    echo "run-agent.sh: OpenRouter rejected the key (401). In CI this means this build's throwaway key was already deleted -- a job was retried after the run finished. Use 'Re-run all jobs', not 'Re-run failed jobs'." >&2
    exit 1 ;;
  *)
    echo "run-agent.sh: WARNING: couldn't verify the key with OpenRouter; continuing." >&2 ;;
esac

check_model

echo "run-agent.sh: stage=$STAGE harness=$HARNESS@$HARNESS_VERSION model=$MODEL max_turns=${MAX_TURNS:-none}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- **$STAGE**: \`$HARNESS@$HARNESS_VERSION\` · \`$MODEL\` · maxTurns=${MAX_TURNS:-n/a}" >> "$GITHUB_STEP_SUMMARY"
fi

# Harness config/state goes in a scratch dir, never in $HOME or the repo, so
# local runs don't clobber your own ~/.codex or opencode setup and CI runs
# don't leave files that trip the path allowlists.
AGENT_TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/run-agent-$STAGE.XXXXXX")"

# Linux caps a single argv string at 128 KiB; harnesses that take the prompt
# as an argument get it from a file instead once it's anywhere near that.
PROMPT_BYTES=$(wc -c < "$PROMPT_FILE")

npm_install() {
  # npm_install <package> <binary>
  if ! command -v "$2" >/dev/null 2>&1; then
    npm install -g "$1@$HARNESS_VERSION"
  fi
}

run_claude_code() {
  npm_install @anthropic-ai/claude-code claude

  export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
  export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
  # Must be an explicitly empty string, not unset -- otherwise Claude Code
  # may fall back to authenticating against Anthropic directly.
  export ANTHROPIC_API_KEY=""
  # Claude Code picks a tier (Fable/Opus/Sonnet/Haiku) for internal and
  # sub-agent calls. Pin every tier to this stage's model so all traffic is
  # billed to, and served by, the model you configured.
  export ANTHROPIC_DEFAULT_FABLE_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
  export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

  if [ -z "$MAX_TURNS" ]; then
    MAX_TURNS=8
    echo "run-agent.sh: no maxTurns set for stage '$STAGE'; defaulting to $MAX_TURNS" >&2
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

opencode_permissions() {
  # Translate the Claude-style tool profile into opencode's permission block.
  local edit=deny
  case ",$TOOL_PROFILE," in *,Write,*|*,Edit,*) edit=allow ;; esac
  local bash_rules='{"*":"deny"}'
  local pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    bash_rules="$(jq -c --arg p "$pattern" '. + {($p): "allow"}' <<<"$bash_rules")"
  done < <(grep -o 'Bash([^)]*)' <<<"$TOOL_PROFILE" | sed -E 's/^Bash\((.*)\)$/\1/')
  jq -n --arg edit "$edit" --argjson bash "$bash_rules" \
    '{edit: $edit, bash: $bash, webfetch: "deny", external_directory: "allow"}'
}

run_opencode() {
  npm_install opencode-ai opencode

  # Registering the slug under provider.openrouter.models makes ids that
  # aren't in opencode's bundled catalog (new releases, ~aliases) work too.
  export OPENCODE_CONFIG="$AGENT_TMP/opencode.json"
  jq -n --arg model "$MODEL" --argjson perm "$(opencode_permissions)" '{
    "$schema": "https://opencode.ai/config.json",
    autoupdate: false,
    share: "disabled",
    model: ("openrouter/" + $model),
    provider: { openrouter: {
      options: { apiKey: "{env:OPENROUTER_API_KEY}" },
      models: { ($model): {} }
    } },
    permission: $perm
  }' > "$OPENCODE_CONFIG"

  # </dev/null: `opencode run` appends piped stdin to the message, and an
  # inherited open stdin would block it forever.
  if [ "$PROMPT_BYTES" -lt 100000 ]; then
    opencode run --model "openrouter/$MODEL" --auto --format json \
      "$(cat "$PROMPT_FILE")" < /dev/null
  else
    opencode run --model "openrouter/$MODEL" --auto --format json \
      --file "$PROMPT_FILE" "Follow the instructions in the attached file exactly." < /dev/null
  fi
}

run_codex() {
  npm_install @openai/codex codex

  export CODEX_HOME="$AGENT_TMP/codex"
  mkdir -p "$CODEX_HOME"
  # Matches OpenRouter's own Codex guide: wire_api must be "responses" (the
  # chat protocol was removed), and command-based auth (rather than env_key)
  # makes Codex load OpenRouter's model catalog so non-OpenAI slugs don't run
  # with "unknown model" defaults. approval_policy=never because there's no
  # human to approve in CI; network_access lets the product test command reach services (e.g. a database).
  cat > "$CODEX_HOME/config.toml" <<EOF
model_provider = "openrouter"
model = "$MODEL"
approval_policy = "never"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
wire_api = "responses"

[model_providers.openrouter.auth]
command = "sh"
args = ["-c", "echo \$OPENROUTER_API_KEY"]
EOF

  # "-" reads the prompt from stdin, so prompt size is never an issue.
  codex exec \
    --skip-git-repo-check \
    -m "$MODEL" \
    - < "$PROMPT_FILE"
}

run_harness() {
  case "$HARNESS" in
    claude-code) run_claude_code ;;
    opencode) run_opencode ;;
    codex) run_codex ;;
  esac
}

if [ -n "${FACTORY_RUN_DIR:-}" ]; then
  mkdir -p "$FACTORY_RUN_DIR"
  {
    echo "===== $(date -u +%FT%TZ) $STAGE · $HARNESS@$HARNESS_VERSION · $MODEL ====="
    cat "$PROMPT_FILE"
    echo
  } | bash "$(dirname "$0")/scrub.sh" --stdin >> "$FACTORY_RUN_DIR/prompts-$STAGE.md"
  # The log is uploaded as an artifact, and GitHub only masks secrets in job
  # logs, not artifacts. Scrub the key in case an agent echoes its env.
  run_harness 2>&1 | bash "$(dirname "$0")/scrub.sh" --stdin | tee -a "$FACTORY_RUN_DIR/agent-$STAGE.log" || STATUS=$?
else
  run_harness || STATUS=$?
fi
STATUS="${STATUS:-0}"

# A harness that dies mid-run because the key hit its credit cap usually
# says something cryptic; say it plainly.
if [ "$STATUS" -ne 0 ] && [ "$(openrouter_key_info "$KEY_INFO")" = 200 ] \
   && [ "$(jq -r '(.data.limit_remaining // 1) <= 0' "$KEY_INFO" 2>/dev/null)" = true ]; then
  echo "run-agent.sh: this build's key hit its spending cap. Raise runKey.limitUsd in .factory/orchestrator.config.json." >&2
fi
rm -f "$KEY_INFO"
exit "$STATUS"
