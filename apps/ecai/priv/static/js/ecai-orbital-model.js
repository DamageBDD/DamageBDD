/**
 * OTV-001: reproducible SYNTHETIC reservoir-transfer verification fixtures.
 * Not a Starship model, not a cryogenic flow solver and not flight telemetry.
 * Every threshold below is an illustrative dimensionless benchmark setting.
 */
import {sha256Hex} from './ecai-math-3d.js';

export const OTV_VERSION = 'otv-001-demo-v1';
export const OTV_RULES = Object.freeze({
  mass_balance: {name:'Conservation', unit:'mass units', bound:0.08},
  closed_valve_flow: {name:'Command / flow agreement', unit:'mass units/step', bound:0.018},
  thermal_envelope: {name:'Thermal envelope', unit:'index', bound:0.78},
  pressure_envelope: {name:'Pressure envelope', unit:'index', bound:0.76},
  sensor_agreement: {name:'Redundant sensor agreement', unit:'mass units', bound:0.23},
  monotonic_time: {name:'Event ordering', unit:'steps', bound:0}
});
export const OTV_SCENARIOS = Object.freeze({
  nominal: {label:'Nominal transfer', description:'Conservative reference with no injected violation', injected:[]},
  leak: {label:'Unaccounted transfer loss', description:'A portion of outgoing mass does not reach the receiving reservoir', injected:['mass_balance']},
  'valve-stuck': {label:'Valve command mismatch', description:'Measured flow persists after a close command', injected:['closed_valve_flow']},
  thermal: {label:'Thermal excursion', description:'Synthetic thermal index exceeds its illustrative envelope', injected:['thermal_envelope']},
  pressure: {label:'Pressure excursion', description:'Synthetic pressure index exceeds its illustrative envelope', injected:['pressure_envelope']},
  'sensor-drift': {label:'Sensor drift', description:'One receiving-tank sensor increasingly disagrees with a redundant sensor', injected:['mass_balance','sensor_agreement']},
  'event-reorder': {label:'Out-of-order telemetry', description:'Two sequential telemetry records arrive in reversed order', injected:['monotonic_time']}
});
const R = v => Math.round(v*1e6)/1e6;
const assertScenario = scenario => { if (!Object.hasOwn(OTV_SCENARIOS,scenario)) throw new RangeError('Unknown synthetic scenario'); };
const assertSeed = seed => { if (!Number.isSafeInteger(seed)||seed<0||seed>999999999) throw new RangeError('Seed must be an integer from 0 to 999999999'); };

export function simulateTransfer({scenario='nominal',seed=1729}={}) {
  assertScenario(scenario);assertSeed(seed);
  let source=100,receiver=12,accountedLoss=0;
  const trace=[];
  for(let step=0;step<96;step++) {
    const commandOpen=step>=12&&step<78;
    const actualOpen=commandOpen||(scenario==='valve-stuck'&&step>=78&&step<89);
    const modulation=(seed%101)/101;
    const flow=actualOpen ? R(0.14+0.032*Math.sin(step*0.27+modulation)) : 0;
    if(actualOpen){source=R(source-flow);receiver=R(receiver+flow*(scenario==='leak'&&step>=38&&step<65?0.66:1));}
    const drift=scenario==='sensor-drift'&&step>=43?R((step-42)*0.013):0;
    const measured=R(receiver+drift);
    let thermal=0.35+0.055*Math.sin(step*0.095+modulation);
    let pressure=0.43+0.06*Math.sin(step*0.08+modulation);
    if(scenario==='thermal'&&step>=39)thermal+=Math.min(0.58,(step-38)*0.016);
    if(scenario==='pressure'&&step>=45)pressure+=Math.min(0.53,(step-44)*0.017);
    const redundant=R(receiver+0.008*Math.sin(step*0.33+modulation));
    trace.push({
      step, event_id:`otv-${String(step).padStart(3,'0')}`,timestamp:step,
      command_open:commandOpen,actual_open:actualOpen,flow,
      source_mass:R(source),receiver_mass:R(receiver),receiver_reported:measured,
      receiver_redundant:redundant,accounted_loss:accountedLoss,
      thermal_index:R(thermal),pressure_index:R(pressure),
      mass_residual:R(Math.abs(112-(source+measured+accountedLoss)))
    });
  }
  if(scenario==='event-reorder') [trace[55],trace[56]]=[trace[56],trace[55]];
  return {benchmark:'OTV-001',generator:OTV_VERSION,simulation_type:'dimensionless_synthetic_two_reservoir',scenario,seed,initial:{source:100,receiver:12},trace};
}

