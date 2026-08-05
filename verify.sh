#!/usr/bin/env bash
#
# ctx-kit — verify every layer, with evidence rather than config-reading.
#
#   ./verify.sh [--project-dir DIR] [--no-probe]
#
# Exits non-zero if any check fails.
#
# The check that matters most is the bare-env probe: it extracts the hook command
# FROM the settings file and runs it under `env -i`, then proves a brand-new symbol
# reached the graph. Reading the JSON back only proves the JSON is what we wrote.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$KIT_DIR/lib/common.sh"

PROJECT_DIR=""
DO_PROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:?}"; shift 2 ;;
    --no-probe) DO_PROBE=0; shift ;;
    -h|--help) echo "usage: ./verify.sh [--project-dir DIR] [--no-probe]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
PROJECT_DIR="$(resolve_project_dir "${PROJECT_DIR:-$PWD}")"
SETTINGS="$PROJECT_DIR/.claude/settings.local.json"

# ---------------------------------------------------------------------------
step "Toolchain"
# ---------------------------------------------------------------------------
if CG="$(resolve_node_cli code-graph-mcp 2>/dev/null)"; then
  ok "code-graph-mcp -> $CG"
  export PATH="$(dirname "$CG"):$PATH"
else
  fail "code-graph-mcp not found (plugin not installed, or Claude Code not restarted yet)"
  CG=""
fi

if CMCP="$(resolve_node_cli compressmcp 2>/dev/null)"; then
  ok "compressmcp -> $CMCP"
else
  warn "compressmcp not found (optional)"
  CMCP=""
fi

# ---------------------------------------------------------------------------
step "Plugins"
# ---------------------------------------------------------------------------
plugins="$(claude plugin list 2>/dev/null || true)"
for p in context-mode code-graph-mcp; do
  if printf '%s' "$plugins" | grep -q "$p"; then
    ver="$(printf '%s' "$plugins" | grep -A1 "$p@" | grep -o 'Version: .*' | head -1)"
    ok "$p installed ${ver:+(${ver#Version: })}"
  else
    fail "$p not installed"
  fi
done

# ---------------------------------------------------------------------------
step "compressmcp wiring"
# ---------------------------------------------------------------------------
if [ -n "$CMCP" ]; then
  status="$("$CMCP" check 2>&1 || true)"
  printf '%s' "$status" | grep -q 'compress): *✓' && ok "PostToolUse compress hook" || fail "PostToolUse compress hook missing"

  # NOT `compressmcp check`, and NOT the settings file. Its installer writes
  # mcpServers into ~/.claude/settings.json, and Claude Code does not read MCP
  # config from there at all — servers live in ~/.claude.json (local/user scope)
  # or a project .mcp.json. So the entry is real, `compressmcp check` reports it
  # as registered, any verifier that reads the same file agrees, and the server
  # has never once started. Ask the only component whose opinion decides.
  mcp_list="$(claude mcp list 2>/dev/null || true)"
  if printf '%s' "$mcp_list" | grep -q '^compressmcp:.*Connected'; then
    ok "MCP server connected (confirmed by claude mcp list)"
  elif printf '%s' "$mcp_list" | grep -q '^compressmcp:'; then
    fail "MCP server registered but not connecting — run: claude mcp get compressmcp"
  else
    fail "MCP server not registered where Claude Code reads it (~/.claude.json) — re-run ./install.sh"
  fi

  # `compressmcp check` reports the status line as missing whenever something
  # else owns settings.json -> statusLine. That is a false alarm when code-graph's
  # composite status line has adopted it as a provider, so check the registry.
  if printf '%s' "$status" | grep -q 'Status line: *✗'; then
    if grep -q 'compressmcp --status' "$HOME/.claude/statusline-providers.json" 2>/dev/null; then
      ok "status line chained via code-graph composite (compressmcp's own check is a false negative here)"
    else
      warn "status line not configured (cosmetic only)"
    fi
  else
    ok "status line configured"
  fi
fi

