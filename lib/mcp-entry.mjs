#!/usr/bin/env node
/**
 * Print the absolute JS entry point of an npm-global CLI.
 *
 *   node mcp-entry.mjs --name compressmcp
 *   -> /usr/local/lib/node_modules/compressmcp/dist/index.js
 *
 * Exits 1 if the package or its entry cannot be found.
 *
 * Why an MCP server must be registered as `node <entry>` and not as its own bin
 * name: Claude Code spawns MCP servers in EXEC form — `command` is resolved as
 * an executable and spawned directly, with no shell. On Windows an npm-global
 * CLI is not an executable in that sense:
 *
 *   spawn('compressmcp')      -> ENOENT   (extensionless sh shim; Windows cannot exec it)
 *   spawn('compressmcp.cmd')  -> EINVAL   (Node >= 18.20 refuses .cmd/.bat without a shell)
 *
 * So a registration written by a tool's POSIX-shaped installer silently never
 * starts on Windows. `node <entry> --server` works on every platform, which is
 * why the installers resolve the entry here and register that.
 *
 * (This file used to rewrite the entry inside ~/.claude/settings.json. That was
 * wrong for a bigger reason than the shim: Claude Code does not read mcpServers
 * from settings.json at all — MCP config lives in ~/.claude.json or a project
 * .mcp.json. Registration now goes through `claude mcp add`, which writes the
 * file Claude Code actually loads.)
 */

import { existsSync, readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : null;
};
const name = flag('name');
if (!name) {
  console.error('usage: mcp-entry.mjs --name PACKAGE');
  process.exit(2);
}

// npm's global node_modules, in the order most likely to be right and cheapest
// to test. `npm root -g` is authoritative but costs 50-200 ms of process spawn,
// so it is the last resort rather than the first move.
function globalNodeModulesCandidates() {
  const out = [];
  const prefix = process.env.NPM_CONFIG_PREFIX || process.env.npm_config_prefix;
  const nodeBin = dirname(process.execPath);
  if (prefix) out.push(process.platform === 'win32' ? join(prefix, 'node_modules') : join(prefix, 'lib', 'node_modules'));
  if (process.platform === 'win32') {
    if (process.env.APPDATA) out.push(join(process.env.APPDATA, 'npm', 'node_modules'));
    out.push(join(nodeBin, 'node_modules'));
  } else {
    out.push(resolve(nodeBin, '..', 'lib', 'node_modules'));
    out.push('/usr/local/lib/node_modules');
    out.push('/opt/homebrew/lib/node_modules');
  }
  out.push(join(homedir(), '.npm-global', 'lib', 'node_modules'));
  return [...new Set(out)];
}

function entryFor(pkgDir) {
  const pkgJson = join(pkgDir, 'package.json');
  if (!existsSync(pkgJson)) return null;
  let pkg;
  try {
    pkg = JSON.parse(readFileSync(pkgJson, 'utf8'));
  } catch {
    return null;
  }
  let rel = null;
  if (typeof pkg.bin === 'string') rel = pkg.bin;
  else if (pkg.bin && typeof pkg.bin === 'object') rel = pkg.bin[name] || Object.values(pkg.bin)[0];
  if (!rel) rel = pkg.main;
  if (!rel) return null;
  const entry = join(pkgDir, rel);
  return existsSync(entry) ? entry : null;
}

for (const root of globalNodeModulesCandidates()) {
  const entry = entryFor(join(root, name));
  if (entry) {
    process.stdout.write(entry);
    process.exit(0);
  }
}

try {
  const root = execFileSync('npm', ['root', '-g'], {
    encoding: 'utf8',
    timeout: 5000,
    shell: process.platform === 'win32', // npm is a .cmd shim here; exec form cannot spawn it
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
  const entry = root && entryFor(join(root, name));
  if (entry) {
    process.stdout.write(entry);
    process.exit(0);
  }
} catch {
  /* npm not on PATH or timed out */
}

console.error(`could not locate the JS entry point of the global package: ${name}`);
process.exit(1);
