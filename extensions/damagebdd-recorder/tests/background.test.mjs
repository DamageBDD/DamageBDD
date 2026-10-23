import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {webcrypto} from 'node:crypto';

const code = await readFile(new URL('../background.js', import.meta.url), 'utf8');
function harness() {
  let onMessage, onUpdated, onRemoved, stored = {};
  const scripts = [];
  const browser = {
    storage: {local: {
      get: async key => ({[key]: stored[key]}),
      set: async data => {stored = {...stored,...data};}
    }},
    runtime: {onMessage: {addListener: fn => onMessage = fn}},
    tabs: {
      sendMessage: async (_id, message) => message.type === 'RECORDER_FLUSH' ? {event: {kind:'fill', selector:'#pending', value:'last unsaved value'}} : {ok:true},
      onUpdated: {addListener: fn => onUpdated = fn},
      onRemoved: {addListener: fn => onRemoved = fn}
    },
    scripting: {executeScript: async args => {scripts.push(args);}}
  };
  runInNewContext(code, {chrome:browser, URL, crypto:webcrypto, Date, Math, console});
  const send = (data, tabId) => new Promise(resolve => onMessage(data, tabId === undefined ? {} : {tab:{id:tabId}}, resolve));
  return {send, scripts, update: (id, change, tab) => onUpdated(id,change,tab), remove: id => onRemoved(id)};
}

test('records actions only from the intended tab and strips auth query parameters', async () => {
  const h = harness();
  const started = await h.send({type:'START',tabId:7,url:'https://shop.test/form?token=VERYSECRET&lang=en',title:'Checkout'});
  assert.equal(started.ok,true);
  const sessionId = started.state.id;
  assert.equal(h.scripts.length,1);
  assert.equal(started.state.actions[0].url,'https://shop.test/form?lang=en');
  const denied = await h.send({type:'RECORDER_EVENT',sessionId,event:{kind:'click', selector:'#buy'}},9);
  assert.equal(denied.ok,false);
  const saved = await h.send({type:'RECORDER_EVENT',sessionId,event:{kind:'click',selector:'#buy'}},7);
  assert.equal(saved.state.actions.length,2);
  const badSelector = await h.send({type:'RECORDER_EVENT',sessionId,event:{kind:'click',selector:'[id="private"]'}},7);
  assert.equal(badSelector.state.actions.length,2);
  const paused = await h.send({type:'PAUSE'});
  assert.equal(paused.state.status,'paused');
  assert.equal(paused.state.actions.at(-1).value,'last unsaved value');
  const ignored = await h.send({type:'RECORDER_EVENT',sessionId,event:{kind:'click',selector:'#later'}},7);
  assert.equal(ignored.ok,false);
});

test('tracks same-tab navigation, deduplicates input events and preserves saved steps', async () => {
  const h=harness();
  const {state:started}=await h.send({type:'START',tabId:12,url:'https://shop.test/',title:'Flow'});
  const sendEvent = event => h.send({type:'RECORDER_EVENT',sessionId:started.id,event},12);
  await sendEvent({kind:'fill',selector:'#search',value:'abc'});
  await sendEvent({kind:'fill',selector:'#search',value:'abcd'});
  assert.equal((await h.send({type:'GET_STATE'})).state.actions.length,2);
  await sendEvent({kind:'click',selector:'#checkout'});
  h.update(12,{url:'https://shop.test/cart?state=sensitive&lang=fr'},{});
  // Update handler is queued; GET_STATE runs after it.
  const state=(await h.send({type:'GET_STATE'})).state;
  assert.equal(state.actions.at(-1).kind,'navigation');
  assert.equal(state.actions.at(-1).cause,'click');
  assert.equal(state.actions.at(-1).url,'https://shop.test/cart?lang=fr');
  const res=await h.send({type:'UPDATE',title:'My test',actions:state.actions.map(a=>({id:a.id,enabled:a.id!==state.actions[1].id}))});
  assert.equal(res.state.title,'My test');
  assert.equal(res.state.actions[1].enabled,false);
});
