#!/usr/bin/env bash
#
# ctx-kit — one-command setup of the context-saving stack for a repo.
#
#   ./install.sh                 # install everything into the current git repo
#   ./install.sh --help          # options
#
# Idempotent: safe to re-run. Every step checks its own state first.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$KIT_DIR/lib/common.sh"

PROJECT_DIR=""
THROTTLE=120
DO_PLUGINS=1
DO_COMPRESSMCP=1
DO_INDEX=1
ASSUME_YES=0

usage() {
  cat <<'USAGE'
ctx-kit installer

Usage: ./install.sh [options]

Options:
  --project-dir DIR   Repo to configure (default: git root of $PWD)
  --throttle SEC      Min seconds between mid-session reindexes (default: 120)
  --skip-plugins      Do not install the context-mode / code-graph-mcp plugins
  --skip-compressmcp  Do not install compressmcp (MCP response compression)
  --no-index          Do not build the initial code graph
  -y, --yes           Do not prompt
  -h, --help          This text

What it installs:
  1. context-mode      plugin — sandboxes large tool output out of the context window
  2. code-graph-mcp    plugin — tree-sitter AST graph, so the agent reads 15 files not 27k
  3. compressmcp       npm    — lossless compression of MCP tool responses
  4. project hooks     .claude/settings.local.json — keeps the graph fresh automatically
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:?}"; shift 2 ;;
    --throttle) THROTTLE="${2:?}"; shift 2 ;;
    --skip-plugins) DO_PLUGINS=0; shift ;;
    --skip-compressmcp) DO_COMPRESSMCP=0; shift ;;
    --no-index) DO_INDEX=0; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

PROJECT_DIR="$(resolve_project_dir "${PROJECT_DIR:-$PWD}")"

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
require_cmd node "install Node.js 18+ first"
require_cmd claude "install Claude Code first: https://claude.com/claude-code"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node 18+ required, found $(node -v)"
ok "node $(node -v), claude CLI present"

info "project: $PROJECT_DIR"
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  warn "not a git repository — .gitignore wiring will be skipped"
fi

if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  printf '\nInstall into %s? [y/N] ' "$PROJECT_DIR"
  read -r reply
  case "$reply" in [yY]*) ;; *) die "aborted" ;; esac
fi

# ---------------------------------------------------------------------------
step "Plugins (context-mode, code-graph-mcp)"
# ---------------------------------------------------------------------------
if [ "$DO_PLUGINS" -eq 0 ]; then
  info "skipped (--skip-plugins)"
else
  installed_plugins="$(claude plugin list 2>/dev/null || true)"
  marketplaces="$(claude plugin marketplace list 2>/dev/null || true)"

  add_marketplace() { # <repo> <name>
    if printf '%s' "$marketplaces" | grep -q "$2"; then
      ok "marketplace already registered: $2"
    else
      claude plugin marketplace add "$1" >/dev/null 2>&1 \
        && ok "marketplace added: $1" \
        || warn "could not add marketplace $1 — add it manually with /plugin"
    fi
  }
  install_plugin() { # <plugin@marketplace> <short-name>
    if printf '%s' "$installed_plugins" | grep -q "$2"; then
      ok "plugin already installed: $2"
    else
      claude plugin install "$1" >/dev/null 2>&1 \
        && ok "plugin installed: $1" \
        || warn "could not install $1 — install it manually with /plugin"
    fi
  }

  # mksglu/context-mode is canonical; mksglu/claude-context-mode is a redirect to it.
  add_marketplace "mksglu/context-mode" "context-mode"
  install_plugin "context-mode@context-mode" "context-mode"

  add_marketplace "sdsrss/code-graph-mcp" "code-graph-mcp"
  install_plugin "code-graph-mcp@code-graph-mcp" "code-graph-mcp"
fi

# ---------------------------------------------------------------------------
step "compressmcp (MCP response compression)"
# ---------------------------------------------------------------------------
if [ "$DO_COMPRESSMCP" -eq 0 ]; then
  info "skipped (--skip-compressmcp)"
