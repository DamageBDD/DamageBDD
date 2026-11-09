/** Synthetic, fully enumerated scheduling model. Not an ECAI/LLM algorithm. */
import {VERSION, validateFixture, checkPlan, canonical} from './energyflex-checker.js';
export {VERSION, validateFixture, checkPlan, canonical};
export const PRESETS = Object.freeze([
  {id: 'evening', title: 'Evening commute', icon: '01', hint: 'Move charging away from expensive hours.', capacity: 18, deadline: 3, prices: [60,60,35,20,20,15]},
  {id: 'price-spike', title: 'Price spike', icon: '02', hint: 'The peak tariff doubles. Can you avoid it?', capacity: 18, deadline: 3, prices: [120,120,35,20,20,15]},
  {id: 'grid-squeeze', title: 'Grid squeeze', icon: '03', hint: 'A lower site limit forces charging to spread out.', capacity: 16, deadline: 3, prices: [60,60,35,20,20,15]},
  {id: 'early-departure', title: 'Leaving early', icon: '04', hint: 'Vehicle A must leave an hour sooner.', capacity: 18, deadline: 2, prices: [60,60,35,20,20,15]},
  {id: 'impossible', title: 'Not enough power', icon: '05', hint: 'Learn why an honest “no plan” is useful.', capacity: 10, deadline: 3, prices: [60,60,35,20,20,15]}
]);
export function makeFixture(id = 'evening', overrides = {}) {
  const p = PRESETS.find(x => x.id === id);
  if (!p) throw new Error('Unknown scenario.');
  if (Object.keys(overrides).some(k => !['capacity_kw','deadline'].includes(k))) throw new Error('Unsupported scenario override.');
  const capacity = overrides.capacity_kw ?? p.capacity, deadline = overrides.deadline ?? p.deadline;
  if (!Number.isInteger(capacity) || capacity < 10 || capacity > 26 || ![2,3,4].includes(deadline)) throw new Error('Choose a site limit of 10–26 kW and a departure of 19:00–21:00.');
  return validateFixture({id: 'energyflex-' + id, version: 1, scope: 'Synthetic six-hour scheduling fixture; not a field result.',
    currency: 'AUD', slot_hours: 1, slot_labels: ['17:00','18:00','19:00','20:00','21:00','22:00'],
    prices_cents_per_kwh: [...p.prices], base_load_kw: [4,5,4,3,3,3], capacity_kw: capacity,
    tasks: ['A','B','C'].map((v,i) => ({id: 'EV-' + v, power_kw: 7, grid_energy_kwh: 14, release_slot: 0, deadline_slot_exclusive: [deadline,5,6][i]}))});
}
const blank = f => Object.fromEntries(f.tasks.map(t => [t.id, []]));
const order = f => [...f.tasks].sort((a,b) => a.deadline_slot_exclusive - b.deadline_slot_exclusive || a.id.localeCompare(b.id));
export function earliestFirst(f) {
  validateFixture(f); const plan = blank(f);
  for (let s = 0; s < f.slot_labels.length; s++) {
    let load = f.base_load_kw[s];
    for (const t of order(f)) if (s >= t.release_slot && s < t.deadline_slot_exclusive && plan[t.id].length * t.power_kw < t.grid_energy_kwh && load + t.power_kw <= f.capacity_kw) {
      plan[t.id].push(s); load += t.power_kw;
    }
  }
  return plan;
}
export function tariffGreedy(f) {
  validateFixture(f); const plan = blank(f), loads = [...f.base_load_kw];
  for (const t of order(f)) {
    const slots = Array.from({length:t.deadline_slot_exclusive-t.release_slot},(_,i)=>i+t.release_slot).sort((a,b)=>f.prices_cents_per_kwh[a]-f.prices_cents_per_kwh[b] || a-b);
    for (const s of slots) if (plan[t.id].length * t.power_kw < t.grid_energy_kwh && loads[s] + t.power_kw <= f.capacity_kw) { plan[t.id].push(s); loads[s] += t.power_kw; }
    plan[t.id].sort((a,b)=>a-b);
  }
  return plan;
}
function combinations(start, end, count) {
  const out = [];
  function visit(at, picks) {
    if (picks.length === count) { out.push([...picks]); return; }
    for (let i = at; i <= end - (count-picks.length); i++) { picks.push(i); visit(i+1,picks); picks.pop(); }
  }
  visit(start,[]); return out;
}
export function exactPlan(f) {
  validateFixture(f);
  const options = f.tasks.map(t => combinations(t.release_slot,t.deadline_slot_exclusive,t.grid_energy_kwh/t.power_kw));
  const size = options.reduce((a,v)=>a*v.length,1);
  if (size > 200000) throw new Error('Scenario exceeds the bounded demo search budget.');
  let best = null, bestCost = Infinity, evaluated = 0, feasible = 0;
  const picked = [];
  function visit(i) {
    if (i < options.length) { for (const choice of options[i]) { picked[i]=choice; visit(i+1); } return; }
    evaluated++;
    // Independent of checkPlan: enumerate all assignments, enforce site capacity,
    // and compare exact integer-cent objectives. Options encode energy/windows.
    const loads = [...f.base_load_kw]; let cost = 0;
    f.tasks.forEach((t,j) => { for (const s of picked[j]) { loads[s]+=t.power_kw; cost+=t.power_kw*f.prices_cents_per_kwh[s]; } });
    if (loads.some(x=>x>f.capacity_kw)) return;
    feasible++;
    if (cost < bestCost) { bestCost=cost; best=Object.fromEntries(f.tasks.map((t,j)=>[t.id,[...picked[j]]])); }
  }
  visit(0);
  return {plan:best, candidate_assignments:evaluated, feasible_assignments:feasible, complete:true};
}
export function compare(f) {
  validateFixture(f);
  const exact = exactPlan(f), plans = {earliest:earliestFirst(f), tariff:tariffGreedy(f), optimal:exact.plan};
  const strategies = Object.fromEntries(Object.entries(plans).map(([key,plan])=>[key,{plan,verification:plan ? checkPlan(f,plan) : null}]));
  const first = strategies.earliest.verification, optimal = strategies.optimal.verification;
  const comparable = Boolean(first?.passed && optimal?.passed);
  const saving = comparable ? first.metrics.total_variable_energy_cost_cents-optimal.metrics.total_variable_energy_cost_cents : null;
  return {strategies, search:{candidate_assignments:exact.candidate_assignments,feasible_assignments:exact.feasible_assignments,complete:exact.complete},
    comparison:{comparable,saving_cents:saving,saving_basis_points:comparable && first.metrics.total_variable_energy_cost_cents > 0 ? Math.round(10000*saving/first.metrics.total_variable_energy_cost_cents) : null,
      tariff_matches_optimum:Boolean(optimal?.passed && strategies.tariff.verification.passed && strategies.tariff.verification.metrics.total_variable_energy_cost_cents===optimal.metrics.total_variable_energy_cost_cents)}};
}
export function infeasibleExplanation(f) {
  const required=f.tasks.reduce((a,t)=>a+t.grid_energy_kwh,0);
  const upper=f.base_load_kw.reduce((a,b)=>a+Math.max(0,f.capacity_kw-b),0);
  return upper<required ? `Only ${upper} kWh of headroom is available, but the vehicles need ${required} kWh. No schedule can make that energy fit.` : 'No assignment meets every departure, energy requirement and site limit in this hourly on/off charging model. A different charger model or more capacity may change the result.';
}
export function evidencePayload(f,result) {
  return {schema:VERSION,execution:'browser-local-reference',fixture:f,result,
    scope:'Synthetic discrete model. No live devices, ECAI-native retrieval, LLM call, or DamageBDD backend run. SHA-256 is a checksum, not a signature.'};
}
export async function makeEvidence(f,result) {
  // Recompute rather than serialize an arbitrary caller-supplied outcome.
  const fresh=compare(f);
  if (canonical(fresh)!==canonical(result)) throw new Error('Results are stale. Run the comparison again before exporting.');
  const payload=JSON.parse(JSON.stringify(evidencePayload(f,fresh)));
  if (!globalThis.crypto?.subtle) throw new Error('Evidence export needs HTTPS or localhost. The demo itself still works.');
  const digest=await globalThis.crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical(payload)));
  return {...payload,integrity:{algorithm:'SHA-256',canonicalization:'sorted-keys-compact-json-v1',sha256:Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('')}};
}
