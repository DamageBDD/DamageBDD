/** Food Rescue & Recall v1. Bounded synthetic planning, not food-safety advice.
 * No inference, network, native ECAI retrieval or remote DamageBDD execution.
 * Six indivisible lots, six fixed trips. Exact search <= 7^6 assignments.
 */
export const VERSION = 'food-rescue-v1';
export const SCENARIOS = Object.freeze([
  {id:'everyday', name:'Rescue the morning', tag:'START HERE', description:'Match short-lived stock to the right stops.'},
  {id:'road-closure', name:'Bridge closed', tag:'DISRUPTION', description:'Use the north detour. The clock keeps moving.'},
  {id:'cold-chain', name:'Cooling failure', tag:'QUARANTINE', description:'A warm reading blocks one berry lot.'},
  {id:'missing-record', name:'Missing sensor log', tag:'UNKNOWN', description:'No evidence is not the same as a pass.'},
  {id:'recall', name:'Supplier recall', tag:'TRACEABILITY', description:'Hold both lots from the same dairy batch.'},
  {id:'late-recall', name:'Recall after delivery', tag:'RESPONSE', description:'Trace delivered stock and put recipients on hold.'},
  {id:'demand-surge', name:'More mouths to feed', tag:'SHORTFALL', description:'Demand rises. Do not invent extra food.'},
  {id:'van-outage', name:'One van offline', tag:'CAPACITY', description:'Make the most of the remaining timetable.'}
]);
export const DEFAULTS = Object.freeze({capacityKg:160, delayMinutes:0});
export const SCOPE = 'Synthetic browser-local whole-lot planning and recall simulation. Not food-safety certification, live sensor provenance, native ECAI retrieval or a DamageBDD backend run.';
export const clone = value => JSON.parse(JSON.stringify(value));
export function canonical(value) {
  if (Array.isArray(value)) return '['+value.map(canonical).join(',')+']';
  if (value && typeof value === 'object') return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
  return JSON.stringify(value);
}
function integer(v, min, max, step=1) { return Number.isSafeInteger(v) && v>=min && v<=max && (v-min)%step===0; }
export function fixture(id='everyday', controls=DEFAULTS) {
  if (!SCENARIOS.some(s=>s.id===id)) throw new Error('Unknown scenario');
  if (!controls || canonical(Object.keys(controls).sort())!==canonical(['capacityKg','delayMinutes']) ||
      !integer(controls.capacityKg,80,180,10) || !integer(controls.delayMinutes,0,30,5)) throw new Error('Invalid demo controls');
  const lots = [
    {id:'TOM-01',name:'Tomatoes',kg:80,batch:'GROW-11',cold:false,expires:70,readings:[]},
    {id:'LEAF-02',name:'Leafy greens',kg:60,batch:'GROW-12',cold:true,expires:50,readings:[3,4,4]},
    {id:'BREAD-03',name:'Bread',kg:100,batch:'BAKE-18',cold:false,expires:250,readings:[]},
    {id:'YOG-04',name:'Yoghurt · lot A',kg:50,batch:'DAIRY-42',cold:true,expires:145,readings:[3,3,4]},
    {id:'YOG-05',name:'Yoghurt · lot B',kg:40,batch:'DAIRY-42',cold:true,expires:220,readings:[4,4,3]},
    {id:'BERRY-06',name:'Berries',kg:70,batch:'GROW-13',cold:true,expires:140,readings:[3,4,3]}
  ];
  if(id==='cold-chain') lots[5].readings=[3,9,8];
  if(id==='missing-record') lots[1].readings=[3,null,4];
  return {version:VERSION,scenario:id,controls:clone(controls),horizon:270,
    policy:{id:'DEMO-COLD-01',maxTemperatureC:5,requiredReadings:3,expiryExclusive:true,wholeLots:true},
    lots,
    nodes:[{id:'depot',name:'Rescue hub',x:105,y:215},{id:'west',name:'West junction',x:280,y:215},
      {id:'east',name:'East junction',x:435,y:215},{id:'north',name:'North bypass',x:280,y:80},
      {id:'kitchen',name:'Community kitchen',x:590,y:95},{id:'pantry',name:'Neighbourhood pantry',x:645,y:285},
      {id:'shelter',name:'Evening shelter',x:310,y:395}],
    edges:[{id:'hub-west',a:'depot',b:'west',minutes:8},{id:'bridge',a:'west',b:'east',minutes:4},
      {id:'east-kitchen',a:'east',b:'kitchen',minutes:6},{id:'east-pantry',a:'east',b:'pantry',minutes:8},
      {id:'west-shelter',a:'west',b:'shelter',minutes:14},{id:'hub-north',a:'depot',b:'north',minutes:10},
      {id:'north-kitchen',a:'north',b:'kitchen',minutes:18}],
    closedEdges:id==='road-closure'?['bridge']:[],
    destinations:[{id:'kitchen',name:'Community kitchen',demandKg:id==='demand-surge'?200:160,cold:true},
      {id:'pantry',name:'Neighbourhood pantry',demandKg:id==='demand-surge'?180:140,cold:true},
      {id:'shelter',name:'Evening shelter',demandKg:id==='demand-surge'?120:100,cold:false}],
    vehicles:[{id:'VAN-A',available:true,cold:true},{id:'VAN-B',available:id!=='van-outage',cold:true}],
    timetable:[{id:'A1',vehicle:'VAN-A',destination:'kitchen',depart:0},
      {id:'B1',vehicle:'VAN-B',destination:'pantry',depart:0},
      {id:'A2',vehicle:'VAN-A',destination:'shelter',depart:90},
      {id:'B2',vehicle:'VAN-B',destination:'kitchen',depart:90},
      {id:'A3',vehicle:'VAN-A',destination:'pantry',depart:180},
      {id:'B3',vehicle:'VAN-B',destination:'shelter',depart:180}],
    recalls:id==='recall'?[{batch:'DAIRY-42',at:0,reason:'Synthetic supplier recall'}]:[],
    incidents:id==='late-recall'?[{batch:'DAIRY-42',at:30,reason:'Synthetic supplier recall received at 09:30'}]:[]};
}
export function shortestPath(world, target) {
  const distance=new Map(world.nodes.map(n=>[n.id,Infinity])); distance.set('depot',0);
  const paths=new Map([['depot',['depot']]]), visited=new Set();
  while(visited.size<world.nodes.length) {
    const node=world.nodes.filter(n=>!visited.has(n.id)).sort((a,b)=>distance.get(a.id)-distance.get(b.id)||a.id.localeCompare(b.id))[0];
    if(!node || !Number.isFinite(distance.get(node.id))) break;
    visited.add(node.id);
    for(const edge of world.edges) {
      if(world.closedEdges.includes(edge.id)) continue;
      const next=edge.a===node.id?edge.b:edge.b===node.id?edge.a:null;
      if(next && distance.get(node.id)+edge.minutes<distance.get(next)) {
        distance.set(next,distance.get(node.id)+edge.minutes); paths.set(next,[...paths.get(node.id),next]);
      }
    }
  }
  return Number.isFinite(distance.get(target))?{nodes:paths.get(target),minutes:distance.get(target)}:null;
}
export function trips(world) {
  return world.timetable.map(t=>{const route=shortestPath(world,t.destination),depart=t.depart+world.controls.delayMinutes;
    return {...t,depart,arrival:route?depart+route.minutes:null,returns:route?depart+route.minutes*2:null,route};});
}
export function disposition(world, lot, minute=0, includeIncidents=false) {
  const records=includeIncidents?[...world.recalls,...world.incidents]:world.recalls;
  if(records.some(r=>r.batch===lot.batch && r.at<=minute)) return {state:'quarantined',reason:'Recalled batch '+lot.batch};
  if(lot.cold && lot.readings.some(v=>Number.isFinite(v) && v>world.policy.maxTemperatureC)) return {state:'quarantined',reason:'Temperature exceeds synthetic demo rule'};
  if(lot.cold && (lot.readings.length!==world.policy.requiredReadings || lot.readings.some(v=>!Number.isFinite(v)))) return {state:'unverifiable',reason:'Required temperature evidence is missing'};
  return {state:'available',reason:'Eligible under the synthetic rules'};
}
function candidateReason(world, lot, trip) {
  const state=disposition(world,lot);
  if(state.state!=='available') return state.reason;
  const vehicle=world.vehicles.find(v=>v.id===trip.vehicle),dest=world.destinations.find(d=>d.id===trip.destination);
  if(!vehicle?.available) return 'Vehicle unavailable';
  if(!trip.route) return 'No open route';
  if(lot.cold && (!vehicle.cold||!dest.cold)) return 'Destination or vehicle cannot accept chilled stock';
  if(trip.arrival>=lot.expires) return 'Arrival is not before expiry';
  if(trip.returns>world.horizon) return 'Trip exceeds the demo horizon';
  const next=world.timetable.filter(t=>t.vehicle===trip.vehicle && t.depart+world.controls.delayMinutes>trip.depart).sort((a,b)=>a.depart-b.depart)[0];
  if(next && trip.returns>next.depart+world.controls.delayMinutes) return 'Vehicle cannot return before next departure';
  return null;
}
function score(world, assignments) {
  const ts=trips(world),lm=new Map(world.lots.map(l=>[l.id,l]));
  return {kg:assignments.reduce((s,a)=>s+lm.get(a.lot).kg,0),
    kgMinutes:assignments.reduce((s,a)=>s+lm.get(a.lot).kg*ts.find(t=>t.id===a.trip).arrival,0),
    travelMinutes:[...new Set(assignments.map(a=>a.trip))].reduce((s,id)=>s+ts.find(t=>t.id===id).route.minutes*2,0)};
}
/** Simple FEFO+earliest-arrival greedy baseline, not the best conventional solver. */
export function greedyPlan(world) {
  const ts=trips(world),used={},demand={},assignments=[];
  for(const lot of [...world.lots].sort((a,b)=>a.expires-b.expires||a.id.localeCompare(b.id))) {
    const candidates=ts.filter(t=>!candidateReason(world,lot,t)).sort((a,b)=>a.arrival-b.arrival||a.id.localeCompare(b.id));
    for(const t of candidates) {
      const dest=world.destinations.find(d=>d.id===t.destination);
      if((used[t.id]||0)+lot.kg>world.controls.capacityKg || (demand[t.destination]||0)+lot.kg>dest.demandKg) continue;
      used[t.id]=(used[t.id]||0)+lot.kg; demand[t.destination]=(demand[t.destination]||0)+lot.kg;
      assignments.push({lot:lot.id,trip:t.id});break;
    }
  }
  assignments.sort((a,b)=>world.lots.findIndex(l=>l.id===a.lot)-world.lots.findIndex(l=>l.id===b.lot));
  return {method:'fefo-earliest',assignments,score:score(world,assignments)};
}
/** Exact only within this fixed six-trip / six-lot model. No future recall input. */
export function rescuePlan(world) {
  const ts=trips(world),lots=world.lots,used=Array(ts.length).fill(0),demand={};
  const choices=lots.map(l=>ts.map((t,i)=>({t,i})).filter(({t})=>!candidateReason(world,l,t)));
  let best=null,nodes=0;const current=[];
  function visit(i,kg,kgMinutes,travelMinutes) {
    nodes++;
    if(best && kg+lots.slice(i).reduce((s,l)=>s+l.kg,0)<best.score.kg) return;
    if(i===lots.length) {
      const candidate={kg,kgMinutes,travelMinutes};
      if(!best || kg>best.score.kg || (kg===best.score.kg && (kgMinutes<best.score.kgMinutes || (kgMinutes===best.score.kgMinutes && travelMinutes<best.score.travelMinutes)))) best={assignments:clone(current),score:candidate};
      return;
    }
    const lot=lots[i];
    for(const {t,i:idx} of choices[i]) {
      const destination=world.destinations.find(d=>d.id===t.destination);
      if(used[idx]+lot.kg>world.controls.capacityKg || (demand[t.destination]||0)+lot.kg>destination.demandKg) continue;
      const extra=used[idx]===0?t.route.minutes*2:0;
      used[idx]+=lot.kg;demand[t.destination]=(demand[t.destination]||0)+lot.kg;current.push({lot:lot.id,trip:t.id});
      visit(i+1,kg+lot.kg,kgMinutes+lot.kg*t.arrival,travelMinutes+extra);
      current.pop();used[idx]-=lot.kg;demand[t.destination]-=lot.kg;
    }
    visit(i+1,kg,kgMinutes,travelMinutes);
  }
  visit(0,0,0,0);
  return {method:'bounded-exact',...best,searchNodes:nodes};
}
/** Recompute proposal constraints; never trust flags or supplied totals. */
export function validatePlan(world, assignments) {
  const errors=[],seen=new Set(),loads={},demand={};const ts=trips(world);
  if(!Array.isArray(assignments)||assignments.length>world.lots.length) return {valid:false,errors:['Invalid assignment list']};
  for(const a of assignments) {
    if(!a||canonical(Object.keys(a).sort())!==canonical(['lot','trip'])) {errors.push('Unknown assignment fields');continue;}
    const lot=world.lots.find(l=>l.id===a.lot),trip=ts.find(t=>t.id===a.trip);
    if(!lot||!trip) {errors.push('Unknown lot or trip');continue;}
    if(seen.has(lot.id)) errors.push('Duplicate lot '+lot.id); seen.add(lot.id);
    const why=candidateReason(world,lot,trip);if(why) errors.push(lot.id+': '+why);
    loads[trip.id]=(loads[trip.id]||0)+lot.kg;demand[trip.destination]=(demand[trip.destination]||0)+lot.kg;
  }
  for(const [trip,kg] of Object.entries(loads)) if(kg>world.controls.capacityKg) errors.push(trip+': vehicle capacity exceeded');
  for(const dest of world.destinations) if((demand[dest.id]||0)>dest.demandKg) errors.push(dest.id+': recipient demand exceeded');
  return {valid:errors.length===0,errors};
}
export function executePlan(world, plan) {
  const validation=validatePlan(world,plan.assignments);if(!validation.valid) throw new Error('Rejected plan: '+validation.errors.join('; '));
  const ts=trips(world),records=world.lots.map(l=>({lot:l.id,kg:l.kg,batch:l.batch,...disposition(world,l),location:'depot',trip:null,deliveredAt:null}));
  const events=[],trace=[];
  const snapshot=()=>clone(records);
  trace.push({at:0,type:'start',message:'Inventory checked against the current synthetic rules.',records:snapshot()});
  for(const incident of world.incidents) events.push({at:incident.at,order:0,type:'recall',batch:incident.batch});
  for(const t of ts) if(plan.assignments.some(a=>a.trip===t.id)) {
    events.push({at:t.depart,order:1,type:'dispatch',trip:t.id});events.push({at:t.arrival,order:2,type:'arrival',trip:t.id});
  }
  events.sort((a,b)=>a.at-b.at||a.order-b.order||String(a.trip||'').localeCompare(String(b.trip||'')));
  const ledger=[],gate=[];
  for(const event of events) {
    if(event.type==='recall') {
      for(const record of records.filter(r=>r.batch===event.batch)) {
        const previous=record.state;record.state=previous==='delivered'?'recall-hold':'quarantined';record.reason='Recalled batch '+event.batch;
        ledger.push({at:event.at,action:previous==='delivered'?'recipient-hold':'recall-hold',lot:record.lot,kg:record.kg,location:record.location});
      }
    } else {
      const trip=ts.find(t=>t.id===event.trip);
      for(const a of plan.assignments.filter(a=>a.trip===trip.id)) {
        const lot=world.lots.find(l=>l.id===a.lot),record=records.find(r=>r.lot===a.lot);
        if(event.type==='arrival' && record.trip!==trip.id) continue;
        const eligible=disposition(world,lot,event.at,true),passes=eligible.state==='available' && event.at<lot.expires;
        gate.push({at:event.at,stage:event.type,lot:lot.id,trip:trip.id,passed:passes,reason:passes?'Current recall, evidence and expiry checks pass':eligible.state!=='available'?eligible.reason:'Expired before release'});
        if(!passes) {
          record.state=eligible.state==='unverifiable'?'unverifiable':'quarantined';record.reason=eligible.state!=='available'?eligible.reason:'Expired before release';
          if(event.type==='arrival')record.location=trip.destination;
          ledger.push({at:event.at,action:'release-blocked',lot:lot.id,kg:lot.kg,location:record.location});
        } else if(event.type==='dispatch') {
          record.state='in-transit';record.location=trip.vehicle;record.trip=trip.id;record.reason='In transit; check again on arrival';
          ledger.push({at:event.at,action:'loaded',lot:lot.id,kg:lot.kg,location:trip.vehicle});
        } else {
          record.state='delivered';record.location=trip.destination;record.deliveredAt=event.at;record.reason='Delivered before expiry under the demo rules';
          ledger.push({at:event.at,action:'delivered',lot:lot.id,kg:lot.kg,location:trip.destination});
        }
      }
    }
    trace.push({at:event.at,type:event.type,message:event.type==='recall'?'Recall received: '+event.batch+'. Hold all matching lots.':event.trip+' '+(event.type==='dispatch'?'dispatch checked':'arrival checked'),records:snapshot()});
  }
  for(const r of records) if(r.state==='available') {r.state='unallocated';r.reason='No assignment in this plan; not counted as rescued';}
  trace.push({at:world.horizon,type:'end',message:'End of demo window. Only eligible deliveries count as rescued.',records:snapshot()});
  const sum=fn=>records.filter(fn).reduce((s,r)=>s+r.kg,0);
  const metrics={totalKg:world.lots.reduce((s,l)=>s+l.kg,0),rescuedKg:sum(r=>r.state==='delivered'),
    quarantineKg:sum(r=>['quarantined','recall-hold'].includes(r.state)),unverifiableKg:sum(r=>r.state==='unverifiable'),
    unallocatedKg:sum(r=>r.state==='unallocated'),recipientHoldKg:sum(r=>r.state==='recall-hold')};
  metrics.demandKg=world.destinations.reduce((s,d)=>s+d.demandKg,0);metrics.unmetKg=metrics.demandKg-metrics.rescuedKg;
  const checks=[
    {id:'mass',label:'Every kilogram accounted for',passed:metrics.totalKg===metrics.rescuedKg+metrics.quarantineKg+metrics.unverifiableKg+metrics.unallocatedKg},
    {id:'eligible',label:'No held stock counted as rescued',passed:records.filter(r=>r.state==='delivered').every(r=>disposition(world,world.lots.find(l=>l.id===r.lot),world.horizon,true).state==='available')},
    {id:'expiry',label:'Deliveries arrive before expiry',passed:ledger.filter(e=>e.action==='delivered').every(e=>e.at<world.lots.find(l=>l.id===e.lot).expires)},
    {id:'capacity',label:'Vehicle loads stay within capacity',passed:ts.every(t=>plan.assignments.filter(a=>a.trip===t.id).reduce((s,a)=>s+world.lots.find(l=>l.id===a.lot).kg,0)<=world.controls.capacityKg)},
    {id:'demand',label:'Recipient allocations do not exceed demand',passed:world.destinations.every(d=>ledger.filter(e=>e.action==='delivered'&&e.location===d.id).reduce((s,e)=>s+e.kg,0)<=d.demandKg)},
    {id:'unique',label:'No lot is delivered twice',passed:new Set(ledger.filter(e=>e.action==='delivered').map(e=>e.lot)).size===ledger.filter(e=>e.action==='delivered').length},
    {id:'gate',label:'Every delivery has a passing release check',passed:ledger.filter(e=>e.action==='delivered').every(e=>gate.some(g=>g.stage==='arrival'&&g.lot===e.lot&&g.at===e.at&&g.passed))}
  ];
  return {plan,records,ledger,gate,trace,metrics,checks};
}
export function runScenario(id='everyday', controls=DEFAULTS) {
  const world=fixture(id,controls);
  const baseline=executePlan(world,greedyPlan(world)),rescue=executePlan(world,rescuePlan(world));
  return {version:VERSION,scope:SCOPE,world,baseline,rescue};
}
export function evidencePayload(result) { return {schema:VERSION,scope:SCOPE,result:clone(result)}; }
export async function makeEvidence(result) {
  if(!globalThis.crypto?.subtle) throw new Error('Evidence export needs HTTPS or localhost for SHA-256.');
  const payload=evidencePayload(result),bytes=new TextEncoder().encode(canonical(payload));
  const hash=await crypto.subtle.digest('SHA-256',bytes);
  return {payload,sha256:[...new Uint8Array(hash)].map(x=>x.toString(16).padStart(2,'0')).join('')};
}
export function runReferenceSuite() {
  return SCENARIOS.map(s=>{const r=runScenario(s.id);return {scenario:s.id,passed:r.baseline.checks.every(c=>c.passed)&&r.rescue.checks.every(c=>c.passed),rescuedKg:r.rescue.metrics.rescuedKg};});
}
export function recordAt(execution, minute) {
  return execution.trace.filter(t=>t.at<=minute).at(-1)?.records || execution.trace[0].records;
}
