import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const code = await readFile(new URL('../../priv/static/js/auth-model.js', import.meta.url), 'utf8');
const {normaliseSession, signatureHex, errorMessage, walletDeepLink, parseCallback} =
  await import('data:text/javascript;base64,' + Buffer.from(code).toString('base64'));
const address = 'ak_' + '2'.repeat(50), state = 'a'.repeat(64), sig = 'b'.repeat(128);
const session = () => ({authenticated: true, mode:'wallet', address, access_token:'ds1.' + state,
  expires_at:Math.floor(Date.now()/1000)+3600, capabilities:{execute:false}});
const pending = phase => ({state, phase, createdAt:1000, challenge:{address, challenge_id:'proof'}});
const callback = (phase, fields = {}) => '#wallet-callback?' + new URLSearchParams({state, phase, result:'ok', address, ...fields});
test('requires a server-issued session, not merely an address', () => assert.throws(() => normaliseSession({address})));
test('accepts wallet session and freezes capabilities', () => {
  for (const address of [session().address, 'ak_11111111111111111111111111111111273Yts']) {
    const s=normaliseSession({...session(), address}); assert.equal(s.mode,'wallet'); assert.ok(Object.isFrozen(s.capabilities));
  }
});
test('rejects unsupported mode', () => assert.throws(() => normaliseSession({...session(),mode:'admin'})));
test('rejects stateless token as new browser session', () => assert.throws(() => normaliseSession({...session(),access_token:'ae1.any.sig'})));
test('rejects expired session', () => assert.throws(() => normaliseSession({...session(),expires_at:1})));
test('does not treat a rejected signature as success', () => assert.throws(() => signatureHex({ok:false,result:{signature:sig}})));
test('normalises Sidekick hex response', () => assert.equal(signatureHex({ok:true,result:{signature:sig.toUpperCase()}}),sig));
test('rejects malformed signature', () => assert.throws(() => signatureHex('sg_unhandled')));
test('limits error text length', () => assert.equal(errorMessage({message:'x'.repeat(1000)},400).length,500));
test('rate-limit response has useful retry message', () => assert.match(errorMessage({},429),/minute/));
test('wallet connect deep link has origin-bound fragment callbacks', () => {
  const link=new URL(walletDeepLink('connect','https://damage.test',state));
  const cb=new URL(link.searchParams.get('x-success'));
  assert.equal(cb.origin,'https://damage.test'); assert.equal(cb.search,''); assert.match(cb.hash,/\{address\}/);
});
test('sign-message link uses plain UTF-8 and never broadcasts', () => {
  const link=new URL(walletDeepLink('sign','https://damage.test',state,'Sign in safely'));
  assert.equal(link.pathname,'/sign-message'); assert.equal(link.searchParams.get('message'),'Sign in safely');
  assert.equal(link.searchParams.has('encoding'),false); assert.equal(link.searchParams.has('broadcast'),false);
});
test('no transaction operation exists in auth link helper', () => assert.throws(() => walletDeepLink('transaction','https://damage.test',state)));
test('rejects unsolicited mobile callback', () => assert.throws(() => parseCallback(callback('connect'),null,1100)));
test('accepts bound mobile address return as connection only', () => {
  const result=parseCallback(callback('connect',{networkId:'ae_mainnet'}),pending('connect'),1100);
  assert.equal(result.address,address); assert.equal(result.signature,undefined);
});
test('rejects wrong mobile state', () => assert.throws(() => parseCallback(callback('connect',{state:'other'}),pending('connect'),1100)));
test('rejects stale callback', () => assert.throws(() => parseCallback(callback('connect'),pending('connect'),602000)));
test('rejects duplicate callback fields', () => assert.throws(() => parseCallback(callback('connect')+'&state='+state,pending('connect'),1100)));
test('rejects account changed during signing', () => assert.throws(() => parseCallback(callback('sign',{signature:sig,address:'ak_'+'3'.repeat(50)}),pending('sign'),1100)));
test('accepts valid sign return', () => assert.equal(parseCallback(callback('sign',{signature:sig}),pending('sign'),1100).signature,sig));
test('wallet cancellation requires the same state binding', () => assert.deepEqual(parseCallback(callback('connect',{result:'cancel'}),pending('connect'),1100),{cancelled:true}));

const main = await readFile(new URL('../../priv/static/js/main.js', import.meta.url), 'utf8');
test('operator form bindings precede the anonymous dashboard early return', () => {
  const guard=main.indexOf('if (!document.getElementById("content")) return;');
  assert.ok(guard>0);
  for (const hook of ['const nodeUnlockForm =', 'const nodeSetPasswordSubmitBtn =', '// Sweep wallet button handler']) {
    const at=main.indexOf(hook); assert.ok(at>0 && at<guard,hook);
  }
});
