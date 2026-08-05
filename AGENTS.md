# Installing ctx-kit — a runbook for agents

You are being asked to install ctx-kit into someone's repository. Read this first.
It is not a summary of the README; it is the order of operations, the decisions you
have to make, and the failures you will otherwise report as successes.

**The one thing to understand before you touch anything:** every layer this kit wires
up fails *silently*. A hook that exits 127 prints nothing anywhere. An MCP server that
cannot spawn is not reported. `semantic_code_search` without its model still answers,
just with keyword matching. Nothing in the UI turns red. So a config file that contains
the right JSON is **not evidence that anything works** — and reading it back is the
mistake this runbook exists to prevent.

---

## 1. Decide the platform first

| Host | Scripts | Hook shell |
|---|---|---|
| macOS, Linux | `install.sh`, `verify.sh`, `uninstall.sh`, `install-model.sh` | `sh` |
| Windows | `install.ps1`, `verify.ps1`, `uninstall.ps1`, `install-model.ps1` | PowerShell, pinned |

On Windows, do **not** reach for `install.sh` just because Git Bash happens to be
installed on that machine. Claude Code runs a Windows hook through Git Bash only *when
Git for Windows is present*, and falls back to PowerShell when it is not — so a bash
hook is a hook that works on your box and is dead on the user's. `install.ps1` writes
hooks carrying `"shell": "powershell"`, which removes the question.

Both platforms generate their hooks from the same `lib/settings.mjs`. Do not hand-write
hook JSON; call the script.

## 2. Know what you are about to change

Tell the user this before you run anything. The kit is small and honest about its
footprint, and an agent that cannot say what it modified is not one you should trust
with `-Yes`.

| Path | Scope | What lands there |
|---|---|---|
| `<repo>/.claude/settings.local.json` | project | the two reindex hooks + `CODE_GRAPH_HOOK_INDEX=on` |
| `<repo>/.gitignore` | project | two lines: the settings file and `.code-graph/` |
| `<repo>/.code-graph/` | project | the index (SQLite; tens to hundreds of MB) |
| `~/.claude/settings.json` | **machine-wide** | plugin registration, compressmcp hooks + MCP server + status line |
| `~/.cache/code-graph/bin/` | **machine-wide** | the native `code-graph-mcp` binary (~44 MB) |
| `~/.cache/code-graph/models-manual/` | **machine-wide** | the embedding model, only if you run `install-model` (~80 MB) |

Three of those are outside the repo. If the user only agreed to "set this up in my
project", say that the last three are shared by every repo on the machine before you
proceed.

## 3. Run the installer

```bash
./install.sh --project-dir /path/to/repo          # add -y once the user has agreed
```
```powershell
.\install.ps1 -ProjectDir C:\path\to\repo         # add -Yes once the user has agreed
```

It is idempotent — every step checks its own state — so re-running after a fix is
normal and safe, not a sign something went wrong.

Useful flags when the situation calls for them: `--skip-plugins` / `-SkipPlugins` when
the plugins are managed elsewhere, `--skip-compressmcp` / `-SkipCompressMcp` when the
user has no MCP servers at all (it would be pure overhead), `--no-index` / `-NoIndex`
to defer the first full walk of a large tree.

## 4. The manual step you cannot do for the user

Claude Code only watches directories that already had a settings file when the session
started. A freshly created `.claude/settings.local.json` is **not live** until the
config reloads.

> Ask the user to open `/hooks` once, or restart Claude Code.

You cannot do this yourself, and no amount of re-running the installer substitutes for
it. Say it plainly and wait, rather than looping.

## 5. Prove it — this is the part that matters

```bash
./verify.sh --project-dir /path/to/repo
```
```powershell
.\verify.ps1 -ProjectDir C:\path\to\repo
```

Quote its output to the user. Not your summary of it — its output. The check that
carries the weight is the last one: `verify` pulls the hook command **out of the
settings file**, runs it in a deliberately hostile environment, writes a brand-new
symbol into the repo, and then asks the graph whether that symbol arrived. Then it
deletes the file and asks again, because an index that never forgets is also broken.

Everything before that check only proves the JSON says what you wrote.

If a check fails, fix the cause and re-run. Do not report a partial install as done, and
do not describe a `[WARN]` as if it were a `[FAIL]` or the reverse — the script already
distinguishes them.

