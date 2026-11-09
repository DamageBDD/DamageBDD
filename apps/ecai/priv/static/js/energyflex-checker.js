/** EnergyFlex v1: pure, bounded constraint checker. No DOM, network, or authority. */
export const VERSION = 'energyflex-v1';
const integer = (n, lo, hi) => Number.isSafeInteger(n) && n >= lo && n <= hi;
export function validateFixture(f) {
  if (!f || typeof f !== 'object' || Array.isArray(f)) throw new Error('Missing scenario.');
  const n = f.slot_labels?.length;
  if (!integer(n, 1, 8) || f.slot_hours !== 1 || f.currency !== 'AUD') throw new Error('Only 1–8 hourly AUD slots are supported.');
  if (!f.slot_labels.every(x => typeof x === 'string' && x.length <= 16)) throw new Error('Invalid time labels.');
  if (!Array.isArray(f.prices_cents_per_kwh) || f.prices_cents_per_kwh.length !== n || !f.prices_cents_per_kwh.every(x => integer(x, 0, 500))) throw new Error('Tariffs must be integer cents/kWh in 0–500.');
  if (!Array.isArray(f.base_load_kw) || f.base_load_kw.length !== n || !f.base_load_kw.every(x => integer(x, 0, 50))) throw new Error('Invalid building demand.');
  if (!integer(f.capacity_kw, 1, 100) || !Array.isArray(f.tasks) || !integer(f.tasks.length, 1, 4)) throw new Error('Invalid capacity or fleet size.');
  const ids = new Set();
  for (const t of f.tasks) {
    if (!t || typeof t.id !== 'string' || !/^EV-[A-D]$/.test(t.id) || ids.has(t.id)) throw new Error('Invalid or repeated vehicle ID.');
    ids.add(t.id);
    if (!integer(t.power_kw, 1, 22) || !integer(t.grid_energy_kwh, 1, 176) || t.grid_energy_kwh % t.power_kw !== 0) throw new Error('Energy must be a whole number of charging hours.');
    if (!integer(t.release_slot, 0, n - 1) || !integer(t.deadline_slot_exclusive, t.release_slot + 1, n)) throw new Error('Invalid arrival/departure window.');
  }
  return f;
}

/** Recalculate from raw schedule; never trusts producer metrics or pass flags. */
export function checkPlan(f, plan) {
  validateFixture(f);
  const failures = [], n = f.slot_labels.length, loads = [...f.base_load_kw];
  const add = (rule, message) => failures.push({rule, message});
  const record = plan && typeof plan === 'object' && !Array.isArray(plan);
  const keys = record ? Object.keys(plan).sort() : [];
  if (!record || JSON.stringify(keys) !== JSON.stringify(f.tasks.map(t => t.id).sort())) add('vehicles', 'The plan must include exactly the declared vehicles.');
  let chargingEnergy = 0, chargingCost = 0, completeVehicles = 0;
  const delivered = {};
  for (const t of f.tasks) {
    let slots = record && Object.prototype.hasOwnProperty.call(plan, t.id) ? plan[t.id] : null;
    if (!Array.isArray(slots) || slots.length > n || slots.some(s => !integer(s, 0, n - 1))) {
      add('slots', `${t.id}: charging slots must be valid integer hours.`); slots = [];
    }
    if (new Set(slots).size !== slots.length) add('unique', `${t.id}: the same charging hour is counted twice.`);
    // Duplicate or out-of-window slots never inflate delivered service.
    const valid = [...new Set(slots)].filter(s => s >= t.release_slot && s < t.deadline_slot_exclusive);
    if (valid.length !== new Set(slots).size) add('windows', `${t.id}: charging occurs outside its arrival/departure window.`);
    delivered[t.id] = valid.length * t.power_kw;
    if (delivered[t.id] !== t.grid_energy_kwh) add('energy', `${t.id}: ${delivered[t.id]} of ${t.grid_energy_kwh} kWh delivered before departure.`);
    else completeVehicles++;
    for (const s of new Set(slots)) { loads[s] += t.power_kw; chargingEnergy += t.power_kw; chargingCost += t.power_kw * f.prices_cents_per_kwh[s]; }
  }
  for (let s = 0; s < n; s++) if (loads[s] > f.capacity_kw) add('capacity', `${f.slot_labels[s]}: ${loads[s]} kW exceeds the ${f.capacity_kw} kW site limit.`);
  const baseCost = f.base_load_kw.reduce((a, kw, s) => a + kw * f.prices_cents_per_kwh[s], 0);
  const labels = [
    ['vehicles', 'Every vehicle is accounted for'], ['slots', 'All hours are inside the horizon'],
    ['unique', 'No hour is counted twice'], ['windows', 'Arrival and departure windows respected'],
    ['energy', 'Required energy delivered on time'], ['capacity', 'Site limit respected at every hour']
  ];
  return {
    passed: failures.length === 0, failures,
    checks: labels.map(([id, label]) => ({id, label, passed: !failures.some(v => v.rule === id)})),
    metrics: {charging_energy_kwh: chargingEnergy, charging_cost_cents: chargingCost,
      base_cost_cents: baseCost, total_variable_energy_cost_cents: chargingCost + baseCost,
      peak_kw: Math.max(...loads), load_kw_by_slot: loads, delivered_by_vehicle: delivered,
      complete_vehicles: completeVehicles, required_energy_kwh: f.tasks.reduce((a, t) => a + t.grid_energy_kwh, 0)}
  };
}

export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
}
