#!/usr/bin/env node
/**
 * Merge (or remove) ctx-kit hooks in a project's
 * .claude/settings.local.json — without clobbering anything already there.
 *
 * Usage:
 *   node settings.mjs apply  --project-dir DIR [--throttle SEC] [--shell bash|powershell]
 *   node settings.mjs remove --project-dir DIR
 *   node settings.mjs print  --project-dir DIR [--throttle SEC]   # dry run
 *
 * Why project-local and not ~/.claude/settings.json:
 * the indexer is per-repository. Global hooks would fire `incremental-index` in
 * every project you open, including ones that have no graph at all.
 *
 * This file is the single source of truth for the hook commands on BOTH
 * platforms — install.sh and install.ps1 call it rather than templating their
 * own, so the two can never drift.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

const MARKER = '[ctx-kit]';
const CLI = 'code-graph-mcp';

// ---------------------------------------------------------------------------
// POSIX (macOS / Linux) hook body.
//
// A hook shell has neither the version manager's bin dir on PATH nor `node`
// itself, and these CLIs are `#!/usr/bin/env node` shims. Resolving the binary
// is not enough — its directory must go on PATH or the shebang fails with a
// silent exit 127.
// ---------------------------------------------------------------------------
const shPrelude = [
  `CG=$(command -v ${CLI} 2>/dev/null)`,
  `[ -x "$CG" ] || CG=$(ls -t "$HOME"/.cache/code-graph/bin/${CLI} "$HOME"/.nvm/versions/node/*/bin/${CLI} "$HOME"/.volta/bin/${CLI} "$HOME"/.local/share/fnm/node-versions/*/installation/bin/${CLI} "$HOME"/.asdf/installs/nodejs/*/bin/${CLI} /opt/homebrew/bin/${CLI} /usr/local/bin/${CLI} 2>/dev/null | head -1)`,
  `[ -x "$CG" ] || exit 0`,
  `export PATH="$(dirname "$CG"):$PATH"`,
].join('; ');

const shPreamble = (projectDir) =>
  `D="\${CLAUDE_PROJECT_DIR:-${projectDir}}"; S="$D/.code-graph/.auto-index-stamp"; [ -d "$D/.code-graph" ] || exit 0`;

const shSessionStart = (projectDir) =>
  [
    shPrelude,
    shPreamble(projectDir),
    `printf '%s' "$(date +%s)" > "$S"`,
    `(cd "$D" && "$CG" incremental-index --quiet) >/dev/null 2>&1`,
    `exit 0`,
  ].join('; ');

const shUserPrompt = (projectDir, throttle) =>
  [
    shPrelude,
    shPreamble(projectDir),
    `N=$(date +%s)`,
    `L=$(cat "$S" 2>/dev/null || echo 0)`,
    `if [ $((N-L)) -ge ${throttle} ]; then printf '%s' "$N" > "$S"; (cd "$D" && "$CG" incremental-index --quiet) >/dev/null 2>&1; fi`,
    `exit 0`,
  ].join('; ');

// ---------------------------------------------------------------------------
// Windows hook body (PowerShell).
//
// Why not reuse the sh one: Claude Code does run Windows hooks through Git Bash
// *when Git Bash is installed*, and falls back to PowerShell when it is not —
// so a bash-only hook is silently dead on any machine without Git for Windows.
// Pinning `shell: "powershell"` makes the hook independent of that.
//
// The exit-127 trap the POSIX prelude exists to dodge does not exist here for a
// different reason: on Windows the CLI is a native `code-graph-mcp.exe` with no
// shebang, so once its path is known it needs neither `node` nor anything on
// PATH. The Windows failure mode is the opposite one — the exe is NOT on PATH at
// all, because the plugin downloads it into its own cache rather than installing
// an npm shim. Hence the explicit candidate list, cache file first.
// ---------------------------------------------------------------------------
const psCandidates = [
  `$env:CODE_GRAPH_BIN`,
  `"$env:USERPROFILE\\.cache\\code-graph\\bin\\${CLI}.exe"`,
  `"$env:LOCALAPPDATA\\code-graph\\bin\\${CLI}.exe"`,
  `"$env:APPDATA\\npm\\node_modules\\${CLI}\\bin\\${CLI}.exe"`,
  `"$env:APPDATA\\npm\\${CLI}.cmd"`,
].join(', ');

// `$c` may be $null/empty (unset env var) — Test-Path throws on those under
// StrictMode, so guard before testing.
const psResolve = [
  `$ErrorActionPreference='SilentlyContinue'`,
  `$CG=$null`,
  `$p="$env:USERPROFILE\\.cache\\code-graph\\binary-path"`,
  `if(Test-Path $p){$c=(Get-Content $p -Raw).Trim(); if($c -and (Test-Path $c)){$CG=$c}}`,
  `if(-not $CG){foreach($c in @(${psCandidates})){if($c -and (Test-Path $c)){$CG=$c; break}}}`,
  `if(-not $CG){$CG=(Get-Command ${CLI} -ErrorAction SilentlyContinue).Source}`,
  `if(-not $CG){exit 0}`,
].join('; ');

const psPreamble = (projectDir) =>
  [
    `$D=if($env:CLAUDE_PROJECT_DIR){$env:CLAUDE_PROJECT_DIR}else{'${projectDir.replace(/'/g, "''")}'}`,
    `$G=Join-Path $D '.code-graph'`,
    `if(-not (Test-Path $G)){exit 0}`,
    `$S=Join-Path $G '.auto-index-stamp'`,
  ].join('; ');

const psSessionStart = (projectDir) =>
  [
    psResolve,
    psPreamble(projectDir),
    `Set-Content -Path $S -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -NoNewline -Encoding ascii`,
    `Push-Location $D; & $CG incremental-index --quiet *> $null; Pop-Location`,
    `exit 0`,
  ].join('; ');

