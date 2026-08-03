#!/usr/bin/env bash
#
# ctx-kit — rollback.
#
#   ./uninstall.sh                  # remove this repo's hooks only (safe default)
#   ./uninstall.sh --global         # also unwire compressmcp and the two plugins
#   ./uninstall.sh --purge-index    # also delete .code-graph/ (asks first)
#
# Nothing here deletes source files. The index is the only removable artifact and
# it is never removed without an explicit flag plus a confirmation.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$KIT_DIR/lib/common.sh"

PROJECT_DIR=""
DO_GLOBAL=0
DO_PURGE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:?}"; shift 2 ;;
    --global) DO_GLOBAL=1; shift ;;
    --purge-index) DO_PURGE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) echo "usage: ./uninstall.sh [--project-dir DIR] [--global] [--purge-index] [-y]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
PROJECT_DIR="$(resolve_project_dir "${PROJECT_DIR:-$PWD}")"

step "Project hooks"
if [ -f "$PROJECT_DIR/.claude/settings.local.json" ]; then
  # Must not abort the whole rollback: settings.mjs exits non-zero on malformed
  # JSON (it refuses to clobber it), and that must not stop --global/--purge-index
  # from running.
  if node "$KIT_DIR/lib/settings.mjs" remove --project-dir "$PROJECT_DIR" >/dev/null 2>&1; then
    ok "kit hooks and CODE_GRAPH_HOOK_INDEX removed (other settings left intact)"
  else
    warn "could not edit .claude/settings.local.json (malformed?) — remove the [ctx-kit] hooks by hand"
  fi
else
  info "no .claude/settings.local.json — nothing to do"
fi

if [ "$DO_GLOBAL" -eq 1 ]; then
  step "Global tooling"
  if CMCP="$(resolve_node_cli compressmcp 2>/dev/null)"; then
    "$CMCP" uninstall >/dev/null 2>&1 && ok "compressmcp hooks removed" || warn "compressmcp uninstall failed"
  fi
  for p in context-mode code-graph-mcp; do
    claude plugin uninstall "$p" >/dev/null 2>&1 && ok "plugin removed: $p" || warn "could not remove plugin $p"
  done
  info "the npm package itself is left in place: npm uninstall -g compressmcp"
fi

if [ "$DO_PURGE" -eq 1 ]; then
  step "Index"
  IDX="$PROJECT_DIR/.code-graph"
  if [ -d "$IDX" ]; then
    sz="$(du -sh "$IDX" 2>/dev/null | cut -f1)"
    if [ "$ASSUME_YES" -eq 1 ]; then
      : # explicit consent already given on the command line
    elif [ -t 0 ]; then
      printf '  Delete %s (%s)? This is not reversible. [y/N] ' "$IDX" "$sz"
      read -r reply
      case "$reply" in [yY]*) ;; *) info "kept"; IDX="" ;; esac
    else
      # No tty and no -y: there is nobody to ask, so deleting would be deleting
      # without consent. Refuse rather than assume.
      warn "refusing to delete $IDX non-interactively — pass -y if you mean it"
      IDX=""
    fi
    if [ -n "$IDX" ]; then
      rm -rf "$IDX" && ok "removed $IDX ($sz)"
    fi
  else
    info "no .code-graph/ directory"
  fi
fi

printf '\n%sDone.%s Restart Claude Code (or open /hooks) to reload the config.\n' "$C_GRN" "$C_OFF"
