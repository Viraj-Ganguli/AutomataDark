#!/usr/bin/env bash
#
# proofs.sh -- the proof-obligation gate for a product's Lean proofs package.
#
# Usage: proofs.sh [dir]   (default: product.proofs from the config; a no-op if unset)
#
# A proofs package (see .factory/lean/README.md, "Proof obligations") has:
#   Spec/                    protected, human-approved: the model, invariants,
#                            and the obligations as predicates
#   Spec/obligations.json    which theorem must prove which predicate about
#                            which implementation constant
#   Impl/                    the coder agent's: implementations and proofs
#   lakefile.toml, lean-toolchain   protected
#
# The gate builds the package (the Lean kernel checks every proof) and then
# runs check-proofs.lean, which fails on a missing or weakened statement,
# `sorry`, a non-standard axiom, `native_decide`, a shadowed predicate, or an
# @[implemented_by]/@[extern] swap. The package must use the factory's Lean
# toolchain, since the checker is written against that Lean version.
#
# The package is always rebuilt from source, in a clean copy without .lake/.
# Agent-written Lean runs during `lake build`, so the factory's key material
# is removed from its environment.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG="${ORCHESTRATOR_CONFIG:-.factory/orchestrator.config.json}"
DIR="${1:-$(jq -r '.product.proofs // ""' "$CONFIG")}"

if [ -z "$DIR" ]; then
  echo "No product.proofs configured; no proof obligations to check."
  exit 0
fi
MANIFEST="Spec/obligations.json"
[ -f "$DIR/$MANIFEST" ] || { echo "proofs.sh: $DIR/$MANIFEST not found"; exit 1; }

# The checker and the factory's toolchain: next to this script in a CI
# snapshot, or in .factory/lean locally.
CHECKER="$HERE/check-proofs.lean"
TOOLCHAIN="$HERE/lean-toolchain"
[ -f "$TOOLCHAIN" ] || TOOLCHAIN="$HERE/../lean/lean-toolchain"
if ! cmp -s "$TOOLCHAIN" "$DIR/lean-toolchain"; then
  echo "proofs.sh: $DIR/lean-toolchain must match the factory's ($(cat "$TOOLCHAIN"))"
  exit 1
fi

LAKE=$(command -v lake || echo "$HOME/.elan/bin/lake")
if [ ! -x "$LAKE" ]; then
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none >/dev/null
  LAKE="$HOME/.elan/bin/lake"
fi

clean() { env -u FACTORY_KEY_PASSPHRASE -u OPENROUTER_KEY_CIPHER -u OPENROUTER_API_KEY "$@"; }

# Build from source in a clean copy: a committed or tampered .lake/ could
# hold forged .olean files the kernel never re-checks, and building in place
# would leave build output in the agent's working tree.
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
rsync -a --exclude .lake "$DIR/" "$BUILD/"
cd "$BUILD"
echo "Building proofs from $DIR in a clean copy (the kernel checks every proof)..."
# pipefail: the `if` sees lake's status, not tail's.
if ! clean "$LAKE" build 2>&1 | tail -40; then
  echo "Proof obligations not met: the proofs package doesn't build."
  exit 1
fi
clean "$LAKE" env lean --run "$CHECKER" check "$MANIFEST"