# ---------------------------------------------------------------------------
step "Project settings"
# ---------------------------------------------------------------------------
if [ ! -f "$SETTINGS" ]; then
  fail "missing $SETTINGS — run ./install.sh"
else
  if node -e "JSON.parse(require('fs').readFileSync('$SETTINGS','utf8'))" 2>/dev/null; then
    ok "settings.local.json is valid JSON"
  else
    fail "settings.local.json is malformed — this silently disables ALL settings in it"
  fi

  env_val="$(node -p "JSON.parse(require('fs').readFileSync('$SETTINGS','utf8')).env?.CODE_GRAPH_HOOK_INDEX ?? ''" 2>/dev/null || echo '')"
  [ "$env_val" = "on" ] && ok "env CODE_GRAPH_HOOK_INDEX=on" || fail "env CODE_GRAPH_HOOK_INDEX not set to 'on'"

  for ev in SessionStart UserPromptSubmit; do
    n="$(node -p "((JSON.parse(require('fs').readFileSync('$SETTINGS','utf8')).hooks?.$ev)||[]).flatMap(g=>g.hooks||[]).filter(h=>String(h.description||'').includes('$KIT_MARKER')).length" 2>/dev/null || echo 0)"
    [ "$n" = "1" ] && ok "$ev hook present" || fail "$ev hook: expected 1, found $n"
  done

  # The env var is only actually live once Claude Code has reloaded the config.
  if [ "${CODE_GRAPH_HOOK_INDEX:-}" = "on" ]; then
    ok "CODE_GRAPH_HOOK_INDEX is live in this shell's session"
  else
    warn "CODE_GRAPH_HOOK_INDEX not visible in the environment — open /hooks once or restart Claude Code"
  fi
fi

# ---------------------------------------------------------------------------
step "Git hygiene"
# ---------------------------------------------------------------------------
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  for entry in ".claude/settings.local.json" ".code-graph"; do
    if git -C "$PROJECT_DIR" check-ignore -q "$entry" 2>/dev/null; then
      ok "$entry is gitignored"
    else
      fail "$entry is NOT gitignored (it holds absolute machine paths / a large local DB)"
    fi
  done
else
  info "not a git repo — skipped"
fi

# ---------------------------------------------------------------------------
step "Index health"
# ---------------------------------------------------------------------------
if [ -n "$CG" ] && [ -d "$PROJECT_DIR/.code-graph" ]; then
  health="$( cd "$PROJECT_DIR" && "$CG" health-check 2>&1 || true )"
  printf '%s' "$health" | grep -q '^OK:' \
    && ok "$(printf '%s' "$health" | head -1)" \
    || fail "$(printf '%s' "$health" | head -1)"

  vec="$(printf '%s' "$health" | grep -i '^Search:' || true)"
  if printf '%s' "$vec" | grep -qi 'vector inactive'; then
    # The lazy background download often never fires at all — doctor keeps
    # reporting "no download has ever been attempted" indefinitely, while
    # semantic_code_search quietly degrades to keyword matching and still
    # returns plausible results. ./install-model.sh installs the weights by hand.
    warn "semantic search is keyword-only (FTS5/BM25), not vector — run ./install-model.sh"
  else
    ok "${vec:-vector search active}"
    printf '%s' "$vec" | grep -qi 'in progress' \
      && info "embedding coverage still filling — re-run ./install-model.sh to finish"
  fi
else
  [ -n "$CG" ] && fail "no .code-graph/ index in $PROJECT_DIR — run ./install.sh"
fi

# ---------------------------------------------------------------------------
step "Hook probe (bare environment)"
# ---------------------------------------------------------------------------
# This is the check that catches the failure mode nothing else does: a hook that
# exits 127 because the version-manager bin dir is not on PATH. A normal shell
# test passes misleadingly, because the interactive profile has already loaded it.
if [ "$DO_PROBE" -eq 0 ]; then
  info "skipped (--no-probe)"
elif [ -z "$CG" ] || [ ! -f "$SETTINGS" ] || [ ! -d "$PROJECT_DIR/.code-graph" ]; then
  info "skipped (prerequisites missing)"
