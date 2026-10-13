// Real Windows install/verify/uninstall against fresh, independently initialized repos.
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,copyFileSync,existsSync,readdirSync} from 'node:fs';
import {tmpdir,homedir} from 'node:os';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const argv=process.argv.slice(2);
const opt=k=>{const i=argv.indexOf('--'+k);return i<0?null:argv[i+1];};
assert(process.platform==='win32','This integration suite validates Windows hooks');
assert(opt('binary'),'Pass --binary pointing to a built GDScript-capable code graph');
const kit=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const suite=mkdtempSync(join(tmpdir(),'ctx-kit-clean-'));
const env={...process.env,...(opt('model-dir')?{CODE_GRAPH_MODEL_DIR:opt('model-dir')}:{})};
const run=(exe,args,cwd=kit)=>{
  const r=spawnSync(exe,args,{cwd,env,encoding:'utf8',timeout:240000,maxBuffer:12*1024*1024});
  assert.equal(r.status,0,`${exe} ${args.join(' ')}\n${r.error||r.stdout+'\n'+r.stderr}`);
  return r.stdout;
};
const ps=(file,args)=>run('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(kit,file),...args]);
const put=(p,text)=>{mkdirSync(dirname(p),{recursive:true});writeFileSync(p,text);};
const userFiles=['.codex/config.toml','.claude/settings.json','.claude.json'].map(p=>join(homedir(),p));
const before=new Map(userFiles.map(p=>[p,existsSync(p)?readFileSync(p):null]));
for(const language of ['gdscript','typescript']) {
  const root=join(suite,language);mkdirSync(root);
  run('git',['init','-q'],root);
  mkdirSync(join(root,'bin'));copyFileSync(resolve(opt('binary')),join(root,'bin/graph.exe'));
  put(join(root,'.gitignore'),'bin/\n');
  put(join(root,'.ctx-kit.json'),JSON.stringify({codeGraphBinary:'bin/graph.exe'}));
  const originalClaude={env:{KEEP_ME:'yes',CODE_GRAPH_BIN:'user-original-binary'},enabledPlugins:{'code-graph-mcp@code-graph-mcp':true,'other-plugin':true},hooks:{Stop:[{hooks:[{type:'command',command:'echo unrelated'}]}]}};
  const originalCodex={hooks:{Stop:[{hooks:[{type:'command',command:'echo unrelated',commandWindows:'Write-Output unrelated'}]}]}};
  const originalMcp={mcpServers:{'fixture-other':{command:'node',args:['--version']}}};
  const originalToml='[mcp_servers.fixture-other]\ncommand = "node"\nargs = ["--version"]\n';
  put(join(root,'.claude/settings.local.json'),JSON.stringify(originalClaude));
  put(join(root,'.codex/hooks.json'),JSON.stringify(originalCodex));
  put(join(root,'.codex/config.toml'),originalToml);
  put(join(root,'.mcp.json'),JSON.stringify(originalMcp));
  if(language==='gdscript') {
    put(join(root,'project.godot'),'config_version=5\n[application]\nrun/main_scene="res://source/start.tscn"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n');
    put(join(root,'source/domain/counter.gd'),'extends Node\nfunc _ready() -> void:\n\tprint("FRESH_GODOT_BOOT")\n\tget_tree().quit()\nfunc compute_score() -> int:\n\treturn 7\n');
    put(join(root,'source/start.tscn'),'[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://source/domain/counter.gd" id="1"]\n[node name="Root" type="Node"]\nscript = ExtResource("1")\n');
  } else put(join(root,'src/counter.ts'),'export function computeScore(): number { return 7; }\n');
  const args=['-ProjectDir',root,'-Target','Both','-SkipPlugins','-SkipCompressMcp','-Yes'];
  const first=ps('install.ps1',args);put(join(suite,language+'-install.log'),first);
  assert(/All checks passed/.test(first),first);
  assert(first.includes(`${language} symbol/callgraph addition and deletion`),first);
  assert(first.includes(`Actual stdio MCP: ${language}`),first);
  const selected=JSON.parse(readFileSync(join(root,'.mcp.json'),'utf8'));
  assert.equal(selected.mcpServers['code-graph-mcp'].command,join(root,'bin/graph.exe'));
  const second=ps('install.ps1',args);put(join(suite,language+'-reinstall.log'),second);
  assert(/All checks passed/.test(second),second);
  const hooks=JSON.parse(readFileSync(join(root,'.codex/hooks.json'),'utf8')).hooks;
  const handlers=Object.values(hooks).flatMap(g=>g.flatMap(x=>x.hooks));
  assert.equal(handlers.filter(h=>h.commandWindows?.includes('ctx-kit-codex')).length,9);
  assert.equal(handlers.filter(h=>h.commandWindows==='Write-Output unrelated').length,1);
  assert(!readdirSync(root).some(n=>n.startsWith('__ctx_kit_probe_')),'Verifier left a probe file');
  const settings=JSON.parse(readFileSync(join(root,'.claude/settings.local.json'),'utf8'));
  assert.equal(settings.enabledPlugins['code-graph-mcp@code-graph-mcp'],false);
  assert.equal(settings.env.CODE_GRAPH_BIN,join(root,'bin/graph.exe'));
  if(language==='gdscript'&&opt('godot')) {
    const quote=s=>"'"+s.replaceAll("'","''")+"'";
    const cmd=`& ${quote(opt('godot'))} --headless --path ${quote(root)} --import --quit`;
    run('powershell.exe',['-NoProfile','-Command',cmd],root);
    const boot=run('powershell.exe',['-NoProfile','-Command',`& ${quote(opt('godot'))} --headless --path ${quote(root)} --quit-after 3`],root);
    assert(boot.includes('FRESH_GODOT_BOOT'),boot);
    put(join(suite,'godot-boot.log'),boot);
  }
  const removed=ps('uninstall.ps1',['-ProjectDir',root,'-Target','Both','-Yes']);
  put(join(suite,language+'-uninstall.log'),removed);
  assert.deepEqual(JSON.parse(readFileSync(join(root,'.claude/settings.local.json'),'utf8')),originalClaude);
  assert.deepEqual(JSON.parse(readFileSync(join(root,'.codex/hooks.json'),'utf8')),originalCodex);
  assert.deepEqual(JSON.parse(readFileSync(join(root,'.mcp.json'),'utf8')),originalMcp);
  assert.equal(readFileSync(join(root,'.codex/config.toml'),'utf8'),originalToml);
  console.log(`[OK] Fresh ${language} repo: initial index, actual hooks/MCP, idempotent reinstall, non-destructive uninstall`);
}
for(const [p,bytes] of before) assert.deepEqual(existsSync(p)?readFileSync(p):null,bytes,`User-wide configuration changed: ${p}`);
console.log('[OK] User-wide Claude/Codex configurations stayed byte-identical');
console.log(`Evidence retained: ${suite}`);
