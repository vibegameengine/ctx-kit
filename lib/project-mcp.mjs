// Manage only ctx-kit's project transports, preserving unrelated MCP/config data.
import {readFileSync,writeFileSync,existsSync,mkdirSync,unlinkSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
const argv=process.argv.slice(2),mode=argv[0];
const opt=(k,d='')=>{const i=argv.indexOf('--'+k);return i<0?d:argv[i+1];};
if(!['apply','remove'].includes(mode)) throw Error('Expected apply or remove');
const root=resolve(opt('project-dir',process.cwd()));
const target=opt('target','Both');
const begin='# BEGIN ctx-kit project MCP',end='# END ctx-kit project MCP';
const configPath=join(root,'.codex/config.toml'),mcpPath=join(root,'.mcp.json');
const statePath=join(root,'.ctx-kit/mcp-state.json');
const state=existsSync(statePath)?JSON.parse(readFileSync(statePath,'utf8')):{};
const write=(p,t)=>{mkdirSync(dirname(p),{recursive:true});writeFileSync(p,t);};
const strip=t=>{
  const a=t.indexOf(begin),b=t.indexOf(end);
  if(a<0&&b<0) return t;
  if(a<0||b<a) throw Error('Malformed ctx-kit MCP markers; refusing to edit');
  return t.slice(0,a)+t.slice(b+end.length).replace(/^\r?\n/,'');
};
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
if(mode==='apply') {
  const node=opt('node'),cli=opt('context-cli'),binary=opt('code-graph');
  if(!node||!cli||!binary) throw Error('Missing transport executable paths');
  const text=target!=='Claude'&&existsSync(configPath)?readFileSync(configPath,'utf8'):'';
  const clean=strip(text);
  if(target!=='Claude' && /^\s*\[mcp_servers\.(?:code-graph-mcp|context-mode)(?:\]|\.)/m.test(clean))
    throw Error('Project already defines code-graph-mcp/context-mode outside ctx-kit; preserve it and resolve explicitly');
  const local=existsSync(join(root,'.ctx-kit.json'))&&JSON.parse(readFileSync(join(root,'.ctx-kit.json'),'utf8')).codeGraphBinary;
  const mcp=target!=='Codex'&&existsSync(mcpPath)?JSON.parse(readFileSync(mcpPath,'utf8')):{};
  const server={command:binary,args:['serve']};
  if(target!=='Codex'&&local&&mcp.mcpServers?.['code-graph-mcp']&&!same(mcp.mcpServers['code-graph-mcp'],state.claudeServer||server))
    throw Error('Project already defines another Claude code-graph-mcp transport; refusing to overwrite');
  if(target!=='Claude') {
    const q=JSON.stringify;
    const block=`${begin}\n[mcp_servers.code-graph-mcp]\ncommand = ${q(binary)}\nargs = ["serve"]\ncwd = ${q(root)}\n\n[mcp_servers.context-mode]\ncommand = ${q(node)}\nargs = [${q(cli)}]\ncwd = ${q(root)}\n${end}\n`;
    state.codex=true;
    write(configPath,clean+(clean&&!clean.endsWith('\n')?'\n':'')+block);
  }
  if(target!=='Codex'&&local) {
    if(!mcp.mcpServers?.['code-graph-mcp']||state.claudeServer) {
      state.claudeServer=server;
      mcp.mcpServers={...(mcp.mcpServers||{}),'code-graph-mcp':server};
      write(mcpPath,JSON.stringify(mcp,null,2)+'\n');
    }
  }
  write(statePath,JSON.stringify(state,null,2)+'\n');
} else {
  if(target!=='Claude'&&state.codex&&existsSync(configPath)) {
    const text=strip(readFileSync(configPath,'utf8'));
    if(text.trim()) write(configPath,text);else unlinkSync(configPath);
    delete state.codex;
  }
  if(target!=='Codex'&&state.claudeServer&&existsSync(mcpPath)) {
    const mcp=JSON.parse(readFileSync(mcpPath,'utf8'));
    if(same(mcp.mcpServers?.['code-graph-mcp'],state.claudeServer)) {
      delete mcp.mcpServers['code-graph-mcp'];
      if(!Object.keys(mcp.mcpServers).length) delete mcp.mcpServers;
      if(Object.keys(mcp).length) write(mcpPath,JSON.stringify(mcp,null,2)+'\n');else unlinkSync(mcpPath);
    }
    delete state.claudeServer;
  }
  if(Object.keys(state).length) write(statePath,JSON.stringify(state,null,2)+'\n');
  else if(existsSync(statePath)) unlinkSync(statePath);
}
console.log(`Project MCP ${mode}: ${root}`);
