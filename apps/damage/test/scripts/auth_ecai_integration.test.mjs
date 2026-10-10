// node --experimental-vm-modules --test <this-file>
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const root=new URL('../../priv/static/js/',import.meta.url);
const modelCode=await readFile(new URL('auth-model.js',root),'utf8');
const tokenCode=await readFile(new URL('wallet-switcher.js',root),'utf8');
const model=await import('data:text/javascript;base64,'+Buffer.from(modelCode).toString('base64'));
const address='ak_11111111111111111111111111111111273Yts';
const sample=(key='a',mode='custodial')=>({authenticated:true,mode,address,access_token:'ds1.'+key.repeat(64),
  expires_at:Math.floor(Date.now()/1000)+3600,capabilities:{execute:mode==='custodial'}});

test('ECAI mobile address and sign links return to the dashboard fragment',()=>{
  for(const phase of ['connect','sign']){
    const url=new URL(model.walletDeepLink(phase,'https://ecai.example','a'.repeat(64),'review this','/dashboard'));
    const callback=new URL(url.searchParams.get('x-success'));
    assert.equal(callback.pathname,'/dashboard');assert.equal(callback.origin,'https://ecai.example');
    assert.ok(callback.hash.startsWith('#wallet-callback?'));assert.equal(callback.search,'');
    assert.equal(url.searchParams.has('encoding'),false);
  }
});
test('DamageBDD mobile callback default stays at root',()=>{
  const u=new URL(model.walletDeepLink('connect','https://damage.example','b'.repeat(64)));
  assert.equal(new URL(u.searchParams.get('x-success')).pathname,'/');
});
test('callback target cannot be a supplied remote URL or arbitrary path',()=>{
  for(const path of ['https://evil.example','//evil.example','/../','/dashboard?next=evil','/unknown'])
    assert.throws(()=>model.walletDeepLink('connect','https://ecai.example','c'.repeat(64),undefined,path));
});

async function tokenFixture(){
  const pending=[];const events=[];
  const context=vm.createContext({window:{},URL,Date,console,
    setTimeout:()=>1,clearTimeout:()=>{},localStorage:{removeItem(){}},
    CustomEvent:class{constructor(type,{detail}={}){this.type=type;this.detail=detail;}},
    document:{readyState:'loading',body:{dataset:{}},querySelectorAll:()=>[],addEventListener(){},dispatchEvent:e=>events.push(e)},
    fetch:()=>new Promise((resolve,reject)=>pending.push({resolve,reject}))});
  const m=new vm.SourceTextModule(modelCode,{context});
  const t=new vm.SourceTextModule(tokenCode,{context});
  await t.link(()=>m);await t.evaluate();
  return {manager:context.window.TokenManager,pending,events};
}
const ok=data=>({status:200,ok:true,json:async()=>data});
test('a delayed restore cannot resurrect a locally expired or logged-out session',async()=>{
  const {manager:m,pending}=await tokenFixture();
  m.logout();pending[0].resolve(ok(sample()));await m.ready;
  assert.equal(m.isAuthenticated(),false);assert.equal(m.getToken(),'');
});
test('a delayed 401 cannot clear a newly accepted sign-in',async()=>{
  const {manager:m,pending}=await tokenFixture();
  m.acceptSession(sample('b'));pending[0].resolve({status:401});await m.ready;
  assert.equal(m.getToken(),sample('b').access_token);
});
test('a delayed network error cannot clear a newly accepted sign-in',async()=>{
  const {manager:m,pending}=await tokenFixture();
  m.acceptSession(sample('c'));pending[0].reject(new Error('offline'));await m.ready;
  assert.equal(m.getToken(),sample('c').access_token);
});
test('a delayed successful restore cannot overwrite a newer identity/session',async()=>{
  const {manager:m,pending}=await tokenFixture();
  m.acceptSession(sample('d','wallet'));pending[0].resolve(ok(sample('a')));await m.ready;
  assert.equal(m.session().mode,'wallet');assert.equal(m.getToken(),sample('d').access_token);
});
test('logout during JSON decoding also invalidates the old restore result',async()=>{
  const {manager:m,pending}=await tokenFixture();let bodyResolve;
  pending[0].resolve({status:200,ok:true,json:()=>new Promise(r=>bodyResolve=r)});
  await new Promise(r=>setImmediate(r));m.logout();bodyResolve(sample());await m.ready;
  assert.equal(m.getToken(),'');
});
test('malformed replacement sessions cannot replace a valid current identity',async()=>{
  const {manager:m,pending}=await tokenFixture();pending[0].resolve({status:401});await m.ready;
  m.acceptSession(sample('e'));
  assert.throws(()=>m.acceptSession({...sample(),access_token:'legacy-token'}));
  assert.equal(m.getToken(),sample('e').access_token);
});
test('auth change events never contain the session bearer',async()=>{
  const {manager:m,pending,events}=await tokenFixture();pending[0].resolve({status:401});await m.ready;
  m.acceptSession(sample('f'));assert.ok(events.some(e=>e.detail?.authenticated));
  assert.ok(!JSON.stringify(events).includes(sample('f').access_token));
});