const psUserPrompt = (projectDir, throttle) =>
  [
    psResolve,
    psPreamble(projectDir),
    `$N=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`,
    `$L=0`,
    `if(Test-Path $S){[void][int64]::TryParse((Get-Content $S -Raw).Trim(),[ref]$L)}`,
    `if(($N-$L) -ge ${throttle}){Set-Content -Path $S -Value $N -NoNewline -Encoding ascii; Push-Location $D; & $CG incremental-index --quiet *> $null; Pop-Location}`,
    `exit 0`,
  ].join('; ');

// ---------------------------------------------------------------------------
function buildHooks(projectDir, throttle, shell) {
  const ps = shell === 'powershell';
  // Backslashes are escape characters in a bash string; the sh hooks must get a
  // forward-slash path even when the caller passed a native Windows one.
  const dir = ps ? projectDir : projectDir.replace(/\\/g, '/');
  const extra = ps ? { shell: 'powershell' } : {};
  return {
    SessionStart: {
      type: 'command',
      description: `${MARKER} code-graph: reindex everything changed since the last session`,
      command: ps ? psSessionStart(dir) : shSessionStart(dir),
      ...extra,
      async: true,
      timeout: 120,
    },
    UserPromptSubmit: {
      type: 'command',
      description: `${MARKER} code-graph: throttled (>=${throttle}s) reindex for edits made outside the agent`,
      command: ps ? psUserPrompt(dir, throttle) : shUserPrompt(dir, throttle),
      ...extra,
      async: true,
      timeout: 120,
    },
  };
}

// --- arg parsing ------------------------------------------------------------
const argv = process.argv.slice(2);
const mode = argv[0];
if (!['apply', 'remove', 'print'].includes(mode)) {
  console.error('usage: settings.mjs <apply|remove|print> --project-dir DIR [--throttle SEC] [--shell bash|powershell]');
  process.exit(2);
}
const flag = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : def;
};
const projectDir = flag('project-dir', process.cwd());
const throttle = parseInt(flag('throttle', '120'), 10);
if (!Number.isFinite(throttle) || throttle < 0) {
  console.error(`invalid --throttle: ${flag('throttle', '120')}`);
  process.exit(2);
}
const shell = flag('shell', process.platform === 'win32' ? 'powershell' : 'bash');
if (!['bash', 'powershell'].includes(shell)) {
  console.error(`invalid --shell: ${shell} (expected bash or powershell)`);
  process.exit(2);
}

const settingsPath = join(projectDir, '.claude', 'settings.local.json');

if (mode === 'print') {
  const h = buildHooks(projectDir, throttle, shell);
  console.log(JSON.stringify(h, null, 2));
  process.exit(0);
}

// --- read existing ----------------------------------------------------------
let settings = {};
if (existsSync(settingsPath)) {
  const raw = readFileSync(settingsPath, 'utf8').trim();
  if (raw) {
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      // Refuse to touch a file we cannot parse — overwriting it would silently
      // disable every setting the user already had in there.
      console.error(`refusing to modify malformed JSON: ${settingsPath}\n  ${e.message}`);
      process.exit(1);
    }
  }
}

// Strip any hooks this kit installed previously, so apply/remove are idempotent
// and re-running never stacks duplicates.
//
// Also strips equivalent hooks that were wired BY HAND before the kit existed:
// they carry no marker, so matching on description alone would leave them in
// place and every reindex would then run twice per event.
//
// Matching is deliberately shell-agnostic: switching a project between the bash
// and PowerShell flavours must REPLACE the hook, not stack a second one that
// reindexes the same repo on the same event.
const isOurs = (h) => {
  if (String(h.description || '').includes(MARKER)) return true;
  const cmd = String(h.command || '');
  return cmd.includes('incremental-index') && cmd.includes(CLI);
};

let adopted = 0;
const stripKitHooks = (event) => {
  const groups = settings.hooks?.[event];
  if (!Array.isArray(groups)) return;
  const kept = groups
    .map((g) => {
      const hooks = (g.hooks || []).filter((h) => {
        if (!isOurs(h)) return true;
        if (!String(h.description || '').includes(MARKER)) adopted++;
        return false;
      });
      return { ...g, hooks };
    })
    .filter((g) => (g.hooks || []).length > 0);
  if (kept.length) settings.hooks[event] = kept;
  else delete settings.hooks[event];
};

for (const ev of ['SessionStart', 'UserPromptSubmit']) stripKitHooks(ev);
if (adopted > 0) {
  console.error(`note: replaced ${adopted} hand-wired reindex hook(s) with the kit's managed version`);
}
if (settings.hooks && Object.keys(settings.hooks).length === 0) delete settings.hooks;

if (mode === 'remove') {
  if (settings.env) {
    delete settings.env.CODE_GRAPH_HOOK_INDEX;
    if (Object.keys(settings.env).length === 0) delete settings.env;
  }
} else {
  // env: flips the code-graph plugin's own PostToolUse Write|Edit hook back on.
  // That hook ships default-off since v0.21 (the plugin relies on query-time
  // freshness instead), so agent edits are otherwise not indexed on write.
  settings.env = { ...(settings.env || {}), CODE_GRAPH_HOOK_INDEX: 'on' };

  const h = buildHooks(projectDir, throttle, shell);
  settings.hooks = settings.hooks || {};
  for (const ev of ['SessionStart', 'UserPromptSubmit']) {
    settings.hooks[ev] = settings.hooks[ev] || [];
    settings.hooks[ev].push({ hooks: [h[ev]] });
  }
}

mkdirSync(dirname(settingsPath), { recursive: true });
writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
console.log(settingsPath);
