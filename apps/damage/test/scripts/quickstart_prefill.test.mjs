import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

function element(id) {
  return {id, value:'', textContent:'', disabled:false, href:'', listeners:{},
    classList:{add(){},remove(){},toggle(){}},
    addEventListener(key,fn){this.listeners[key]=fn;}};
}
const names=['target','connect-form','test-panel','result-panel','feature','run',
  'generate','status','trial-note','schedule','copy','download','share','result'];
const nodes=Object.fromEntries(names.map(id=>[id,element(id)]));
const requests=[];
let submitCount=0;
nodes['connect-form'].requestSubmit=function(){submitCount++;return this.listeners.submit({preventDefault(){}});};
const originalDocument=globalThis.document, originalWindow=globalThis.window, originalFetch=globalThis.fetch;
globalThis.document={getElementById(id){return nodes[id];}};
globalThis.window={location:{search:'?url=https%3A%2F%2Fapi.example.com%2Fhealth'}};
globalThis.fetch=async (url,opts)=>{
  requests.push({url,opts});
  if(url==='/api/quickstart/generate') return {ok:true,json:async()=>({url:'https://api.example.com/health',feature:'Feature: check',trial_available:false})};
  throw new Error('Unexpected live execution: '+url);
};
const source=await readFile(new URL('../../priv/static/js/quickstart.js',import.meta.url),'utf8');
await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));

test('dashboard URL handoff prefills /try, generates one draft and never auto-executes', async()=>{
  assert.equal(nodes.target.value,'https://api.example.com/health');
  assert.equal(submitCount,1);
  await new Promise(setImmediate);
  assert.deepEqual(requests.map(r=>r.url), ['/api/quickstart/generate']);
  assert.equal(JSON.parse(requests[0].opts.body).url,'https://api.example.com/health');
  assert.equal(nodes.run.disabled,true);
  assert.equal(nodes.feature.textContent,'Feature: check');
});

test('test cleanup',()=>{globalThis.document=originalDocument;globalThis.window=originalWindow;globalThis.fetch=originalFetch;});
