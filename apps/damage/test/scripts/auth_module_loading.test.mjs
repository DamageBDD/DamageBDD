// Run: node --experimental-vm-modules --test <this-file>
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root = new URL('../../priv/static/js/', import.meta.url);
const source = name => readFile(new URL(name, root), 'utf8');
const loaderCode = await source('auth-wallet-loader.js');
const {createAuthWalletLoader} = await import('data:text/javascript;base64,' + Buffer.from(loaderCode).toString('base64'));
const walletCode = await source('wallet.js');
const legacyWallet = walletCode.split('// Authentication adapter:')[0];

async function graph(entry, overrides = {}, context = vm.createContext({})) {
  assert.equal(typeof vm.SourceTextModule, 'function', 'Run with --experimental-vm-modules');
  const modules = new Map();
  async function create(url) {
    if (modules.has(url.href)) return modules.get(url.href);
    const name = url.pathname.split('/').pop();
    const code = Object.hasOwn(overrides, name) ? overrides[name] : await readFile(url, 'utf8');
    const module = new vm.SourceTextModule(code, {context, identifier: url.href});
    modules.set(url.href, module);
    return module;
  }
  const module = await create(new URL(entry, root));
  await module.link((specifier, parent) => create(new URL(specifier, parent.identifier)));
  return {module, modules, context};
}