export function evaluateTransfer(data) {
  if(!data || !Array.isArray(data.trace) || !data.trace.length || data.trace.length>1024) throw new TypeError('Expected a bounded synthetic trace');
  const earliest=new Map();const counts=Object.fromEntries(Object.keys(OTV_RULES).map(id=>[id,0]));
  let prevTime=-Infinity, peakResidual=0;
  const initialTotal=data.initial.source+data.initial.receiver;
  for(const sample of data.trace) {
    const residual=R(Math.abs(initialTotal-(sample.source_mass+sample.receiver_reported+sample.accounted_loss)));
    peakResidual=Math.max(peakResidual,residual);
    const observations=[
      ['mass_balance',residual,OTV_RULES.mass_balance.bound,residual>OTV_RULES.mass_balance.bound],
      ['closed_valve_flow',sample.flow,OTV_RULES.closed_valve_flow.bound, !sample.command_open&&sample.flow>OTV_RULES.closed_valve_flow.bound],
      ['thermal_envelope',sample.thermal_index,OTV_RULES.thermal_envelope.bound,sample.thermal_index>OTV_RULES.thermal_envelope.bound],
      ['pressure_envelope',sample.pressure_index,OTV_RULES.pressure_envelope.bound,sample.pressure_index>OTV_RULES.pressure_envelope.bound],
      ['sensor_agreement',R(Math.abs(sample.receiver_reported-sample.receiver_redundant)),OTV_RULES.sensor_agreement.bound,Math.abs(sample.receiver_reported-sample.receiver_redundant)>OTV_RULES.sensor_agreement.bound],
      ['monotonic_time',sample.timestamp-prevTime,0,sample.timestamp<=prevTime]
    ];
    for(const [rule,observed,bound,failed] of observations){
      if(failed){counts[rule]++;if(!earliest.has(rule))earliest.set(rule,{rule,name:OTV_RULES[rule].name,step:sample.step,observed:R(observed),bound});}
    }
    prevTime=sample.timestamp;
  }
  const violations=[...earliest.values()].sort((a,b)=>a.step-b.step||a.rule.localeCompare(b.rule));
  const firstViolation=violations.length?Math.min(...violations.map(v=>v.step)):null;
  return {
    ...data,
    result:{status:violations.length?'FAIL':'PASS',checks:Object.keys(OTV_RULES).length,
      violations,violation_counts:counts,first_violation_step:firstViolation,
      peak_mass_residual:R(peakResidual),
      failed_invariant_count:violations.length}
  };
}

/** A deliberately simple local reference lookup, NOT native ECAI curve retrieval. */
const PATTERN_ATLAS=[
  {id:'OTV-REF-01',title:'Unaccounted conservation delta',rules:['mass_balance'],hypothesis:'Inspect transfer accounting or unobserved losses'},
  {id:'OTV-REF-02',title:'Valve/flow contradiction',rules:['closed_valve_flow'],hypothesis:'Compare commanded transitions with independent flow readings'},
  {id:'OTV-REF-03',title:'Thermal limit excursion',rules:['thermal_envelope'],hypothesis:'Check model-defined temperature-index bound'},
  {id:'OTV-REF-04',title:'Pressure limit excursion',rules:['pressure_envelope'],hypothesis:'Check model-defined pressure-index bound'},
  {id:'OTV-REF-05',title:'Sensor bias or drift',rules:['sensor_agreement','mass_balance'],hypothesis:'Compare redundant instruments before classifying a leak'},
  {id:'OTV-REF-06',title:'Telemetry reordering',rules:['monotonic_time'],hypothesis:'Check transport ordering and idempotent replay'}
];
export function findReferencePatterns(result,limit=2) {
  const faults=new Set(result?.violations?.map(x=>x.rule)||[]);
  if(!faults.size)return [];
  return PATTERN_ATLAS.map(pattern=>{
    const intersection=pattern.rules.filter(rule=>faults.has(rule)).length;
    const union=new Set([...pattern.rules,...faults]).size;
    return {...pattern,similarity:R(intersection/union)};
  }).filter(x=>x.similarity>0).sort((a,b)=>b.similarity-a.similarity||a.id.localeCompare(b.id)).slice(0,limit);
}

export async function makeEvidence(evaluated) {
  if(!evaluated?.result||!OTV_SCENARIOS[evaluated.scenario])throw new TypeError('Evaluated OTV-001 fixture required');
  const evidence={
    schema:'otv-001-evidence-v1',benchmark:evaluated.benchmark,
    generator:evaluated.generator,scenario:evaluated.scenario,seed:evaluated.seed,
    scope:{synthetic:true,spaceflight_validated:false,fluid_dynamics_validated:false,
      native_ecai_retrieval:false,damagebdd_execution:false,independent_node_attestations:0,
      signed_by_operator:false},
    invariant_definitions:OTV_RULES,initial:evaluated.initial,trace:evaluated.trace,
    result:evaluated.result
  };
  const json=JSON.stringify(evidence);
  return {evidence,sha256:await sha256Hex(json),bytes:new TextEncoder().encode(json).byteLength};
}

export function featureBlueprint(scenario,seed=1729) {
  assertScenario(scenario);assertSeed(seed);
  return `# OTV-001 synthetic benchmark; this is a proposed DamageBDD adapter specification.\n# Do not claim these steps are registered or executed until a server-side bridge exists.\n@otv @synthetic @research\nFeature: Independently reproduce transfer verification for ${scenario}\n  Scenario: Replay a seeded fixture and inspect its invariants\n    Given the OTV-001 synthetic fixture "${scenario}" with seed ${seed}\n    When DamageBDD executes all OTV-001 verification rules\n    Then the result matches the versioned benchmark expectation\n    And the full trace and integrity digest are available for independent replay\n`;
}
