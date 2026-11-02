#!/usr/bin/env bash
#
# usage.sh -- turn one agent session's raw output into one usage line, the
# same shape for every harness, so runs on different models can be compared.
#
# Usage: usage.sh <harness> <stage> <attempt> <model> <seconds> <output-file>
#   harness  claude | claude-code | codex | opencode
#
# Prints one JSON object:
#   {stage, attempt, harness, model, seconds, turns, inputTokens, outputTokens,
#    costUsd, costByModel, error}
# Fields a harness doesn't report are null: Codex reports tokens but no cost;
# Claude Code and opencode report both. costUsd is the harness's own figure
# (list price for Claude Code on a subscription, so not what you were billed,
# but a fair measure of compute).
#
# Reads Claude Code's json / stream-json, Codex's `exec --json` events, and
# opencode's `run --format json` events; other lines are ignored.

set -uo pipefail
H="${1:?harness}"; STAGE="${2:?stage}"; N="${3:?attempt}"; MODEL="${4-}"; SECS="${5:-0}"; OUT="${6:?output file}"

jq -c -n -R --arg h "$H" --arg stage "$STAGE" --argjson n "$N" --arg model "$MODEL" --argjson secs "$SECS" '
  [inputs | fromjson? | objects] as $ev
  | {stage: $stage, attempt: $n, harness: $h, model: (if $model == "" then "default" else $model end), seconds: $secs}
  + (if $h == "claude" or $h == "claude-code" then
       ([$ev[] | select(.type == "result" or has("total_cost_usd"))] | last) as $r
       | if $r == null then {} else
         {turns: $r.num_turns,
          inputTokens: (($r.usage // {}) | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)),
          outputTokens: $r.usage.output_tokens,
          costUsd: $r.total_cost_usd,
          costByModel: ($r.modelUsage // null | if . == null then null else map_values(.costUSD) end),
          error: (if $r.is_error then ($r.subtype // "error") else null end)} end
     elif $h == "codex" then
       [$ev[] | select(.type == "turn.completed") | .usage] as $u
       | {turns: ([$ev[] | select(.type == "item.completed")] | length),
          inputTokens: ([$u[] | .input_tokens // 0] | add),
          outputTokens: ([$u[] | (.output_tokens // 0) + (.reasoning_output_tokens // 0)] | add),
          error: ([$ev[] | select(.type == "error" or .type == "turn.failed")] | if length > 0 then "error" else null end)}
     elif $h == "opencode" then
       [$ev[] | select(.type == "step_finish") | .part] as $s
       | {turns: ($s | length),
          inputTokens: ([$s[].tokens | (.input // 0) + (.cache.read // 0) + (.cache.write // 0)] | add),
          outputTokens: ([$s[].tokens | (.output // 0) + (.reasoning // 0)] | add),
          costUsd: ([$s[].cost // empty] | if length > 0 then add else null end),
          error: ([$ev[] | select(.type == "error")] | if length > 0 then "error" else null end)}
     else {} end)
  | {stage, attempt, harness, model, seconds, turns, inputTokens, outputTokens, costUsd, costByModel, error}
' < "$OUT"
