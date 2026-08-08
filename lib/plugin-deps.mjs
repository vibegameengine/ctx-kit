#!/usr/bin/env node
//
// Find — and repair — the runtime dependencies context-mode ships without.
//
//   node lib/plugin-deps.mjs           # print each unresolvable package, one per line
//   node lib/plugin-deps.mjs --dir     # print the plugin directory that was inspected
//   node lib/plugin-deps.mjs --repair  # install the missing ones, print what landed
//
// Exit 0 means the inspection succeeded (an empty listing then means "nothing
// missing"). Exit 2 means the plugin directory could not be found, so nothing
// was inspected and an empty listing proves nothing — callers must tell those
// two apart, which is why the script does not just print and exit 0 regardless.
//
// WHY THIS EXISTS
//
// context-mode's bundler inlines most of its dependencies into server.bundle.mjs
// but leaves a few as real `require()` calls — turndown, at the time of writing,
// because it reaches its DOM implementation dynamically. The published plugin
// then ships a node_modules containing only better-sqlite3 and its tree, so the
// externalized ones resolve nowhere.
//
// The failure is invisible in exactly the way this kit exists to catch. The MCP
// server starts, every tool that does not touch that code path works, and
// `ctx_doctor` reports a full column of green — it checks runtimes, storage,
// hooks and FTS5, none of which touch turndown. Only `ctx_fetch_and_index`
// fails, at call time, with `Cannot find module 'turndown'`. So the entire web
// layer is dead while the diagnostic says the install is healthy.
//
// Detection is deliberately triple-gated: a package is reported only when it is
// (a) passed somewhere as a call's sole string argument, (b) declared in the
// plugin's own package.json dependencies, and (c) genuinely unresolvable from
// the bundle's directory. Gate (c) uses createRequire against server.bundle.mjs
// itself, which is not an approximation of how the server resolves the module —
// it is the same lookup, from the same file.
//
// Gate (a) looks odd until you read the bundle. Grepping for `require("x")` finds
// nothing: the file is minified, so the surviving calls read
// `RT(import.meta.url).resolve("turndown")` and `t("better-sqlite3")`, where RT
// and t are mangled aliases of createRequire and require. Any pattern anchored on
// the word `require` therefore reports a clean bill of health on a bundle that
// externalizes everything. What minification cannot rename is the specifier
// itself, and a module specifier is always its call's only argument — so `("x")`
// is the shape that survives. Matching every quoted string instead is too loose
// in the other direction: it catches package names that merely appear in log
// messages (measured: it reported the inlined `zod` and missed `turndown`).
//
// Repair does NOT run `npm install` inside the plugin directory: that tree was
// created by bun, and npm walks into its lockfile and dies with
// `Cannot read properties of null (reading 'edgesOut')`. Staging in a temp
// directory and copying the packages across sidesteps the lockfile entirely.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createRequire, builtinModules } from 'node:module'

const BUNDLE = 'server.bundle.mjs'
const BUILTINS = new Set(builtinModules)

// --- locate the plugin -----------------------------------------------------

