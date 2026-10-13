import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const kit=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const put=(p,s)=>{mkdirSync(dirname(p),{recursive:true});writeFileSync(p,s);};
const fixture=()=>{const root=mkdtempSync(join(tmpdir(),'ctx-kit-config-'));put(join(root,'.ctx-kit.json'),'{"codeGraphBinary":"bin/graph.exe"}');return root;};
const run=(root,mode='apply',target='Both')=>spawnSync(process.execPath,[join(kit,'lib/project-mcp.mjs'),mode,'--project-dir',root,'--target',target,'--node',process.execPath,'--context-cli',join(root,'context.mjs'),'--code-graph',join(root,'bin/graph.exe')],{encoding:'utf8'});
test('conflicting project graph definition is refused without modifying config',()=>{
  const root=fixture(),file=join(root,'.codex/config.toml');
  const text='[mcp_servers.code-graph-mcp]\ncommand = "user-owned"\n';put(file,text);
  const result=run(root);assert.notEqual(result.status,0);assert.match(result.stderr,/already defines/);
  assert.equal(readFileSync(file,'utf8'),text);assert(!existsSync(join(root,'.mcp.json')));
});
test('malformed Claude config does not partially write a Codex block',()=>{
  const root=fixture();put(join(root,'.mcp.json'),'{broken');
  assert.notEqual(run(root).status,0);assert(!existsSync(join(root,'.codex/config.toml')));
  assert.equal(readFileSync(join(root,'.mcp.json'),'utf8'),'{broken');
});
test('Codex-only setup leaves unrelated malformed Claude MCP untouched',()=>{
  const root=fixture();put(join(root,'.mcp.json'),'{broken');
  assert.equal(run(root,'apply','Codex').status,0);
  assert.equal(readFileSync(join(root,'.mcp.json'),'utf8'),'{broken');
  assert.equal(run(root,'remove','Codex').status,0);
  assert(!existsSync(join(root,'.codex/config.toml')));
});
test('Claude-only setup leaves unrelated malformed Codex markers untouched',()=>{
  const root=fixture(),file=join(root,'.codex/config.toml');put(file,'# BEGIN ctx-kit project MCP\n');
  assert.equal(run(root,'apply','Claude').status,0);
  assert.equal(readFileSync(file,'utf8'),'# BEGIN ctx-kit project MCP\n');
  assert.equal(run(root,'remove','Claude').status,0);
});
test('uninstall preserves a transport edited after installation',()=>{
  const root=fixture();assert.equal(run(root).status,0);
  const file=join(root,'.mcp.json');const mcp=JSON.parse(readFileSync(file));mcp.mcpServers['code-graph-mcp'].command='user-new-command';put(file,JSON.stringify(mcp));
  assert.equal(run(root,'remove').status,0);
  assert.equal(JSON.parse(readFileSync(file)).mcpServers['code-graph-mcp'].command,'user-new-command');
});
