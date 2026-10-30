#!/usr/bin/env bash
#
# setup.sh -- one-time (idempotent) GitHub setup for the agent orchestrator.
#
# Usage (from the repo root):
#   .factory/factory.sh setup     # or: bash .factory/scripts/setup.sh
#   .factory/factory.sh check     # or: bash .factory/scripts/setup.sh --check
#
# Setup mode does everything the pipeline needs, skipping what's already done:
#   1. key isolation (see README "Keeping your OpenRouter key safe"):
#      - a "factory" environment that only releases secrets to the default branch
#      - OPENROUTER_MANAGEMENT_KEY in that environment (from
#        $OPENROUTER_MANAGEMENT_KEY, or pasted with echo off; validated with
#        OpenRouter first; never written to disk or put on a command line)
#      - FACTORY_KEY_PASSPHRASE repo secret, generated randomly
#      - warns if a plain OPENROUTER_API_KEY repo secret is still around
#   2. the trigger label, the nlspec label, and the agent:* status labels
#   3. workflow permissions: read/write GITHUB_TOKEN + Actions may open PRs
#   4. validates every stage's model slug against OpenRouter's catalog
#   5. warns if the default branch doesn't require pull requests
#
# --check only reports; it changes nothing. Safe to re-run any time.

set -uo pipefail

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

CONFIG=".factory/orchestrator.config.json"
RUN_AGENT=".factory/scripts/run-agent.sh"
FAILURES=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "Prerequisites"
for bin in gh jq curl openssl; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin installed"; else fail "$bin not found -- install it first"; fi
done
[ -f "$CONFIG" ] || { fail "$CONFIG not found -- run this from the repo root"; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not logged in -- run: gh auth login"
  exit 1
fi
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
if [ -z "$REPO" ]; then
  fail "couldn't detect the GitHub repo -- is 'origin' a GitHub remote?"
  exit 1
fi
ok "repo: $REPO"

ENV=factory
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)

mgmt_key_valid() {
  # Key on stdin to curl (-H @-), never argv; prints nothing but the status.
  [ "$(printf 'Authorization: Bearer %s\n' "$1" \
    | curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -H @- https://openrouter.ai/api/v1/keys 2>/dev/null)" = 200 ]
}

step "1. Key isolation"
# 1a. Environment that only releases its secrets to the default branch.
# (gh api prints the error body to stdout on a 404, hence the || resets.)
ENV_JSON=$(gh api "repos/$REPO/environments/$ENV" 2>/dev/null) || ENV_JSON=""
POLICIES=$(gh api "repos/$REPO/environments/$ENV/deployment-branch-policies" \
  --jq '[.branch_policies[].name] | join(",")' 2>/dev/null) || POLICIES=""
if [ -n "$ENV_JSON" ] && [ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$ENV_JSON")" = true ] \
   && [ "$POLICIES" = "$DEFAULT_BRANCH" ]; then
  ok "environment '$ENV' only releases secrets to '$DEFAULT_BRANCH'"
elif $CHECK_ONLY; then
  fail "environment '$ENV' missing or not restricted to '$DEFAULT_BRANCH' (allowed: ${POLICIES:-none}) -- run: .factory/factory.sh setup"
elif [ -n "$POLICIES" ] && [ "$POLICIES" != "$DEFAULT_BRANCH" ]; then
  fail "environment '$ENV' allows other branches ($POLICIES). Fix by hand: Settings → Environments → $ENV → Deployment branches → only '$DEFAULT_BRANCH'"
elif printf '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
       | gh api -X PUT "repos/$REPO/environments/$ENV" --input - >/dev/null 2>&1 \
     && { [ "$POLICIES" = "$DEFAULT_BRANCH" ] \
          || gh api -X POST "repos/$REPO/environments/$ENV/deployment-branch-policies" \
               -f name="$DEFAULT_BRANCH" -f type=branch >/dev/null 2>&1; }; then
  ok "environment '$ENV' created, restricted to '$DEFAULT_BRANCH'"
else
  fail "couldn't create environment '$ENV' (private repos need GitHub Pro/Team for environments). Create it by hand: Settings → Environments"
fi

# 1b. Management key -- lives only in that environment.
if gh secret list --env "$ENV" --repo "$REPO" 2>/dev/null | awk '{print $1}' | grep -qx OPENROUTER_MANAGEMENT_KEY; then
  ok "OPENROUTER_MANAGEMENT_KEY is set in '$ENV'"
elif $CHECK_ONLY; then
  fail "OPENROUTER_MANAGEMENT_KEY missing from environment '$ENV' -- run: .factory/factory.sh setup"