// Versions live side by side under the marketplace cache; the newest directory
// is the one Claude Code loads. CTX_KIT_PLUGIN_DIR overrides it for tests.
function findPluginDir() {
  if (process.env.CTX_KIT_PLUGIN_DIR) {
    return fs.existsSync(process.env.CTX_KIT_PLUGIN_DIR) ? process.env.CTX_KIT_PLUGIN_DIR : null
  }
  const root = path.join(os.homedir(), '.claude', 'plugins', 'cache', 'context-mode', 'context-mode')
  let entries
  try {
    entries = fs.readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory())
  } catch {
    return null
  }
  const dirs = entries
    .map((e) => path.join(root, e.name))
    .map((p) => ({ p, mtime: fs.statSync(p).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
  return dirs.length ? dirs[0].p : null
}

// --- detection -------------------------------------------------------------

// A deep import (`turndown/lib/x`) still needs the package installed, so reduce
// every specifier to the package name a node_modules entry is named after.
function packageName(spec) {
  const parts = spec.split('/')
  return spec.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0]
}

function externalSpecifiers(bundlePath) {
  let src
  try {
    src = fs.readFileSync(bundlePath, 'utf8')
  } catch {
    return null // no bundle: caller falls back to every declared dependency
  }
  const found = new Set()
  // The backreference keeps the quote styles paired. A `["']` on both ends lets
  // a match open on a double quote and close on a single one, which misaligns
  // every subsequent match across a minified file.
  const re = /\(\s*(["'])([^"'\n]+)\1\s*\)/g
  let m
  while ((m = re.exec(src)) !== null) {
    const spec = m[2]
    if (spec.startsWith('.') || spec.startsWith('/') || spec.startsWith('node:')) continue
    const name = packageName(spec)
    if (BUILTINS.has(name)) continue
    found.add(name)
  }
  return found
}

function inspect(pluginDir) {
  let pkg = {}
  try {
    pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'))
  } catch {
    /* a plugin without a manifest declares nothing; the gate below empties out */
  }
  const declared = pkg.dependencies || {}
  const external = externalSpecifiers(path.join(pluginDir, BUNDLE))
  // Gate (a) — but if the bundle is unreadable, fall back to every declared
  // dependency rather than silently reporting "nothing missing".
  const candidates = Object.keys(declared).filter((name) => !external || external.has(name))

  // Gate (c): resolve exactly as the bundle does, from the bundle's own path.
  const req = createRequire(path.join(pluginDir, BUNDLE))
  const missing = []
  for (const name of candidates) {
    try {
      req.resolve(name)
    } catch {
      missing.push(name)
    }
  }
  return { missing, declared }
}

// --- repair ----------------------------------------------------------------

// Copy only what the destination lacks. Overwriting an existing package would
// mean shipping a second opinion about a version that already works.
function copyMissingPackages(stageModules, destModules) {
  const copied = []
  const copyOne = (rel) => {
    const dest = path.join(destModules, rel)
    if (fs.existsSync(dest)) return
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.cpSync(path.join(stageModules, rel), dest, { recursive: true })
    copied.push(rel)
  }
  for (const entry of fs.readdirSync(stageModules)) {
    if (entry.startsWith('.')) continue // .bin shims, .package-lock.json
    if (entry.startsWith('@')) {
      for (const inner of fs.readdirSync(path.join(stageModules, entry))) {
        copyOne(path.join(entry, inner))
      }
    } else {
      copyOne(entry)
    }
  }
  return copied
}

function repair(pluginDir, missing, declared) {
  if (!missing.length) return []
  // Install the ranges the plugin itself asks for, not whatever is newest.
  const specs = missing.map((name) => (declared[name] ? `${name}@${declared[name]}` : name))
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'ctx-kit-deps-'))
  try {
    fs.writeFileSync(
      path.join(stage, 'package.json'),
      JSON.stringify({ name: 'ctx-kit-dep-stage', version: '0.0.0', private: true }) + '\n',
    )
    // shell:true because npm on Windows is a .cmd, which Node >= 18.20 refuses
    // to spawn in exec form.
    execFileSync('npm', ['install', '--no-audit', '--no-fund', '--silent', ...specs], {
      cwd: stage,
      stdio: 'ignore',
      shell: true,
    })
    const destModules = path.join(pluginDir, 'node_modules')
    fs.mkdirSync(destModules, { recursive: true })
    return copyMissingPackages(path.join(stage, 'node_modules'), destModules)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
}

// --- cli -------------------------------------------------------------------

const pluginDir = findPluginDir()
if (!pluginDir) {
  process.exit(2)
}

if (process.argv.includes('--dir')) {
  process.stdout.write(pluginDir + '\n')
  process.exit(0)
}

const { missing, declared } = inspect(pluginDir)

if (process.argv.includes('--repair')) {
  let copied = []
  try {
    copied = repair(pluginDir, missing, declared)
  } catch (err) {
    process.stderr.write(String((err && err.message) || err) + '\n')
    process.exit(1)
  }
  for (const name of copied) process.stdout.write(name.replace(/\\/g, '/') + '\n')
  process.exit(0)
}

for (const name of missing) process.stdout.write(name + '\n')
process.exit(0)
