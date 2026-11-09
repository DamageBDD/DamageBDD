import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,runScenario,SCENARIOS,DEFAULTS,trips,shortestPath,disposition,rescuePlan,greedyPlan,executePlan,validatePlan,recordAt,canonical,makeEvidence,runReferenceSuite} from '../../priv/static/js/food-rescue-model.js';

test('Reference is 400 vs 360 kg, every kilogram is accounted for',()=>{
 const r=runScenario();assert.equal(r.rescue.metrics.rescuedKg,400);assert.equal(r.baseline.metrics.rescuedKg,360);assert.equal(r.rescue.metrics.unmetKg,0);
 assert.deepEqual(r.rescue.checks.map(c=>c.passed),Array(7).fill(true));assert.equal(r.rescue.plan.score.kg,400);
});
test('All 616 scenario/control combinations satisfy invariants with non-inferior planned kg',()=>{
 let count=0;
 for(const {id} of SCENARIOS)for(let capacityKg=80;capacityKg<=180;capacityKg+=10)for(let delayMinutes=0;delayMinutes<=30;delayMinutes+=5){
  const r=runScenario(id,{capacityKg,delayMinutes});count++;
  for(const path of ['baseline','rescue']){assert.ok(r[path].checks.every(c=>c.passed),`${id}/${capacityKg}/${delayMinutes}`);assert.ok(r[path].metrics.rescuedKg<=400);assert.ok(r[path].metrics.unmetKg>=0);}
  assert.ok(r.rescue.plan.score.kg>=r.baseline.plan.score.kg);assert.ok(r.rescue.plan.searchNodes<140000);
 }
 assert.equal(count,616);
});
test('Bridge closure recomputes open routes and vehicle returns',()=>{
 const open=fixture(),closed=fixture('road-closure');assert.equal(shortestPath(open,'pantry').minutes,20);assert.equal(shortestPath(closed,'pantry').minutes,42);
 assert.ok(shortestPath(closed,'pantry').nodes.includes('north'));
 for(const t of trips(closed)){assert.ok(t.returns<=t.depart+90);assert.ok(!t.route.nodes.join('-').includes('west-east'));}
 const r=runScenario('road-closure',{capacityKg:160,delayMinutes:15});assert.ok(r.rescue.metrics.rescuedKg<400);
});
test('Warm telemetry quarantines 70kg; missing telemetry remains separately unverifiable',()=>{
 const warm=runScenario('cold-chain'),missing=runScenario('missing-record');assert.equal(warm.rescue.metrics.quarantineKg,70);assert.equal(warm.rescue.metrics.rescuedKg,330);
 assert.equal(missing.rescue.metrics.unverifiableKg,60);assert.equal(missing.rescue.metrics.quarantineKg,0);assert.equal(missing.rescue.metrics.rescuedKg,340);
});
test('A recall blocks every matching lot before dispatch',()=>{
 const r=runScenario('recall');assert.equal(r.rescue.metrics.quarantineKg,90);assert.equal(r.rescue.metrics.rescuedKg,310);
 assert.ok(r.rescue.records.filter(x=>x.batch==='DAIRY-42').every(x=>x.state==='quarantined'&&x.location==='depot'));
 assert.ok(r.rescue.ledger.every(e=>!e.lot.startsWith('YOG')));
});
test('Late recall is not leaked to planning and creates exact recipient holds',()=>{
 const before=runScenario(),after=runScenario('late-recall');assert.deepEqual(before.rescue.plan,after.rescue.plan);
 const dairy=t=>recordAt(after.rescue,t).filter(r=>r.batch==='DAIRY-42');
 assert.ok(dairy(29).every(r=>r.state==='delivered'));assert.ok(dairy(30).every(r=>r.state==='recall-hold'));
 assert.ok(dairy(30).every(r=>r.location==='kitchen'));assert.equal(after.rescue.metrics.recipientHoldKg,90);assert.equal(after.rescue.metrics.rescuedKg,310);
});
test('Recall exactly at arrival wins over release; no prior delivery is invented',()=>{
 const r=runScenario('late-recall',{capacityKg:160,delayMinutes:15});
 assert.equal(r.rescue.metrics.recipientHoldKg,0);
 assert.ok(r.rescue.gate.filter(g=>g.lot.startsWith('YOG')&&g.stage==='arrival').every(g=>!g.passed));
 const w=fixture('late-recall');w.incidents[0].at=18;const e=executePlan(w,rescuePlan(w));
 assert.ok(e.ledger.filter(x=>x.lot.startsWith('YOG')).every(x=>x.action!=='delivered'));
});
test('No demand or inventory is invented for shortages and vehicle outages',()=>{
 const s=runScenario('demand-surge');assert.equal(s.rescue.metrics.unmetKg,100);assert.equal(s.rescue.metrics.rescuedKg,400);
 const r=runScenario('van-outage');assert.equal(r.rescue.metrics.rescuedKg,290);assert.equal(r.rescue.metrics.unallocatedKg,110);
 assert.ok(r.rescue.plan.assignments.every(a=>a.trip.startsWith('A')));
});
test('Reject a forged release, duplicate lot, unknown lot, trip, extra field and overload',()=>{
 const w=fixture();const a=runScenario().rescue.plan.assignments;
 assert.equal(validatePlan(w,[...a,a[0]]).valid,false);
 for(const candidate of [[{lot:'YOG-04',trip:'A1'}],[{lot:'NOT-A-LOT',trip:'A1'}],[{lot:'TOM-01',trip:'unknown'}],[{lot:'TOM-01',trip:'A1',approved:true}]])assert.equal(validatePlan(fixture('recall'),candidate).valid,false);
 const overloaded=[{lot:'TOM-01',trip:'A1'},{lot:'LEAF-02',trip:'A1'},{lot:'YOG-04',trip:'A1'}];assert.ok(validatePlan(w,overloaded).errors.some(s=>s.includes('capacity')));
 assert.throws(()=>executePlan(w,{assignments:overloaded}),/Rejected plan/);
});
test('Cold lots cannot be assigned to ambient recipient and expiry is exclusive',()=>{
 assert.equal(validatePlan(fixture(),[{lot:'YOG-04',trip:'A2'}]).valid,false);
 const w=fixture();w.lots.find(l=>l.id==='LEAF-02').expires=18;
 assert.equal(validatePlan(w,[{lot:'LEAF-02',trip:'A1'}]).valid,false);
});
test('Conflicting trip timetable and closed network fail without dispatch',()=>{
 const w=fixture();w.edges.forEach(e=>e.minutes*=10);
 assert.equal(rescuePlan(w).score.kg,0);
 w.closedEdges=w.edges.map(e=>e.id);assert.equal(shortestPath(w,'kitchen'),null);assert.equal(greedyPlan(w).score.kg,0);
});
test('Exact objective matches independent unpruned enumeration',()=>{
 const w=fixture(),ts=trips(w),choices=Array(6).fill(null).map(()=>[-1,0,1,2,3,4,5]);let best=null,leaves=0;
 const visit=(i,current)=>{if(i===6){leaves++;if(!validatePlan(w,current).valid)return;const assignments=current;
  const kg=assignments.reduce((s,a)=>s+w.lots.find(l=>l.id===a.lot).kg,0),km=assignments.reduce((s,a)=>s+w.lots.find(l=>l.id===a.lot).kg*ts.find(t=>t.id===a.trip).arrival,0),tm=[...new Set(assignments.map(a=>a.trip))].reduce((s,id)=>s+ts.find(t=>t.id===id).route.minutes*2,0);
  if(!best||kg>best.kg||(kg===best.kg&&(km<best.kgMinutes||(km===best.kgMinutes&&tm<best.travelMinutes))))best={kg,kgMinutes:km,travelMinutes:tm};return;}
  for(const c of choices[i])visit(i+1,c<0?current:[...current,{lot:w.lots[i].id,trip:ts[c].id}]);};
 visit(0,[]);assert.equal(leaves,117649);assert.deepEqual(best,rescuePlan(w).score);
});
test('Reference suite passes and does not mutate fixtures across calls',()=>{
 const w=fixture(),snapshot=canonical(w);rescuePlan(w);greedyPlan(w);assert.equal(canonical(w),snapshot);
 assert.equal(runReferenceSuite().filter(x=>x.passed).length,8);assert.deepEqual(runScenario(),runScenario());
});
test('Bounded input validation rejects arbitrary and non-integer parameters',()=>{
 for(const c of [{capacityKg:Infinity,delayMinutes:0},{capacityKg:160,delayMinutes:NaN},{capacityKg:161,delayMinutes:0},{capacityKg:160,delayMinutes:2},{...DEFAULTS,extra:1},null])assert.throws(()=>fixture('everyday',c));
 assert.throws(()=>fixture('unknown'));assert.equal(disposition(fixture('missing-record'),fixture('missing-record').lots[1]).state,'unverifiable');
});
test('Evidence is deterministic and checksummed using canonical content',async()=>{
 const evidence=await makeEvidence(runScenario());const {createHash}=await import('node:crypto');assert.equal(evidence.sha256,createHash('sha256').update(canonical(evidence.payload)).digest('hex'));
 assert.equal(evidence.payload.schema,'food-rescue-v1');assert.match(evidence.payload.scope,/synthetic/i);
});