test('delivered wallet exports satisfy the original named imports with the real Sidekick source', async () => {
  await graph('consumer.js', {'consumer.js': "import {connectBrowserForAuth, signBrowserForAuth} from './wallet.js';"});
});
test('reproduces the reported link error with a legacy wallet module', async () => {
  await assert.rejects(graph('consumer.js', {'wallet.js':legacyWallet,
    'consumer.js': "import {connectBrowserForAuth, signBrowserForAuth} from './wallet.js';"}), /does not provide an export named 'connectBrowserForAuth'/);
});
test('auth UI links without loading wallet.js at startup', async () => {
  const {modules} = await graph('auth-ui.js', {'wallet.js':legacyWallet});
  assert.ok(![...modules.keys()].some(url => new URL(url).pathname.endsWith('/wallet.js')));
});
test('versioned wallet URL tracks the delivered wallet bytes', () => {
  const revision = createHash('sha256').update(walletCode).digest('hex').slice(0,16);
  assert.ok(loaderCode.includes(`./wallet.js?v=${revision}`));
});
test('new HTML requests the updated auth entrypoint', async () => {
  const shell = await readFile(new URL('../../priv/templates/ui/dashboard/page_shell.mustache', import.meta.url), 'utf8');
  assert.match(shell, /src="\/static\/js\/auth-ui\.js\?v=wallet-loader-v1"/);
});
test('loader is lazy and reuses one successful import for connect and sign', async () => {
  let loads=0, connects=0, signs=0;
  const adapter=createAuthWalletLoader(async()=>{ loads++; return {
    connectBrowserForAuth:()=>{ connects++;return {address:'ak_test'}; },
    signBrowserForAuth:(message,address)=>{ signs++;return {message,address}; }
  };});
  assert.equal(loads,0);
  assert.deepEqual(await adapter.connect(),{address:'ak_test'});
  assert.deepEqual(await adapter.sign('exact challenge','ak_test'),{message:'exact challenge',address:'ak_test'});
  assert.deepEqual([loads,connects,signs],[1,1,1]);
});
test('missing auth exports fail closed without calling a legacy connection API', async () => {
  let legacyCalls=0;
  const adapter=createAuthWalletLoader(async()=>({connectWalletSmart(){legacyCalls++;}}));
  await assert.rejects(adapter.connect(),{code:'WALLET_MODULE_MISMATCH'});
  await assert.rejects(adapter.sign('challenge','ak_test'),{code:'WALLET_MODULE_MISMATCH'});
  assert.equal(legacyCalls,0);
});
test('one missing signature export also prevents connection', async () => {
  let calls=0;
  const adapter=createAuthWalletLoader(async()=>({connectBrowserForAuth(){calls++;}}));
  await assert.rejects(adapter.connect(),{code:'WALLET_MODULE_MISMATCH'});
  assert.equal(calls,0);
});
test('network or module errors become safe UI messages', async () => {
  const adapter=createAuthWalletLoader(async()=>{throw Error('internal-request-secret');});
  await assert.rejects(adapter.connect(),error=>{
    assert.equal(error.code,'WALLET_MODULE_UNAVAILABLE');
    assert.match(error.message,/email sign-in/);
    assert.ok(!error.message.includes('internal-request-secret'));
    return true;
  });
});
test('failed imports can be retried at the same URL', async () => {
  let loads=0;
  const adapter=createAuthWalletLoader(async()=>{
    if (++loads===1) throw new TypeError('temporary network failure');
    return {connectBrowserForAuth:()=> 'connected',signBrowserForAuth:()=> 'signed'};
  });
  await assert.rejects(adapter.connect(),{code:'WALLET_MODULE_UNAVAILABLE'});
  assert.equal(await adapter.connect(),'connected');
  assert.equal(loads,2);
});
test('simultaneous actions share the import promise', async () => {
  let loads=0, release;
  const adapter=createAuthWalletLoader(()=>{loads++;return new Promise(resolve=>{release=resolve;});});
  const a=adapter.connect(),b=adapter.sign('message','ak_test');
  await Promise.resolve();
  assert.equal(loads,1);
  release({connectBrowserForAuth:()=>1,signBrowserForAuth:()=>2});
  assert.deepEqual(await Promise.all([a,b]),[1,2]);
});
test('cancelled actions do not start loading', async () => {
  let loads=0;
  const adapter=createAuthWalletLoader(()=>{loads++;});
  const controller=new AbortController();controller.abort();
  await assert.rejects(adapter.connect({signal:controller.signal}),{name:'AbortError'});
  await assert.rejects(adapter.sign('message','ak_test',{signal:controller.signal}),{name:'AbortError'});
  assert.equal(loads,0);
});
test('cancellation while loading cannot open a delayed wallet prompt', async () => {
  let calls=0,release;
  const adapter=createAuthWalletLoader(()=>new Promise(resolve=>{release=resolve;}));
  const controller=new AbortController();
  const result=adapter.connect({signal:controller.signal});
  await Promise.resolve(); controller.abort();
  release({connectBrowserForAuth:()=>{calls++;},signBrowserForAuth:()=>{calls++;}});
  await assert.rejects(result,{name:'AbortError'});
  assert.equal(calls,0);
});
test('production session bootstrap handles 401 as signed out without accepting a session', async () => {
  let requests=0,jsonReads=0,authEvents=0;
  const context=vm.createContext({
    window:{},setTimeout,clearTimeout,
    localStorage:{removeItem(){}},
    CustomEvent:class {constructor(type, options){this.type=type;this.detail=options?.detail;}},
    document:{readyState:'loading',body:{dataset:{}},querySelectorAll:()=>[],
      addEventListener(){},dispatchEvent(event){if(event.type==='auth:changed')authEvents++;}},
    fetch:async(path,options)=>{
      requests++;assert.equal(path,'/accounts/session');assert.equal(options.credentials,'include');
      assert.equal(options.cache,'no-store');assert.equal(options.headers['X-Damage-Auth'],'1');
      return {status:401,json:async()=>{jsonReads++;return {authenticated:false};}};
    }
  });
  const {module}=await graph('wallet-switcher.js',{},context);
  await module.evaluate();
  assert.equal(await context.window.TokenManager.ready,null);
  assert.equal(context.window.TokenManager.isAuthenticated(),false);
  assert.equal(context.window.TokenManager.getToken(),'');
  assert.deepEqual([requests,jsonReads,authEvents],[1,0,1]);
});
