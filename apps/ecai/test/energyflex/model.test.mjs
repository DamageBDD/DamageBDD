import {test} from 'node:test';
import assert from 'node:assert/strict';
import {makeFixture,compare,checkPlan,earliestFirst,tariffGreedy,exactPlan,makeEvidence,canonical,PRESETS} from '../../priv/static/js/energyflex-model.js';
test('reference result: 450 assignments, 189 feasible, 700 cents saved',()=>{
 const r=compare(makeFixture()); assert.deepEqual(r.search,{candidate_assignments:450,feasible_assignments:189,complete:true});
 assert.equal(r.strategies.earliest.verification.metrics.total_variable_energy_cost_cents,2735);
 assert.equal(r.strategies.optimal.verification.metrics.total_variable_energy_cost_cents,2035);
 assert.equal(r.comparison.saving_cents,700); assert.equal(r.comparison.tariff_matches_optimum,true);
});
test('each preset replays deterministically',()=>{for(const p of PRESETS)assert.equal(canonical(compare(makeFixture(p.id))),canonical(compare(makeFixture(p.id))));});
test('infeasible is explicit, not a zero-cost success',()=>{
 const r=compare(makeFixture('impossible'));assert.equal(r.strategies.optimal.plan,null);assert.equal(r.search.feasible_assignments,0);assert.equal(r.comparison.saving_cents,null);assert.equal(r.comparison.comparable,false);
});
test('grid squeeze rejects stale optimum and finds a new valid one',()=>{
 const old=exactPlan(makeFixture()).plan, f=makeFixture('grid-squeeze');assert.equal(checkPlan(f,old).passed,false);assert.equal(checkPlan(f,exactPlan(f).plan).passed,true);
});
test('strict schedule checks reject duplicates, missing IDs, late energy, overloads, string and fractional slots',()=>{
 const f=makeFixture(),good=exactPlan(f).plan;
 for(const modify of [p=>p['EV-A']=[0,0],p=>delete p['EV-C'],p=>p['EV-A']=[0,5],p=>{for(const k in p)p[k]=[0,1];},p=>p['EV-A']=['0',1],p=>p['EV-A']=[0.5,1],p=>p.EXTRA=[],p=>p['EV-A']=[-1,2]]) {
  const p=structuredClone(good);modify(p);assert.equal(checkPlan(f,p).passed,false);
 }
});
test('null, arrays, prototype vehicle keys, and NaN do not pass',()=>{
 const f=makeFixture();for(const p of [null,[],{},Object.create(exactPlan(f).plan),{'EV-A':[NaN,1],'EV-B':[1,2],'EV-C':[3,4]}])assert.equal(checkPlan(f,p).passed,false);
});
test('unknown, unbounded and noninteger inputs fail closed',()=>{
 for(const action of [()=>makeFixture('unknown'),()=>makeFixture('evening',{capacity_kw:27}),()=>makeFixture('evening',{capacity_kw:17.5}),()=>makeFixture('evening',{deadline:5}),()=>makeFixture('evening',{evil:true}),()=>compare({...makeFixture(),prices_cents_per_kwh:[-1,1,1,1,1,1]})])assert.throws(action);
});
test('all bounded controls: any valid heuristic cannot beat the exact optimum',()=>{
 for(const p of PRESETS)for(let cap=10;cap<=26;cap++)for(const deadline of [2,3,4]){
  const f=makeFixture(p.id,{capacity_kw:cap,deadline}),r=compare(f),opt=r.strategies.optimal;
  if(opt.plan)assert.equal(opt.verification.passed,true);
  for(const k of ['earliest','tariff'])if(r.strategies[k].verification.passed){assert.ok(opt.plan);assert.ok(r.strategies[k].verification.metrics.charging_cost_cents>=opt.verification.metrics.charging_cost_cents);}
 }
});
test('an exact search can legitimately report a tie with the conventional baseline',()=>{const f=makeFixture();f.prices_cents_per_kwh.fill(20);const r=compare(f);assert.equal(r.comparison.saving_cents,0);assert.equal(r.comparison.tariff_matches_optimum,true);});
test('evidence checksum and stale-result protection',async()=>{
 const f=makeFixture(),r=compare(f),e=await makeEvidence(f,r);assert.match(e.integrity.sha256,/^[0-9a-f]{64}$/);assert.equal(e.execution,'browser-local-reference');
 await assert.rejects(()=>makeEvidence(makeFixture('grid-squeeze'),r),/stale/);
});
