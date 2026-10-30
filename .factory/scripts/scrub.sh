#!/usr/bin/env bash
#
# scrub.sh -- redact secrets from files before they're published (run-record
# artifacts, issue comments, PR bodies).
#
# Usage:
#   SCRUB_EXTRA="<literal>" scrub.sh <file>...   rewrite files in place
#   scrub.sh --stdin                             filter stdin to stdout
#
# Replaces with "***":
#   - anything shaped like an OpenRouter key (sk-or-..., any version)
#   - $OPENROUTER_API_KEY and $SCRUB_EXTRA, matched literally if set (e.g.
#     the key-encryption passphrase)
#
# GitHub masks secrets only in job logs; files uploaded or posted from a job
# get no such treatment, so every publish path goes through this first.

set -euo pipefail

filter() {
  # No {n,} intervals: Ubuntu's default awk (mawk) may not support them.
  # Literal (index/substr) matching for env values, so regex characters in a
  # secret can't break or bypass it; ENVIRON avoids awk's -v escape handling.
  awk '{
    gsub(/sk-or-[A-Za-z0-9]+-[A-Za-z0-9_-]+/, "***")
    n = split(ENVIRON["OPENROUTER_API_KEY"] "\n" ENVIRON["SCRUB_EXTRA"], lits, "\n")
    for (j = 1; j <= n; j++) {
      k = lits[j]
      if (length(k) < 8) continue
      while ((i = index($0, k)) > 0)
        $0 = substr($0, 1, i - 1) "***" substr($0, i + length(k))
    }
    print; fflush()
  }'
}

if [ "${1:-}" = "--stdin" ]; then
  filter
  exit 0
fi

for f in "$@"; do
  [ -f "$f" ] || continue
  tmp="$(mktemp)"
  filter < "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
done
