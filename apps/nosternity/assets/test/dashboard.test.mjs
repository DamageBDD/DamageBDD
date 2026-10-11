import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {webcrypto} from 'node:crypto';
import {JSDOM} from 'jsdom';
import {finalizeEvent, getPublicKey, verifyEvent} from 'nostr-tools/pure';

const templates=new URL('../../priv/templates/ui/dashboard/',import.meta.url);
const part=async name=>readFile(new URL(name+'.mustache',templates),'utf8');
const fragments=Object.fromEntries(await Promise.all(['page','sidebar','header','hero','feed','footer','auth','analytics','wallet','signer'].map(async name=>[name,await part(name)])));
const html=fragments.page.replace(/\{\{\{(\w+)\}\}\}/g,(_,name)=>fragments[name]);
const bundle=await readFile(new URL('../../priv/static/dashboard/dashboard.js',import.meta.url),'utf8');
const secret=new Uint8Array(32);secret[31]=9;
const pub=getPublicKey(secret), origin='https://nostr.example';
const preferences={spam:true,duplicates:true,muted:[],words:[],bookmarks:[]};
const note=finalizeEvent({kind:1,content:'<img src=x onerror=alert(1)> A signed note',created_at:Math.floor(Date.now()/1000),tags:[]},secret);
async function until(fn){for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,5));}assert.fail('UI condition timed out');}
async function fixture(branding={}){
 const dom=new JSDOM(html,{url:origin+'/dashboard',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window, calls=[];let session=null, saved={...preferences}, signatures=0;
 Object.assign(w.document.body.dataset,{nodeName:'Nosternity',nodeTitle:'Nosternity Search',nodeDescription:'The open network',...branding});
 w.document.title=w.document.body.dataset.nodeTitle;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 Object.defineProperty(w,'crypto',{value:webcrypto});w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;w.AbortSignal=AbortSignal;
 w.nostr={getPublicKey:async()=>pub,signEvent:async event=>{signatures++;return w.JSON.parse(JSON.stringify(finalizeEvent(JSON.parse(JSON.stringify(event)),secret)));}};
 const metrics={relay:{events:1,index:1,subscriptions:0,hydrated:true,max_events:10000},dashboard:{requests:1,searches:0,hidden:0,duration_ms:1,since:Math.floor(Date.now()/1000)}};
 const response=(body,status=200)=>({ok:status<400,status,json:async()=>w.JSON.parse(JSON.stringify(body)),text:async()=>body});
 w.fetch=async(path,options={})=>{
  calls.push({path,options});const body=options.body?JSON.parse(options.body):{};
  if(path.startsWith('/dashboard/fragments/'))return response(fragments[path.split('/').pop()]);
  assert.equal(options.credentials,'same-origin');assert.equal(options.headers['X-Nosternity-Auth'],'1');
  if(path==='/api/nosternity/auth/options')return response({origin,primary:'nostr'});
  if(path==='/accounts/session')return response({error:'unauthorized'},401);
  if(path==='/api/nosternity/auth/session')return session?response(session):response({error:'unauthorized'},401);
  if(path==='/api/nosternity/account')return response({preferences:saved});
  if(path==='/api/nosternity/preferences'){saved=body;return response({preferences:saved});}
  if(path==='/api/nosternity/analytics')return response(metrics);
  if(path==='/api/nosternity/feed')return response({results:[{event:note}],hidden:0,total:1});
  if(path==='/accounts/signup')return response({message:'Confirmation sent'});
  if(path==='/accounts/recovery')return response({message:'Recovery email sent'});
  if(path==='/api/nosternity/auth/nostr/challenge')return response({payload:JSON.stringify({challenge_id:'a'.repeat(64),intent:body.intent}),event:{kind:27235,created_at:Math.floor(Date.now()/1000),content:'',tags:[['u',origin+'/api/nosternity/auth/nostr/verify'],['method','POST']]}});
  if(path==='/api/nosternity/auth/nostr/verify'){
   const event=JSON.parse(Buffer.from(options.headers.Authorization.slice(6),'base64').toString());assert.ok(verifyEvent(event));assert.equal(event.pubkey,pub);
   session={authenticated:true,provider:'nostr',subject:pub};return response(session);
  }
  if(path==='/api/nosternity/events'){assert.ok(verifyEvent(body));assert.equal(body.pubkey,pub);return response({accepted:true,id:body.id},202);}
  if(path==='/api/nosternity/auth/logout'){session=null;return response({authenticated:false});}
  if(path==='/accounts/session/logout')return response({status:'ok'});
  throw Error('Unexpected request '+path);
 };
 w.eval(bundle);await until(()=>w.document.querySelector('#snapshot')?.textContent.includes('Stored events'));
 const q=s=>w.document.querySelector(s);
 const click=s=>{assert.ok(q(s),'Missing '+s);q(s).click();};
 const submit=s=>q(s).dispatchEvent(new w.Event('submit',{bubbles:true,cancelable:true}));
 return {w,dom,calls,q,click,submit,signatures:()=>signatures};
}

test('guest feed escapes event content; every workspace view renders',async()=>{
 const f=await fixture();try{
  assert.match(f.q('#posts').textContent,/<img/);assert.equal(f.q('#posts img'),null);
  assert.match(f.q('#mode').textContent,/Guest/);
  for(const [page,selector] of [['analytics','#metrics'],['wallet','#walletStatus'],['signer','#identity'],['settings','[data-action="signout"]'],['explore','#posts']]){
   f.click('nav [data-page="'+page+'"]');await until(()=>f.q(selector));
  }
  assert.equal(f.w.localStorage.length,0);
 }finally{f.dom.window.close();}
});

test('Nostr signup needs explicit signing; publishing and preferences use server APIs',async()=>{
 const f=await fixture();try{
  f.click('.headeractions [data-action="login"]');f.q('#authIntent').value='signup';f.click('#modal [data-action="nostrLogin"]');
  await until(()=>f.q('[data-action="signProof"]'));assert.equal(f.signatures(),0);
  const c=f.calls.find(c=>c.path.endsWith('/nostr/challenge'));assert.equal(JSON.parse(c.options.body).intent,'signup');
  f.click('[data-action="signProof"]');await until(()=>f.q('#mode').textContent.includes('Nostr connected')&&!f.q('#modal').open);
  assert.equal(f.signatures(),1);assert.equal(f.w.localStorage.length,0);
  f.click('[data-action="compose"]');await until(()=>f.q('#composeForm'));f.q('#note').value='Hello, open world';f.submit('#composeForm');
  await until(()=>f.calls.some(c=>c.path.endsWith('/events'))&&!f.q('#modal').open);
  f.click('[data-action="bookmark"]');await until(()=>f.q('#savedCount').textContent==='1');
  assert.ok(f.calls.some(c=>c.path.endsWith('/preferences')));
  f.click('nav [data-page="settings"]');await until(()=>f.q('[data-action="signout"]'));f.click('[data-action="signout"]');
  await until(()=>f.q('#mode').textContent.includes('Guest'));assert.ok(f.calls.some(c=>c.path==='/accounts/session/logout'));
 }finally{f.dom.window.close();}
});

test('DamageBDD signup and recovery require email without a hidden password',async()=>{
 const f=await fixture();try{
  f.click('.headeractions [data-action="login"]');f.click('#modal [data-action="damageLogin"]');
  f.q('#damageMode').value='signup';f.q('#damageMode').dispatchEvent(new f.w.Event('change',{bubbles:true}));
  assert.equal(f.q('#password').required,false);assert.equal(f.q('#passwordRow').hidden,true);
  f.q('#email').value='person@example.test';f.submit('#damageForm');await until(()=>f.q('#modalBody').textContent.includes('Confirmation sent'));
  const call=f.calls.find(c=>c.path==='/accounts/signup');assert.deepEqual(JSON.parse(call.options.body),{email:'person@example.test'});
  f.click('#modal [data-action="damageLogin"]');f.q('#damageMode').value='recovery';f.q('#damageMode').dispatchEvent(new f.w.Event('change',{bubbles:true}));
  f.q('#email').value='person@example.test';f.submit('#damageForm');await until(()=>f.q('#modalBody').textContent.includes('Recovery email sent'));
  assert.ok(f.calls.some(c=>c.path==='/accounts/recovery'));
 }finally{f.dom.window.close();}
});


test('configured branding survives navigation without becoming markup',async()=>{
 const branding={nodeName:'Sydney <img src=x onerror=alert(1)>',nodeTitle:'Search <script>alert(1)</script>',nodeDescription:'Local <b>conversations</b> & discovery'};
 const f=await fixture(branding);try{
  assert.equal(f.q('#title').textContent,branding.nodeTitle);
  assert.equal(f.q('#title script'),null);
  assert.equal(f.q('#subtitle').textContent,branding.nodeDescription);
  assert.equal(f.w.document.title,branding.nodeTitle);
  f.click('nav [data-page="saved"]');await until(()=>f.q('#subtitle').textContent.includes(branding.nodeName));
  assert.equal(f.q('#subtitle img'),null);
  f.click('nav [data-page="settings"]');await until(()=>f.q('[data-action="signout"]'));
  assert.equal(f.q('#content h2').textContent,'Your '+branding.nodeName+' account');
  assert.equal(f.q('#content h2 img'),null);
  f.click('nav [data-page="explore"]');await until(()=>f.q('#posts'));
  assert.equal(f.q('#title').textContent,branding.nodeTitle);
  assert.equal(f.q('#subtitle').textContent,branding.nodeDescription);
 }finally{f.dom.window.close();}
});