else
  if ! resolve_node_cli compressmcp >/dev/null 2>&1; then
    npm install -g compressmcp >/dev/null 2>&1 \
      && ok "npm package installed" \
      || warn "npm install -g compressmcp failed"
  else
    ok "npm package already present"
  fi

  CMCP="$(resolve_node_cli compressmcp 2>/dev/null || true)"
  if [ -n "$CMCP" ]; then
    status="$("$CMCP" check 2>&1 || true)"
    if printf '%s' "$status" | grep -q 'PostToolUse hook (compress): *✓'; then
      # Deliberately NOT re-running `compressmcp install` here. Its installer
      # overwrites settings.json -> statusLine. If code-graph is also installed,
      # its composite status line has already adopted compressmcp's as
      # "_previous" (see ~/.claude/statusline-providers.json); re-running would
      # replace the composite and silently drop code-graph's segment.
      ok "hooks already wired (not re-running installer — it would clobber the composite status line)"
    else
      "$CMCP" install >/dev/null 2>&1 \
        && ok "hooks + MCP server registered" \
        || warn "compressmcp install failed — run it manually"
    fi
  fi

  # Worth knowing: compressmcp compresses MCP tool responses. With no MCP
  # servers configured it is pure overhead — hooks on every call, nothing to
  # compress. The two plugins above register servers, so this is normally fine.
  if ! grep -q '"mcpServers"' "$HOME/.claude/settings.json" 2>/dev/null; then
    warn "no MCP servers in ~/.claude/settings.json yet — compressmcp has nothing to compress until you add some"
  fi
fi

# ---------------------------------------------------------------------------
step "Project hooks (automatic reindexing)"
# ---------------------------------------------------------------------------
SETTINGS_PATH="$(node "$KIT_DIR/lib/settings.mjs" apply --project-dir "$PROJECT_DIR" --throttle "$THROTTLE")"
ok "wrote ${SETTINGS_PATH#"$PROJECT_DIR"/}"
info "env CODE_GRAPH_HOOK_INDEX=on   -> agent Write/Edit indexed immediately"
info "SessionStart hook              -> catches git pull / editor edits between sessions"
info "UserPromptSubmit hook (${THROTTLE}s)  -> catches edits outside the agent mid-session"

# .gitignore — settings.local.json holds absolute machine paths, never commit it.
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GI="$PROJECT_DIR/.gitignore"
  added=0
  for entry in ".claude/settings.local.json" ".code-graph/"; do
    if ! grep -qxF "$entry" "$GI" 2>/dev/null; then
      if [ "$added" -eq 0 ]; then
        printf '\n# ctx-kit (machine-specific paths + local index)\n' >> "$GI"
        added=1
      fi
      printf '%s\n' "$entry" >> "$GI"
      ok ".gitignore += $entry"
    else
      ok ".gitignore already has $entry"
    fi
  done
fi

# ---------------------------------------------------------------------------
step "Initial index"
# ---------------------------------------------------------------------------
if [ "$DO_INDEX" -eq 0 ]; then
  info "skipped (--no-index)"
else
  CG="$(resolve_node_cli code-graph-mcp 2>/dev/null || true)"
  if [ -z "$CG" ]; then
    warn "code-graph-mcp CLI not found yet — restart Claude Code once, then re-run this installer"
  else
    export PATH="$(dirname "$CG"):$PATH"
    info "indexing $PROJECT_DIR (first run walks the whole tree; later runs are incremental)"
    ( cd "$PROJECT_DIR" && "$CG" incremental-index --quiet ) >/dev/null 2>&1 || true
    health="$( cd "$PROJECT_DIR" && "$CG" health-check 2>&1 | head -1 || true )"
    ok "${health:-index built}"

    # Vector search needs an embedding model the binary is supposed to fetch
    # "lazily on first use". Observed reality: that download can simply never
    # fire — `doctor` keeps reporting "no download has ever been attempted"
    # while semantic_code_search silently degrades to keyword matching. Nudging
    # it with a query does not help, so do not pretend it does; point at the
    # script that installs the weights deterministically instead.
    if ( cd "$PROJECT_DIR" && "$CG" health-check 2>&1 | grep -qi 'vector inactive' ); then
      info "vector search inactive — run ./install-model.sh to install the embedding model (~80 MB)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "Verify"
# ---------------------------------------------------------------------------
"$KIT_DIR/verify.sh" --project-dir "$PROJECT_DIR" || true

cat <<EOF

${C_GRN}Done.${C_OFF} One manual step remains:

  ${C_BLU}Open /hooks once in Claude Code (or restart it).${C_OFF}

  Claude Code only watches directories that already had a settings file when the
  session started. A freshly created .claude/settings.local.json is not picked up
  until the config is reloaded — the hooks are correct, just not live yet.

Then re-run  ${C_DIM}./verify.sh${C_OFF}  to confirm the hooks actually fire.
EOF
