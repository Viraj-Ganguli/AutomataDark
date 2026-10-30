# factory-bin.sh -- sourced by the factory scripts: sets FACTORY_BIN to the
# Lean `factory` executable (.factory/lean), the code that makes every gate
# decision.
#
# Lookup order: $FACTORY_BIN; a `factory` binary next to the calling script
# (CI copies the prebuilt one into its $FACTORY_SCRIPTS snapshot, out of the
# agent's reach); the local build under .factory/lean/.lake. Build that with:
#   (cd .factory/lean && lake build)

if [ -z "${FACTORY_BIN:-}" ]; then
  _here=$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)
  _root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  if [ -x "$_here/factory" ]; then
    FACTORY_BIN="$_here/factory"
  elif [ -x "$_root/.factory/lean/.lake/build/bin/factory" ]; then
    FACTORY_BIN="$_root/.factory/lean/.lake/build/bin/factory"
  else
    echo "factory binary not found -- build it with: (cd .factory/lean && lake build)" >&2
    exit 2
  fi
fi
