#!/usr/bin/env bash
#
# models.test.sh -- model ladders (models.sh, run-agent.sh) and usage lines
# (usage.sh) for every harness. No network, no agent.
#
# Usage: bash .factory/scripts/tests/models.test.sh

set -uo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export ORCHESTRATOR_CONFIG="$WORK/config.json" SKIP_MODEL_CHECK=1
unset STAGE_OVERRIDE_MODEL STAGE_OVERRIDE_HARNESS FACTORY_LOCAL_MODEL FACTORY_LOCAL_CODER_MODELS FACTORY_LOCAL_QA_MODELS

PASS=0; FAIL=0
eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok    $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fi
}
pick() { bash "$S/models.sh" pick "$@" | paste -sd'|' -; }

cat > "$ORCHESTRATOR_CONFIG" <<'EOF'
{
  "harness": "claude-code",
  "model": "~anthropic/claude-sonnet-latest",
  "maxAttempts": 1,
  "localModel": "sonnet",
  "stages": {
    "coder": {
      "model": ["opencode:~google/gemini-flash-latest", "openai/gpt-oss-20b:free", "codex:openai/gpt-5.3-codex"],
      "localModel": ["claude:haiku", "codex:gpt-5.5"],
      "maxAttempts": 2
    },
    "review": { "harness": "opencode" }
  }
}
EOF

echo "models.sh"
eq "a plain model, no harness"            "|~anthropic/claude-sonnet-latest" "$(pick ci qa 1)"
eq "a ladder entry names its harness"     "opencode|~google/gemini-flash-latest" "$(pick ci coder 1)"
eq "a ':' inside a model id isn't a harness" "|openai/gpt-oss-20b:free" "$(pick ci coder 2)"
eq "the last entry repeats"               "codex|openai/gpt-5.3-codex" "$(pick ci coder 7)"
eq "ladder length"                        "3" "$(bash "$S/models.sh" count ci coder)"
eq "local ladder from localModel"         "codex|gpt-5.5" "$(pick local coder 2)"
eq "local single model"                   "|sonnet" "$(pick local review 1)"
eq "FACTORY_LOCAL_MODEL overrides config" "claude|opus" "$(FACTORY_LOCAL_MODEL=claude-code:opus pick local qa 1)"
eq "per-stage env ladder wins"            "|b" "$(FACTORY_LOCAL_MODEL=x FACTORY_LOCAL_CODER_MODELS='a, b' pick local coder 2)"
eq "a bare harness means its default model" "codex|" "$(FACTORY_LOCAL_MODEL=codex: pick local qa 1)"
eq "dispatch override replaces the ladder" "|x/y" "$(STAGE_OVERRIDE_MODEL=x/y pick ci coder 2)"

echo "run-agent.sh"
eq "attempt picks harness and model"      "opencode ~google/gemini-flash-latest" \
  "$(FACTORY_ATTEMPT=1 bash "$S/run-agent.sh" --get coder harness) $(FACTORY_ATTEMPT=1 bash "$S/run-agent.sh" --get coder model)"
eq "no harness in the entry: the stage's" "opencode" "$(bash "$S/run-agent.sh" --get review harness)"
eq "attempts = max(maxAttempts, ladder)"  "3" "$(bash "$S/run-agent.sh" --get coder maxAttempts)"
bash "$S/run-agent.sh" --resolve coder | grep -q 'models=\[opencode:~google/gemini-flash-latest -> claude-code:openai/gpt-oss-20b:free -> codex:openai/gpt-5.3-codex\]'
eq "--resolve shows the ladder" 0 $?
bash "$S/run-agent.sh" --check coder >/dev/null 2>&1; eq "--check accepts every entry" 0 $?
jq '.stages.coder.model = ["~a/b", "bogus:~c/d"] | .stages.coder.harness = "bogus"' "$ORCHESTRATOR_CONFIG" > "$WORK/bad.json"
ORCHESTRATOR_CONFIG="$WORK/bad.json" bash "$S/run-agent.sh" --check coder >/dev/null 2>&1; eq "--check refuses an unknown harness" 1 $?

echo "usage.sh"
u() { bash "$S/usage.sh" "$@" | jq -c "$JQ"; }
JQ='[.harness, .model, .attempt, .turns, .inputTokens, .outputTokens, .costUsd, .error]'
cat > "$WORK/claude.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":9,"total_cost_usd":0.0163,"usage":{"input_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":80,"output_tokens":300},"modelUsage":{"claude-haiku-5-5":{"costUSD":0.0163}}}
EOF
eq "claude: json"         '["claude","haiku",1,9,1100,300,0.0163,null]' "$(u claude coder 1 haiku 46 "$WORK/claude.json")"
{ echo '{"type":"system","subtype":"init"}'; echo 'not json'; cat "$WORK/claude.json"; } > "$WORK/stream.jsonl"
eq "claude-code: stream-json" '["claude-code","m",2,9,1100,300,0.0163,null]' "$(u claude-code coder 2 m 5 "$WORK/stream.jsonl")"
JQ='.costByModel'; eq "claude: cost per model" '{"claude-haiku-5-5":0.0163}' "$(u claude coder 1 haiku 1 "$WORK/claude.json")"
JQ='[.harness, .model, .attempt, .turns, .inputTokens, .outputTokens, .costUsd, .error]'
cat > "$WORK/codex.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"t"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"pytest -q"}}
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"done"}}
{"type":"turn.completed","usage":{"input_tokens":15923,"cached_input_tokens":12160,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":7}}
EOF
eq "codex: tokens, no cost" '["codex","default",1,2,15923,12,null,null]' "$(u codex coder 1 "" 3 "$WORK/codex.jsonl")"
cat > "$WORK/opencode.jsonl" <<'EOF'
{"type":"step_start","part":{}}
{"type":"text","part":{"text":"hi"}}
{"type":"step_finish","part":{"reason":"tool-calls","cost":0.01,"tokens":{"input":100,"output":10,"reasoning":5,"cache":{"read":50,"write":0}}}}
{"type":"step_finish","part":{"reason":"stop","cost":0.02,"tokens":{"input":200,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}}}
EOF
eq "opencode: summed over steps" '["opencode","x/y",1,2,350,35,0.03,null]' "$(u opencode review 1 x/y 9 "$WORK/opencode.jsonl")"
: > "$WORK/empty"
eq "nothing reported: nulls, not a crash" '["codex","m",1,0,null,null,null,null]' "$(u codex qa 1 m 0 "$WORK/empty")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