else
  MGMT="${OPENROUTER_MANAGEMENT_KEY:-}"
  if [ -z "$MGMT" ]; then
    echo "  Create a management key at https://openrouter.ai/settings/management-keys"
    echo "  (give it an expiry). It can mint and delete keys but can't call models."
    read -rsp "  Paste it (input hidden): " MGMT; echo
  fi
  if [ -z "$MGMT" ]; then
    fail "no management key given"
  elif ! mgmt_key_valid "$MGMT"; then
    fail "OpenRouter rejected that as a management key (a regular sk-or key won't work here)"
  elif printf '%s' "$MGMT" | gh secret set OPENROUTER_MANAGEMENT_KEY --env "$ENV" --repo "$REPO"; then
    ok "OPENROUTER_MANAGEMENT_KEY validated and stored in '$ENV'"
  else
    fail "couldn't store OPENROUTER_MANAGEMENT_KEY"
  fi
  MGMT=""
fi

# 1c. Passphrase that encrypts each run key between jobs.
if gh secret list --repo "$REPO" 2>/dev/null | awk '{print $1}' | grep -qx FACTORY_KEY_PASSPHRASE; then
  ok "FACTORY_KEY_PASSPHRASE is set"
elif $CHECK_ONLY; then
  fail "FACTORY_KEY_PASSPHRASE missing -- run: .factory/factory.sh setup"
elif openssl rand -hex 32 | gh secret set FACTORY_KEY_PASSPHRASE --repo "$REPO"; then
  ok "FACTORY_KEY_PASSPHRASE generated and stored"
else
  fail "couldn't store FACTORY_KEY_PASSPHRASE"
fi

# 1d. A long-lived plain key as a repo secret defeats the whole design.
if gh secret list --repo "$REPO" 2>/dev/null | awk '{print $1}' | grep -qx OPENROUTER_API_KEY; then
  warn "repo secret OPENROUTER_API_KEY is no longer used. Delete it (gh secret delete OPENROUTER_API_KEY) and revoke that key at openrouter.ai/settings/keys"
fi

step "2. Labels"
TRIGGER=$(jq -r '.label // "build"' "$CONFIG")
EXISTING=$(gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null)
for l in "$TRIGGER" nlspec agent:qa-done agent:coder-done agent:review-done agent:pr-open agent:merged agent:failed; do
  if grep -qx -- "$l" <<<"$EXISTING"; then
    ok "$l"
  elif $CHECK_ONLY; then
    fail "label '$l' missing"
  else
    color=ededed; [ "$l" = "$TRIGGER" ] && color=0e8a16
    gh label create "$l" --repo "$REPO" --color "$color" >/dev/null && ok "$l (created)" || fail "couldn't create label '$l'"
  fi
done

step "3. Workflow permissions"
PERMS=$(gh api "repos/$REPO/actions/permissions/workflow" 2>/dev/null)
if [ "$(jq -r '.default_workflow_permissions' <<<"$PERMS")" = "write" ] \
   && [ "$(jq -r '.can_approve_pull_request_reviews' <<<"$PERMS")" = "true" ]; then
  ok "GITHUB_TOKEN has write access and may open PRs"
elif $CHECK_ONLY; then
  fail "workflow permissions not set -- run: .factory/factory.sh setup"
elif gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
       -f default_workflow_permissions=write -F can_approve_pull_request_reviews=true >/dev/null 2>&1; then
  ok "set to read/write + allow Actions to create PRs"
else
  fail "couldn't set them (an org policy may lock this). Do it by hand: Settings → Actions → General → Workflow permissions"
fi

step "4. Stage models (from $CONFIG)"
for stage in qa coder review; do
  if out=$(bash "$RUN_AGENT" --check "$stage" 2>&1); then
    ok "$(bash "$RUN_AGENT" --resolve "$stage")"
    grep -i warning <<<"$out" | sed 's/^run-agent.sh: /    /'
  else
    fail "$(bash "$RUN_AGENT" --resolve "$stage")"
    sed 's/^/    /' <<<"$out"
  fi
done

step "5. Default branch protection"
RULES=$(gh api "repos/$REPO/rules/branches/$DEFAULT_BRANCH" --jq '[.[].type] | join(",")' 2>/dev/null) || RULES=""
if grep -q pull_request <<<"$RULES" \
   || gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection/required_pull_request_reviews" >/dev/null 2>&1; then
  ok "'$DEFAULT_BRANCH' requires pull requests"
else
  warn "'$DEFAULT_BRANCH' accepts direct pushes. Add a ruleset requiring PRs (Settings → Rules → Rulesets) so a stolen"
  warn "workflow token can't push straight to it -- see README \"Keeping your OpenRouter key safe\""
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '\033[31m%d problem(s) found.\033[0m\n' "$FAILURES"
  exit 1
fi
cat <<EOF
$(printf '\033[32mAll set.\033[0m') Next:
  1. Push this repo's workflows to the default branch (dispatch only sees workflows there).
  2. Smoke-test a harness/model:  gh workflow run spine-test.yml -f harness=config
  3. File an issue from the NLSpec template and apply the '$TRIGGER' label.
EOF
