import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createHash} from 'node:crypto';
import {OTV_SCENARIOS, OTV_RULES, simulateTransfer, evaluateTransfer, makeEvidence, findReferencePatterns, featureBlueprint} from '../../priv/static/js/ecai-orbital-model.js';
import {verifyEvidence} from '../../tools/verify_otv_evidence.mjs';
import {readFileSync} from 'node:fs';

test('every scenario is deterministic and has bounded finite mass/sensor indices',()=>{
  for(const scenario of Object.keys(OTV_SCENARIOS)){
    const a=simulateTransfer({scenario,seed:1729}),b=simulateTransfer({scenario,seed:1729});
    assert.deepEqual(a,b);
    assert.equal(a.trace.length,96);
    assert.ok(a.trace.every(t=>t.source_mass>0&&t.receiver_mass>0&&Number.isFinite(t.thermal_index)&&Number.isFinite(t.pressure_index)));
  }
});
test('nominal scenario passes six illustrative invariants',()=>{
  const {result}=evaluateTransfer(simulateTransfer({scenario:'nominal'}));
  assert.equal(result.status,'PASS');assert.equal(result.checks,6);assert.equal(result.violations.length,0);
});
test('each fault scenario detects expected invariant violation',()=>{
  for(const [scenario,config] of Object.entries(OTV_SCENARIOS)){
    if(scenario==='nominal')continue;
    const {result}=evaluateTransfer(simulateTransfer({scenario}));
    const found=result.violations.map(x=>x.rule);
    for(const rule of config.injected)assert.ok(found.includes(rule),`${scenario}: missing ${rule}; got ${found.join(',')}`);
    assert.equal(result.status,'FAIL');
    assert.ok(result.first_violation_step>=0&&result.first_violation_step<96);
  }
});
test('anomalies have references but native ECAI is not asserted',()=>{
  assert.deepEqual(findReferencePatterns(evaluateTransfer(simulateTransfer({scenario:'nominal'})).result),[]);
  const refs=findReferencePatterns(evaluateTransfer(simulateTransfer({scenario:'sensor-drift'})).result);
  assert.equal(refs[0].id,'OTV-REF-05');assert.ok(refs[0].similarity>0.9);
});
test('evidence SHA-256 is reproducible, content-bound and explicitly non-attested',async()=>{
  const fixture=evaluateTransfer(simulateTransfer({scenario:'leak',seed:7}));
  const one=await makeEvidence(fixture),two=await makeEvidence(evaluateTransfer(simulateTransfer({scenario:'leak',seed:7})));
  assert.deepEqual(one,two);
  assert.equal(one.sha256,createHash('sha256').update(JSON.stringify(one.evidence)).digest('hex'));
  assert.equal(one.evidence.scope.spaceflight_validated,false);
  assert.equal(one.evidence.scope.native_ecai_retrieval,false);
  assert.equal(one.evidence.scope.damagebdd_execution,false);
  assert.equal(one.evidence.scope.independent_node_attestations,0);
  assert.notEqual(one.sha256,(await makeEvidence(evaluateTransfer(simulateTransfer({scenario:'leak',seed:8})))).sha256);
});
test('invalid fixtures, unbounded seeds and fake scenarios are rejected',()=>{
  for(const seed of [-1,1e12,2.5,NaN,Infinity])assert.throws(()=>simulateTransfer({seed}));
  assert.throws(()=>simulateTransfer({scenario:'../../etc/passwd'}));
  assert.throws(()=>evaluateTransfer({trace:Array(2000).fill({})}));
  assert.throws(()=>featureBlueprint('evil'));
  assert.equal(Object.keys(OTV_RULES).length,6);
});

test('portable process verifier accepts matching synthetic trace, rejects mutation',async()=>{
  const receipt=await makeEvidence(evaluateTransfer(simulateTransfer({scenario:'leak',seed:4})));
  const obj={sha256:receipt.sha256,...receipt.evidence};
  assert.equal(verifyEvidence(obj).status,'PASS');
  const tampered=structuredClone(obj);tampered.trace[45].source_mass=12;
  assert.throws(()=>verifyEvidence(tampered),/SHA-256 mismatch/);
  assert.ok(featureBlueprint('leak',4).includes('seed 4'));
});
test('native ECAI console routes are wired to the OTV-001 panel',()=>{
  const template=readFileSync(new URL('../../priv/templates/ui/dashboard/ecai_console.mustache',import.meta.url),'utf8');
  const consoleJs=readFileSync(new URL('../../priv/static/js/ecai-console.js',import.meta.url),'utf8');
  const applications=template.split('id="navApplicationsLabel"')[1].split('<details class="sidebar-tools"')[0];
  assert.match(applications,/data-view="orbital"/);
  assert.match(applications,/data-view="supply-chain"/);
  assert.match(template,/PUBLIC · NO SIGN-IN/);
  assert.match(template,/data-panel="orbital"/);
  assert.match(template,/ecai-orbital\.css/);
  assert.match(consoleJs,/orbital\?\.setVisible\(view === "orbital"\)/);
  assert.match(consoleJs,/initOrbitalVerification/);
  assert.match(consoleJs,/orbital\?\.dispose\(\)/);
});
