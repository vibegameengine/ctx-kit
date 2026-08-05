#!/usr/bin/env node
/**
 * Point an MCP server registration in ~/.claude/settings.json at a JS entry
 * point run through `node`, instead of at an npm bin shim.
 *
 *   node mcp-entry.mjs --name compressmcp --entry C:\...\dist\index.js [--args --server]
 *
 * Prints `rewritten` or `unchanged`; exits non-zero if it could not.
 *
 * Why this exists (Windows only, but harmless anywhere):
 * Claude Code spawns MCP servers in EXEC form — `command` is resolved as an
 * executable and spawned directly, with no shell. On Windows an npm-global CLI
 * is not an executable in that sense:
 *
 *   spawn('compressmcp')      -> ENOENT   (extensionless sh shim; Windows cannot exec it)
 *   spawn('compressmcp.cmd')  -> EINVAL   (Node >= 18.20 refuses .cmd/.bat without a shell)
 *
 * So a registration written by a tool's own POSIX-shaped installer silently
 * never starts on Windows. `node <entry> --server` always works, on every
 * platform, which is why this rewrites rather than special-cases.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const argv = process.argv.slice(2);
const flag = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : def;
};
const name = flag('name');
const entry = flag('entry');
if (!name || !entry) {
  console.error('usage: mcp-entry.mjs --name NAME --entry PATH [--args ...]');
  process.exit(2);
}
const argsIdx = argv.indexOf('--args');
const serverArgs = argsIdx !== -1 ? argv.slice(argsIdx + 1) : ['--server'];

const settingsPath = flag('settings', join(homedir(), '.claude', 'settings.json'));

let settings = {};
if (existsSync(settingsPath)) {
  const raw = readFileSync(settingsPath, 'utf8').trim();
  if (raw) {
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(`refusing to modify malformed JSON: ${settingsPath}\n  ${e.message}`);
      process.exit(1);
    }
  }
}

if (!existsSync(entry)) {
  console.error(`entry point does not exist: ${entry}`);
  process.exit(1);
}

const desired = { command: 'node', args: [entry, ...serverArgs] };
const current = settings.mcpServers?.[name];

// Leave a registration that is already correct completely alone — including one
// the user hand-tuned to a different but equally valid node invocation.
if (current && current.command === 'node' && Array.isArray(current.args) && current.args[0] === entry) {
  console.log('unchanged');
  process.exit(0);
}
if (!current) {
  // Nothing registered: the tool's own installer owns creating it. Adding one
  // here would resurrect a server the user may have deliberately removed.
  console.log('unchanged');
  process.exit(0);
}

settings.mcpServers = { ...settings.mcpServers, [name]: { ...current, ...desired } };
mkdirSync(dirname(settingsPath), { recursive: true });
writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
console.log('rewritten');
