// Run actual configured index hooks on an owned probe; never rewrite user source.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,existsSync,unlinkSync} from 'node:fs';
import {resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
import {spawnSync,spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
const args=process.argv.slice(2);
const option=(key,fallback)=>{const i=args.indexOf('--'+key);return i<0?fallback:args[i+1];};
const root=resolve(option('project-dir',process.cwd()));
const binary=resolve(option('binary','code-graph-mcp.exe'));
const target=option('target','Both');
assert(['Both','Claude','Codex'].includes(target),'Invalid target');
const language=option('language',existsSync(resolve(root,'project.godot'))?'gdscript':'typescript');
assert(['gdscript','typescript'].includes(language),'Unsupported probe language');
const id=randomUUID().replaceAll('-','');
const symbol='ctxKitProbe'+id;
const caller='ctxKitCaller'+id;
const relative=`__ctx_kit_probe_${id}.${language==='gdscript'?'gd':'ts'}`;
const file=resolve(root,relative);
const stamp=resolve(root,'.code-graph/.auto-index-stamp');
const savedStamp=existsSync(stamp)?readFileSync(stamp):null;
const source=language==='gdscript'?`extends Node\nfunc ${caller}() -> void:\n\t${symbol}()\nfunc ${symbol}() -> void:\n\tpass\n`:
  `export function ${symbol}(): number { return 1; }\nexport function ${caller}(): number { return ${symbol}(); }\n`;
const system=process.env.SystemRoot||'C:\\Windows';
const shell=resolve(system,'System32/WindowsPowerShell/v1.0/powershell.exe');
const bare={...process.env,PATH:`${system}\\System32;${system};${system}\\System32\\WindowsPowerShell\\v1.0`,CLAUDE_PROJECT_DIR:root};
// Windows env keys are case insensitive; avoid duplicate Path inherited from Node.
for(const key of Object.keys(bare)) if(key!=='PATH'&&key.toLowerCase()==='path') delete bare[key];
const run=(exe,argv,env=process.env)=>{
  const r=spawnSync(exe,argv,{cwd:root,env,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
  assert.equal(r.status,0,`${exe}: ${r.error||r.stderr||r.stdout}`);return r.stdout;
};
const search=()=>JSON.parse(run(binary,['search',symbol,'--language',language,'--json','--limit','10']))
  .filter(n=>n.name===symbol&&n.file_path===relative);
const hooks=[];
if(target!=='Codex') {
  const config=JSON.parse(readFileSync(resolve(root,'.claude/settings.local.json'),'utf8'));
  for(const event of ['SessionStart','UserPromptSubmit',...(config.env?.CODE_GRAPH_BIN?['PostToolUse']:[])]) {
    const hook=config.hooks?.[event]?.flatMap(g=>g.hooks).find(h=>h.description?.includes('[ctx-kit]'));
    assert(hook,`Missing Claude ${event} hook`);
    hooks.push({name:`Claude ${event}`,command:hook.command});
  }
}
if(target!=='Claude') {
  const config=JSON.parse(readFileSync(resolve(root,'.codex/hooks.json'),'utf8'));
  for(const action of ['index-sessionstart','index-prompt','index-write']) {
    const hook=Object.values(config.hooks).flatMap(groups=>groups.flatMap(g=>g.hooks))
      .find(h=>h.commandWindows?.endsWith(`-Action ${action}`));
    assert(hook,`Missing Codex ${action} hook`);
    hooks.push({name:`Codex ${action}`,command:hook.commandWindows});
  }
}
let owned=false;
try {
  for(const hook of hooks) {
    writeFileSync(file,source,{flag:'wx'});owned=true;
    if(existsSync(stamp)) unlinkSync(stamp);
    run(shell,['-NoProfile','-NonInteractive','-Command',hook.command],bare);
    assert.equal(search().length,1,`${hook.name}: ${language} symbol was not indexed`);
    assert(run(binary,['callgraph',caller,'--json']).includes(symbol),'Direct call missing');
    assert(readFileSync(file,'utf8')===source,'Probe modified externally; refusing to delete');
    unlinkSync(file);owned=false;
    if(existsSync(stamp)) unlinkSync(stamp);
    run(shell,['-NoProfile','-NonInteractive','-Command',hook.command],bare);
    assert.equal(search().length,0,`${hook.name}: deleted symbol retained`);
    console.log(`[OK] ${hook.name}: stripped PATH; ${language} symbol/callgraph addition and deletion`);
  }
  writeFileSync(file,source,{flag:'wx'});owned=true;
  run(binary,['incremental-index','--quiet']);
  const server=spawn(binary,['serve'],{cwd:root,env:process.env,stdio:['pipe','pipe','pipe']});
  const lines=createInterface({input:server.stdout});let next=0;const pending=new Map();let errors='';
  server.stderr.on('data',d=>errors=(errors+d).slice(-2000));
  lines.on('line',line=>{let v;try{v=JSON.parse(line);}catch{return;}const p=pending.get(v.id);if(p){pending.delete(v.id);clearTimeout(p.timer);v.error?p.reject(Error(JSON.stringify(v.error))):p.resolve(v.result);}});
  const rpc=(method,params)=>new Promise((res,rej)=>{const n=++next;const timer=setTimeout(()=>{pending.delete(n);rej(Error(method+': '+errors));},20000);pending.set(n,{resolve:res,reject:rej,timer});server.stdin.write(JSON.stringify({jsonrpc:'2.0',id:n,method,params})+'\n');});
  try {
    await rpc('initialize',{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'ctx-kit-verifier',version:'1'}});
    server.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
    for(const compact of [false,true]) {
      const r=await rpc('tools/call',{name:'get_ast_node',arguments:{file_path:relative,symbol_name:symbol,compact}});
      assert(!r.isError&&JSON.stringify(r).includes(symbol),JSON.stringify(r));
      if(!compact) assert(JSON.stringify(r).includes(language==='gdscript'?'void':'number'),JSON.stringify(r));
    }
    const r=await rpc('tools/call',{name:'semantic_code_search',arguments:{query:symbol,language,compact:true,top_k:3}});
    assert(!r.isError&&JSON.stringify(r).includes(symbol),JSON.stringify(r));
    console.log(`[OK] Actual stdio MCP: ${language} AST full/compact and search`);
  } finally {server.kill();lines.close();}
} finally {
  if(owned&&existsSync(file)&&readFileSync(file,'utf8')===source) unlinkSync(file);
  run(binary,['incremental-index','--quiet']);
  if(savedStamp) writeFileSync(stamp,savedStamp);else if(existsSync(stamp)) unlinkSync(stamp);
}
assert(run(binary,['health-check','--deep']).startsWith('OK:'));
console.log(`[OK] Deep index health; ${hooks.length} configured hooks tested; probe removed`);