else
  # The probe must land somewhere the indexer actually walks: .code-graph/ is
  # gitignored and skipped, so a probe there would never be indexed and this
  # check would report a false failure. Prefer a real source directory.
  # Note the `|| true`: under `set -e`, a for-loop whose final iteration ends in a
  # failed `&&` returns non-zero and would kill the script.
  PROBE_DIR="$PROJECT_DIR"
  for d in src lib app source; do
    if [ -d "$PROJECT_DIR/$d" ]; then PROBE_DIR="$PROJECT_DIR/$d"; break; fi
  done || true
  STAMP="$PROJECT_DIR/.code-graph/.auto-index-stamp"
  STAMP_BAK=""
  [ -f "$STAMP" ] && STAMP_BAK="$(cat "$STAMP")"
  PROBE_FILE=""

  cleanup_probe() {
    [ -n "$PROBE_FILE" ] && rm -f "$PROBE_FILE"
    if [ -n "$STAMP_BAK" ]; then printf '%s' "$STAMP_BAK" > "$STAMP"; else rm -f "$STAMP"; fi
    ( cd "$PROJECT_DIR" && "$CG" incremental-index --quiet ) >/dev/null 2>&1 || true
  }
  trap cleanup_probe EXIT

  # BOTH hooks, not just one. They are nearly the same command, and "nearly" is
  # exactly what a probe exists to catch: they differ in the throttle, in the
  # stdin they are handed, and in which of them a broken exit code takes down (a
  # non-zero UserPromptSubmit hook blocks every prompt). Verifying one and
  # asserting the other's mere presence is how a dead SessionStart hook sits
  # unnoticed for weeks.
  for ev in SessionStart UserPromptSubmit; do
    CMD="$(node -p "JSON.parse(require('fs').readFileSync('$SETTINGS','utf8')).hooks.$ev.flatMap(g=>g.hooks).find(h=>String(h.description||'').includes('$KIT_MARKER')).command" 2>/dev/null || true)"
    if [ -z "$CMD" ]; then
      fail "could not extract the $ev hook command from settings"
      continue
    fi

    PROBE_SYM="ctxKitProbe$ev$$"
    PROBE_FILE="$PROBE_DIR/__ctx_kit_probe_${ev}_$$.ts"
    printf 'export function %s(): number { return 1; }\n' "$PROBE_SYM" > "$PROBE_FILE"
    # Cleared so the throttled hook cannot decide it ran recently enough.
    rm -f "$STAMP"

    if [ "$ev" = "SessionStart" ]; then STDIN_JSON='{"source":"startup"}'; else STDIN_JSON='{"prompt":"probe"}'; fi
    set +e
    run_in_bare_env "$CMD" "$STDIN_JSON" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      fail "$ev exited $rc in a bare shell (127 = binary or node not on PATH; the hook would fail silently)"
    else
      ok "$ev exits 0 in a bare shell"
    fi

    if ( cd "$PROJECT_DIR" && "$CG" search "$PROBE_SYM" 2>/dev/null | grep -q "$PROBE_SYM" ); then
      ok "$ev put a brand-new symbol into the graph"
    else
      fail "$ev ran but the new symbol never reached the graph"
    fi

    rm -f "$PROBE_FILE"
    PROBE_FILE=""
    rm -f "$STAMP"
    ( cd "$PROJECT_DIR" && "$CG" incremental-index --quiet ) >/dev/null 2>&1 || true

    if ( cd "$PROJECT_DIR" && "$CG" search "$PROBE_SYM" 2>/dev/null | grep -q "$PROBE_SYM" ); then
      fail "$ev: deleted probe still in the graph — deletions are not being reindexed"
    else
      ok "$ev: deleting the file removed it from the graph"
    fi
  done

  cleanup_probe
  trap - EXIT
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '%s%d failed%s, %d warnings\n' "$C_RED" "$FAILURES" "$C_OFF" "$WARNINGS"
  exit 1
fi
printf '%sAll checks passed%s (%d warnings)\n' "$C_GRN" "$C_OFF" "$WARNINGS"
