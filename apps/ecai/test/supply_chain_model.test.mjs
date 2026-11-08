// Pure production-JavaScript helpers. API fixture is not a backend benchmark.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../priv/static/js/ecai-supply-chain.js',import.meta.url),'utf8');
const {assignments,vehiclePosition,isPublicSupplyChainRequest}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const fixture=JSON.parse(await readFile(new URL('./fixtures/supply_chain_browser.json',import.meta.url),'utf8'));

test('empty and populated assignment views',()=>{
  assert.equal(assignments(null).size,0);
  const a=assignments(fixture.approved);
  assert.equal(a.size,48);
  for(const route of fixture.approved.routes)for(const stop of route.stops){
    assert.equal(a.get(stop.order).vehicle,route.vehicle);
    assert.equal(a.get(stop.order).warehouse,route.warehouse);
    assert.equal(a.get(stop.order).finish,stop.finish);
  }
});
test('vehicle interpolation uses edge duration, not equal-distance segments',()=>{
  const s={nodes:[{id:'A',x:0,y:0},{id:'B',x:100,y:0},{id:'C',x:100,y:100}],
    vehicles:[{id:'T1',home:'A'}],edges:[{from:'A',to:'B',minutes:10},{from:'B',to:'C',minutes:20}]};
  const r={vehicle:'T1',legs:[{from:'A',to:'C',path:['A','B','C'],depart:6,arrive:36}]};
  assert.deepEqual(vehiclePosition(s,r,5),s.nodes[0]);
  assert.deepEqual(vehiclePosition(s,r,11),{x:50,y:0});
  assert.deepEqual(vehiclePosition(s,r,26),{x:100,y:50});
  assert.deepEqual(vehiclePosition(s,r,36),s.nodes[2]);
});
test('all fixture positions are finite and remain within the network',()=>{
  for(const route of fixture.approved.routes){
    for(let t=0;t<=240;t+=0.5){
      const p=vehiclePosition(fixture.scenario,route,t);
      assert.ok(Number.isFinite(p.x)&&Number.isFinite(p.y));
      assert.ok(p.x>=65&&p.x<=835&&p.y>=70&&p.y<=385);
    }
    const home=fixture.scenario.nodes.find(n=>n.id===fixture.scenario.vehicles.find(v=>v.id===route.vehicle).home);
    assert.deepEqual(vehiclePosition(fixture.scenario,route,240),home);
  }
});
test('zero-length pickup and loading hold remain at the depot',()=>{
  const r=fixture.approved.routes.find(r=>r.legs[0].arrive===0);
  assert.ok(r);
  const home=fixture.scenario.nodes.find(n=>n.id===r.warehouse);
  for(let t=0;t<r.load_end;t+=0.5)assert.deepEqual(vehiclePosition(fixture.scenario,r,t),home);
});


test('only exact public demo paths bypass the wallet/account gate',()=>{
  assert.equal(isPublicSupplyChainRequest('/ecai/supply-chain/public'),true);
  assert.equal(isPublicSupplyChainRequest('/ecai/supply-chain/public/evidence'),true);
  for(const action of ['reset','event','plan','approve','benchmark']) {
    assert.equal(isPublicSupplyChainRequest(`/ecai/supply-chain/public/${action}`,'POST'),true);
    assert.equal(isPublicSupplyChainRequest(`/ecai/supply-chain/public/${action}`,'GET'),false);
  }
  for(const path of ['/ecai/supply-chain','/ecai/supply-chain/plan',
    '/ecai/supply-chain/publicity','/ecai/supply-chain/public/../plan',
    '/ecai/supply-chain/public/plan/extra','https://evil.test/ecai/supply-chain/public']) {
    assert.equal(isPublicSupplyChainRequest(path),false);
    assert.equal(isPublicSupplyChainRequest(path,'POST'),false);
  }
  assert.equal(isPublicSupplyChainRequest('/ecai/supply-chain/public','DELETE'),false);
});


test('production console request omits account bearer on public demo routes',async()=>{
  const {runInNewContext}=await import('node:vm');
  const consoleSource=await readFile(new URL('../priv/static/js/ecai-console.js',import.meta.url),'utf8');
  const excerpt=(start,end)=>consoleSource.slice(consoleSource.indexOf(start),consoleSource.indexOf(end));
  const calls=[],state={authEpoch:1,sessionMode:'wallet',authenticated:true};
  const scope={state,URL,Response,DOMException,isPublicSupplyChainRequest,
    location:{origin:'https://ecai.test'},
    TokenManager:{getToken:()=> 'private-wallet-token',logout:()=>{throw Error('unexpected logout');}},
    fetch:async(path,options)=>{calls.push({path,options});return new Response('{"ok":true,"data":{}}');}};
  const api=runInNewContext(excerpt('  function safePath(', '  function applyConsoleCapabilities(')+
    excerpt('  function headers(', '  function setAuthenticated(')+'\n({request})',scope);
  await api.request('/ecai/supply-chain/public');
  await api.request('/ecai/supply-chain/public/reset',{method:'POST',body:{expected_revision:0},headers:{Authorization:'do-not-forward'}});
  assert.equal(calls.length,2);
  assert.equal(calls[0].options.headers.Authorization,undefined);
  assert.equal(calls[1].options.headers.Authorization,undefined);
  assert.equal(calls[1].options.headers['X-ECAI-Lab-Request'],'1');
  assert.equal(calls[1].options.headers['Content-Type'],'application/json');
  assert.equal(calls[1].options.credentials,'include');
  await assert.rejects(api.request('/ecai/supply-chain/plan',{method:'POST',body:{}}),/managed email/);
  assert.equal(calls.length,2);
  state.sessionMode='custodial';
  await api.request('/ecai/supply-chain');
  assert.equal(calls.at(-1).options.headers.Authorization,'Bearer private-wallet-token');
});