## 6. Vector search is a separate, explicit decision

After install, `verify` will usually warn that semantic search is keyword-only. That is
accurate and it is not a bug: the embedding weights are supposed to download lazily on
first use, and in practice that download can simply never fire. The tool keeps answering
with FTS5/BM25 and the results still look plausible, which is exactly why this needs
saying out loud.

```bash
./install-model.sh --project-dir /path/to/repo
```
```powershell
.\install-model.ps1 -ProjectDir C:\path\to\repo
```

Two things to warn the user about before you start it: it downloads ~80 MB, and the
embedding pass walks every embeddable node in the repo, which on a large tree is minutes
to tens of minutes of CPU. `--no-embed` / `-NoEmbed` installs the weights and skips the
pass; the pass is resumable, so re-running finishes it.

Then tell them to **restart Claude Code**: until they do, the CLI has the model and the
running MCP server does not.

## 7. If the index looks absurdly large

The indexer walks the tree through the same ignore rules git uses. A repo carrying
vendored third-party sources, reference checkouts or sample projects will index all of
them, and they can easily outweigh the project's own code by an order of magnitude.

Check the file count in `verify`'s "Index health" line against your sense of how big the
project actually is. If it is wildly off, find the directory responsible and exclude it:

- `.gitignore` — if the user is happy for git to ignore it too, and it is committed.
- `.git/info/exclude` — local, uncommitted, invisible to other clones. The right choice
  when the directory must stay untracked but the user does not want a repo-wide rule.
- A `.ignore` file also works, but understand the cost first: ripgrep honours it too, so
  every future `rg` in that repo silently stops searching the directory. Usually the
  wrong trade.

Whichever you pick, **ask first** — you are changing what the user's own tools can see —
then `rebuild-index --confirm` and quote the before/after file counts.

## 8. Things that look right and are not

- **Do not re-run `compressmcp install` once it is wired.** Its installer overwrites
  `settings.json → statusLine`. If code-graph is also installed, its composite status
  line has already adopted compressmcp's as `_previous`; re-running replaces the
  composite and silently drops code-graph's segment. The installer detects this and
  skips — do not "helpfully" run it by hand.
- **`compressmcp check` lies about the status line** in exactly that situation. `verify`
  cross-checks `~/.claude/statusline-providers.json` before believing it.
- **Do not hand-fill the default model cache dir.** `<cache>/code-graph/models` is only
  trusted once the binary's own `extract_and_promote` has written a `.model-id` marker;
  a manually populated copy is ignored. That is why `install-model` uses a separate
  directory pointed at by `CODE_GRAPH_MODEL_DIR`.
- **Do not `npm install -g code-graph-mcp` to "fix" a missing CLI.** The plugin ships a
  native binary and downloads it into its own cache. `install.ps1` triggers that download
  directly; on POSIX, one restart of Claude Code does it. A parallel npm copy just gives
  you two versions to disagree with each other.
- **Do not conclude the tool is missing because it is not on `PATH`.** It is not on PATH
  by design, on any platform. Resolve it the way `lib/common.sh` / `lib/common.ps1` do.
- **Do not test a hook in your own interactive shell.** Your profile has already loaded
  the version manager, so the test passes for a reason that will not exist when the hook
  actually runs. That is the entire point of `verify`'s bare-environment probe.

## 9. Rollback

```bash
./uninstall.sh                  # this repo's hooks only — the safe default
./uninstall.sh --global         # also unwire compressmcp and the two plugins
./uninstall.sh --purge-index    # also delete .code-graph/ (asks first)
```
```powershell
.\uninstall.ps1 ; .\uninstall.ps1 -Global ; .\uninstall.ps1 -PurgeIndex
```

Nothing here deletes source files. The index is the only removable artifact and it is
never removed without an explicit flag. `--purge-index` non-interactively requires `-y`
— if there is nobody to ask, the script refuses rather than assuming consent, and you
should too.

## 10. What to report back

- Which layers are installed, with versions.
- The verify output, verbatim, including warnings.
- Every path you touched outside the repo.
- The manual step still outstanding (`/hooks` or a restart), stated as outstanding.

If something did not work, say which check failed and what its output was. A silent
layer reported as working is worse than an uninstalled one: the user will spend weeks
believing their context is being saved by something that has been doing nothing.
