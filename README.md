# ctx-kit

Drop-in setup for the three context-saving layers in Claude Code, plus the automatic
reindexing wiring that none of them ship with.

```bash
git clone https://github.com/vibegameengine/ctx-kit
./ctx-kit/install.sh --project-dir /path/to/your/repo
```

Or from inside the repo you want to configure:

```bash
./install.sh          # configure the current git repo
./verify.sh           # prove every layer actually works
./uninstall.sh        # roll back
```

The kit itself can live anywhere. All it puts in the target repo is
`.claude/settings.local.json` plus two `.gitignore` lines.

## What it sets up

| Layer | What it does |
|---|---|
| **context-mode** (plugin) | Runs commands in a sandbox and indexes big outputs into SQLite FTS5, so logs, snapshots and API payloads never enter the context window. |
| **code-graph-mcp** (plugin) | Tree-sitter AST graph of the repo in SQLite. Answers "who calls X / what breaks if I change X" by reading the blast radius instead of the tree. |
| **compressmcp** (npm) | Losslessly compresses MCP tool responses via key abbreviation before they hit the context. |
| **project hooks** (this kit) | Keeps the graph fresh automatically — the part you otherwise wire by hand. |

## The reindexing problem this kit solves

`code-graph-mcp` does **not** keep its index current on its own. Its `PostToolUse Write|Edit`
hook ships **default-off** since v0.21 — the plugin relies on query-time freshness
(`ensure_file_indexed`) inside MCP tools that take a `file_path`, so a brand-new file nobody
asked about by path never shows up in search.

The kit closes all three gaps:

| Source of change | Covered by |
|---|---|
| Agent `Write` / `Edit` | `env CODE_GRAPH_HOOK_INDEX=on` → re-enables the plugin's own hook |
| Your edits in the editor, `git pull`, asset generators, branch switches | `SessionStart` hook |
| Edits outside the agent, mid-session | `UserPromptSubmit` hook, throttled (default 120s) |

Both hooks are `async: true`, so nothing blocks the prompt.

## The gotcha this kit exists to encode

Hook commands run in a shell that does **not** have your Node version manager's bin
directory on `PATH`. Every npm-global CLI here (`code-graph-mcp`, `compressmcp`) is a
`#!/usr/bin/env node` shim, so an absolute path is **not enough** either — the shebang
cannot find `node` and the hook dies with `exit 127`.

A hook that exits 127 fails **invisibly**. Nothing in the UI reports it. The graph just
quietly stops updating.

Every generated hook therefore resolves the binary across the common version-manager
layouts *and* puts its directory on `PATH`:

```sh
CG=$(command -v code-graph-mcp 2>/dev/null)
[ -x "$CG" ] || CG=$(ls -t "$HOME"/.nvm/versions/node/*/bin/code-graph-mcp ... | head -1)
[ -x "$CG" ] || exit 0
export PATH="$(dirname "$CG"):$PATH"
```

`verify.sh` tests this the only way that proves anything: it pulls the command **out of
the settings file** and runs it under `env -i`. Testing in a normal shell passes
misleadingly, because your interactive profile has already loaded nvm.

## Other lessons baked in

- **Project-local, not global.** Hooks go in `.claude/settings.local.json`, not
  `~/.claude/settings.json` — global hooks would fire `incremental-index` in every repo you
  open, including ones with no graph.
- **`exit 0` always.** A non-zero `UserPromptSubmit` hook blocks the prompt.
- **Never re-run `compressmcp install` once it is wired.** Its installer overwrites
  `settings.json → statusLine`. If code-graph is also installed, its composite status line
  has already adopted compressmcp's as `_previous`; re-running replaces the composite and
  silently drops code-graph's segment. `install.sh` detects this and skips.
- **`compressmcp check` lies about the status line** in exactly that situation. `verify.sh`
  cross-checks `~/.claude/statusline-providers.json` before reporting it.
- **Merge, never clobber.** `lib/settings.mjs` refuses to touch malformed JSON — overwriting
  it would silently disable every setting already in the file — and strips its own previous
  hooks before re-adding, so re-running never stacks duplicates.
- **`.gitignore` matters.** `settings.local.json` holds absolute machine paths and
  `.code-graph/` is a multi-megabyte local DB. Both get added.
- **The embedding model is lazy.** It downloads in the background on the first real vector
  query, not at install. Until it lands, `semantic_code_search` is FTS5/BM25 only.
  `install.sh` nudges the download; `verify.sh` reports the state as a warning, not a failure.

## After installing

Claude Code only watches directories that already had a settings file when the session
started. A freshly created `.claude/settings.local.json` is not picked up until the config
reloads:

> **Open `/hooks` once, or restart Claude Code.**

Then `./verify.sh` should report the hooks firing.

## Options

```
./install.sh --project-dir DIR    # default: git root of $PWD
             --throttle SEC       # min gap between mid-session reindexes (default 120)
             --skip-plugins       # if the plugins are managed elsewhere
             --skip-compressmcp   # pointless if you have no MCP servers
             --no-index           # skip the initial graph build
             -y                   # no prompts

./verify.sh  --no-probe           # skip the write/index/delete round trip

./uninstall.sh --global           # also unwire compressmcp + plugins
               --purge-index      # also delete .code-graph/ (confirms first)
```

## Layout

```
install.sh          orchestrates, idempotent, self-verifying
verify.sh           evidence-based checks; exits non-zero on failure
uninstall.sh        rollback; never deletes without an explicit flag
lib/common.sh       CLI resolution, bare-env runner, logging
lib/settings.mjs    merges/removes hooks in .claude/settings.local.json
```

## Requirements

Node 18+, the `claude` CLI, git. macOS and Linux.
