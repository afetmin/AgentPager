import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { registerHooks } from 'node:module';
import { test } from 'node:test';

const hooks=registerHooks({resolve(name,ctx,next){return name==='@hermes/plugin-sdk'
  ?{url:'data:text/javascript,export const host=globalThis.producerTraceHost',shortCircuit:true}:next(name,ctx);}});
globalThis.producerTraceHost={};
const {startStatusMonitor}=await import('./plugin.js');hooks.deregister();
function atom(value){const listeners=new Set();return{get:()=>value,listen(fn){listeners.add(fn);return()=>listeners.delete(fn);}};}
async function until(predicate){for(let i=0;i<2000;i++){if(predicate())return;await new Promise(r=>setTimeout(r,1));}assert.fail('Producer trace timed out');}

test('production exporter emits a parent-scoped child-work → completed trace for the real Bridge/phone integration',async t=>{
  t.mock.timers.enable({apis:['setInterval']});
  const packets=[],stops=[],events=new Map();
  const live=[{id:'runtime-parent',session_key:'stored-parent',title:'父会话',status:'idle'},
    {id:'runtime-other',session_key:'stored-other',title:'另一个会话',status:'idle'}];
  const work=[{session_id:'stored-parent',subagents:2,background:0,goal:'PRIVATE CHILD GOAL'}];
  const sdk={state:{gateway:atom('open'),busyBySession:atom({}),connectionId:atom('local'),profile:atom('default')},notify(){},
    onEvent(type,fn){events.set(type,fn);return()=>events.delete(type);},
    async request(method,params){
      if(method==='session.active_list')return{sessions:live};
      if(method==='session.list'){assert.equal(params.profile,'default');return{sessions:live.map(r=>({id:r.session_key,title:r.title}))};}
      if(method==='subagent.roster'){assert.equal(params.profile,'default');return{sessions:work};}
      if(method==='profiles.list')return{profiles:[{name:'default',display_name:'验收助手',path:'PRIVATE PATH'}]};
      return undefined;
    }};
  startStatusMonitor({files:{async writeText(_a,_n,data){packets.push(JSON.parse(data));return{ok:true};}},onDispose:fn=>stops.push(fn)},'',sdk);
  t.after(()=>stops.forEach(fn=>fn()));
  const parent=()=>packets.at(-1)?.sessions?.find(s=>s.title==='父会话');
  const phases=[];
  await until(()=>parent()?.activeSubagents===2);
  assert.equal(parent().state,'running');assert.equal(parent().agentName,'验收助手');
  phases.push(packets.at(-1));
  events.get('message.complete')({session_id:'runtime-parent',profile:'default',connectionId:'local',payload:{status:'complete',text:'PRIVATE BODY'}});
  await until(()=>packets.length>=3);
  assert.equal(parent().state,'running');assert.equal(parent().activeSubagents,2);
  phases.push(packets.at(-1));
  work.length=0;t.mock.timers.tick(5000);
  await until(()=>parent()?.state==='succeeded');
  assert.equal(parent().activeSubagents??0,0);phases.push(packets.at(-1));
  assert.ok(phases.every(p=>p.sessions.find(s=>s.title==='另一个会话')?.state==='idle'));
  assert.ok(!JSON.stringify(phases).includes('PRIVATE'));
  if(process.env.AGENTPAGER_HERMES_TRACE)writeFileSync(process.env.AGENTPAGER_HERMES_TRACE,JSON.stringify(phases),'utf8');
});
