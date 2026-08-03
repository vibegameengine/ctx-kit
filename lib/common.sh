#!/usr/bin/env bash
# Shared helpers for ctx-kit.
# Sourced by install.sh / verify.sh / uninstall.sh — not meant to run directly.

set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_OFF=
fi

FAILURES=0
WARNINGS=0

step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '  %s[OK]%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '  %s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

die() { printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Node-CLI resolution.
#
# THE core lesson this kit encodes: npm-global CLIs installed under a Node
# version manager are NOT on PATH in the shell that runs Claude Code hooks, and
# they are `#!/usr/bin/env node` shims — so even an absolute path fails, because
# the shebang cannot find `node`. The result is a silent `exit 127`: the hook
# does nothing and the UI reports nothing.
#
# Every hook this kit installs therefore (a) resolves the binary across the
# common version-manager layouts and (b) puts its directory on PATH so the
# shebang resolves `node` too.
# ---------------------------------------------------------------------------

# Search order mirrors what the generated hook commands do at runtime.
node_cli_search_globs() {
  local name="$1"
  printf '%s\n' \
    "$HOME/.nvm/versions/node/"*"/bin/$name" \
    "$HOME/.volta/bin/$name" \
    "$HOME/.local/share/fnm/node-versions/"*"/installation/bin/$name" \
    "$HOME/.asdf/installs/nodejs/"*"/bin/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/bin/$name" 2>/dev/null
}

# resolve_node_cli <name> -> prints absolute path, or returns 1
resolve_node_cli() {
  local name="$1" p
  p="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  while IFS= read -r p; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done < <(node_cli_search_globs "$name" | sort -r)
  return 1
}

# The runtime prelude embedded in every generated hook command.
# Kept in one place so install.sh and verify.sh can never drift apart.
hook_prelude() {
  local name="$1"
  cat <<PRELUDE
CG=\$(command -v $name 2>/dev/null); [ -x "\$CG" ] || CG=\$(ls -t "\$HOME"/.nvm/versions/node/*/bin/$name "\$HOME"/.volta/bin/$name "\$HOME"/.local/share/fnm/node-versions/*/installation/bin/$name "\$HOME"/.asdf/installs/nodejs/*/bin/$name /opt/homebrew/bin/$name /usr/local/bin/$name 2>/dev/null | head -1); [ -x "\$CG" ] || exit 0; export PATH="\$(dirname "\$CG"):\$PATH"
PRELUDE
}

# Run a command the way a hook shell would see the world: no inherited PATH,
# no profile, no version manager. This is the ONLY test that catches exit 127.
run_in_bare_env() {
  local cmd="$1" stdin_json="${2:-\{\}}"
  printf '%s' "$stdin_json" | env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "$cmd"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH — $2"
}

# Resolve the project directory (git root by default).
resolve_project_dir() {
  local d="${1:-$PWD}"
  if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$d" rev-parse --show-toplevel
  else
    ( cd "$d" && pwd )
  fi
}

KIT_MARKER='[ctx-kit]'
