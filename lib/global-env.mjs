#!/usr/bin/env node
/**
 * Set (or unset) one key under `env` in ~/.claude/settings.json — merged, never
 * clobbered.
 *
 *   node global-env.mjs set   CODE_GRAPH_MODEL_DIR /path/to/models
 *   node global-env.mjs unset CODE_GRAPH_MODEL_DIR
 *
 * Prints `written` or `unchanged`.
 *
 * Machine-wide on purpose, unlike the hooks: the embedding model is a
 * machine-wide artifact and the MCP server inherits its environment from Claude
 * Code, not from the project.
 *
 * Shared by install-model.sh and install-model.ps1 so the two cannot drift.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const [mode, key, value] = process.argv.slice(2);
if (!['set', 'unset'].includes(mode) || !key || (mode === 'set' && !value)) {
  console.error('usage: global-env.mjs <set KEY VALUE|unset KEY>');
  process.exit(2);
}

const file = process.env.CTX_KIT_GLOBAL_SETTINGS || join(homedir(), '.claude', 'settings.json');

let settings = {};
if (existsSync(file)) {
  const raw = readFileSync(file, 'utf8').trim();
  if (raw) {
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(`refusing to modify malformed JSON: ${file}\n  ${e.message}`);
      process.exit(1);
    }
  }
}

if (mode === 'unset') {
  if (!settings.env || !(key in settings.env)) {
    console.log('unchanged');
    process.exit(0);
  }
  delete settings.env[key];
  if (Object.keys(settings.env).length === 0) delete settings.env;
} else {
  if (settings.env && settings.env[key] === value) {
    console.log('unchanged');
    process.exit(0);
  }
  settings.env = { ...(settings.env || {}), [key]: value };
}

mkdirSync(dirname(file), { recursive: true });
writeFileSync(file, JSON.stringify(settings, null, 2) + '\n');
console.log('written');
