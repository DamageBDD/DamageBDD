import {test} from 'node:test';
import assert from 'node:assert/strict';
import {nextHandoverStep} from '../../priv/static/js/node-bunker.js';

const NOW = 1800000000;
const BASELINE = '10000000-0000-4000-8000-000000000001';
const TESTED = '20000000-0000-4000-8000-000000000002';
const TARGET = 'a'.repeat(64);
const FINGERPRINT = 'b'.repeat(64);
const NEXT_FINGERPRINT = 'c'.repeat(64);
const PENDING_HASH = 'd'.repeat(64);
const VERIFY_HASH = 'e'.repeat(64);
const required = ['current_controls', 'live_signing', 'cold_restart', 'backup_restore', 'version_promotion'];

function tasks(overrides = {}) {
  return [...required, 'operator_acceptance'].map(id => ({
    id, status: overrides[id] || (id === 'current_controls' ? 'passed' : 'not_checked'),
    next_action: 'Complete the recorded requirement.'
  }));
}
function report(extra = {}) {
  return {status:'passed', started_at:NOW - 30, completed_at:NOW - 20,
    target:TARGET, fingerprint:FINGERPRINT, runtime_instance:'runtime-before',
    active_secret_version:BASELINE, ...extra};
}
function verification(extra = {}) {
  return report({sha256:VERIFY_HASH, action:'verify',
    exchanges:Array.from({length:5}, () => ({status:'passed'})),
    policy_checks:[{status:'passed'}, {status:'passed'}], ...extra});
}
function fresh() {
  const health = report({started_at:NOW - 3, completed_at:NOW - 2,
    checks:[{id:'service_ready',status:'passed'}, {id:'relays_subscribed',status:'passed'}],
    setup:{aws:{region:'ap-southeast-2',expected_account_id:'123456789012',
      expected_role_name:'bunker-runtime',secret_id:'/test/bunker'}}});
  return {busy:false,last_error:null,closure:'outstanding',handover_status:'not_accepted',
    health_stale:false,health,evidence:{health},closure_tasks:tasks()};
}
function signed() {
  const data = fresh();
  data.evidence.verify = verification();
  data.closure_tasks = tasks({live_signing:'passed'});
  return data;
}
function rehearsed() {
  const data = signed();
  data.evidence.pending = report({action:'pending',sha256:PENDING_HASH,
    recovery:{secret_provenance:{baseline_version_id:BASELINE,version_id:TESTED}}});
  data.closure_tasks = tasks({live_signing:'passed',version_promotion:'blocked'});
  return data;
}
function restored(version = TESTED) {
  const data = rehearsed();
  data.evidence.recovery = report({action:'recovery',started_at:NOW - 15,completed_at:NOW - 10,
    recovery:{backup_restored:true,wrong_unlock_rejected:true,metadata_restore:{restored:true},
      secret_provenance:{version_id:version}}});
  data.closure_tasks = tasks({live_signing:'passed',backup_restore:'passed',version_promotion:'blocked'});
  return data;
}
function restarted() {
  const data = restored();
  data.evidence.restart = verification({action:'restart',sha256:'f'.repeat(64),started_at:NOW - 8,
    completed_at:NOW - 5,restarted:true,fingerprint:NEXT_FINGERPRINT,
    runtime_instance:'runtime-after',active_secret_version:TESTED});
  data.evidence.verify = {...data.evidence.restart};
  data.health.fingerprint = NEXT_FINGERPRINT;
  data.health.runtime_instance = 'runtime-after';
  data.health.active_secret_version = TESTED;
  data.closure_tasks = tasks(Object.fromEntries(required.map(id => [id,'passed'])));
  data.closure = 'awaiting_acceptance';
  return data;
}
const step = (data, context = {}) => nextHandoverStep(data, context, NOW);
const action = result => `${result.kind}:${result.action || ''}`;
const notPending = result => assert.notEqual(action(result), 'run:pending', 'Do not overwrite pending rehearsal after promotion');

// These tests assert the operator-visible transition and authoritative evidence
// boundary, rather than duplicating the planner's internal branching.
test('initial and unavailable observations cannot start AWS maintenance', () => {
  for (const value of [null, undefined, {}]) {
    const result = step(value);
    assert.ok(['refresh','run','none'].includes(result.kind));
    if (result.kind === 'run') assert.equal(result.action, 'health');
  }
  const data = rehearsed();
  const disconnected = step(data, {loadFailed:true});
  assert.equal(disconnected.kind, 'refresh');
  for (const context of [{loading:true}]) assert.equal(step(data, context).kind, 'none');
  data.busy = true;
  assert.equal(step(data).kind, 'none');
  data.busy = false; data.last_error = 'evidence_write_failed';
  assert.ok(['guide','refresh','run','none'].includes(step(data).kind));
  assert.notEqual(step(data).action, 'accept');
  assert.notEqual(step(data).kind, 'copy');
});

test('health and signing preparation precede the administrator session', () => {
  const data = fresh();
  assert.equal(action(step(data)), 'run:verify');
  data.health.completed_at = NOW - 61;
  data.health_stale = true;
  const stale = step(data);
  assert.ok(['run:health','run:verify'].includes(action(stale)), 'A verification action can reassess stale controls');
  data.health.status = 'failed'; data.health.completed_at = NOW - 1; data.health_stale = false;
  data.health.checks[1] = {id:'relays_subscribed',status:'failed',next_action:'Reduce configured relays to at most six.'};
  const failed = step(data);
  assert.ok(['guide','run'].includes(failed.kind));
  if (failed.kind === 'run') assert.equal(failed.action, 'health');
  assert.match(`${failed.description} ${failed.help || ''}`, /relay|setup|control/i);
});

test('copy hints guide checks but never create evidence or green completion', () => {
  const data = signed(), before = JSON.stringify(data);
  const prepare = step(data);
  assert.equal(action(prepare), 'copy:pending');
  assert.notEqual(prepare.status, 'passed');
  const afterCopy = step(data, {preparedFor:TARGET});
  assert.equal(action(afterCopy), 'run:pending');
  assert.notEqual(afterCopy.status, 'passed');
  assert.equal(action(step(data, {preparedFor:'another-target'})), 'copy:pending');
  assert.equal(JSON.stringify(data), before, 'Navigation must not manufacture or mutate recorded evidence');
});

test('unrelated failed recovery or restart without version evidence does not block preparation', () => {
  const data = signed();
  data.evidence.recovery = {status:'failed',completed_at:NOW - 2,reason:'prerequisites_failed'};
  data.evidence.restart = {status:'failed',completed_at:NOW - 2,reason:'prerequisites_failed'};
  assert.equal(action(step(data)), 'copy:pending');
});

test('pending rehearsal enables exact-version promotion and then a real restore check', () => {
  const data = rehearsed(), before = JSON.stringify(data);
  assert.equal(action(step(data)), 'copy:promote');
  assert.equal(action(step(data, {promotedFor:PENDING_HASH})), 'run:recovery');
  assert.equal(action(step(data, {promotedFor:'another-report'})), 'copy:promote');
  assert.equal(JSON.stringify(data), before);
  data.health.completed_at = NOW - 61; data.health_stale = true;
  assert.equal(action(step(data)), 'run:health', 'Refresh health before copying promotion commands');
});

test('a passed restore or restart of the old current version cannot skip promotion', () => {
  const data = restored(BASELINE);
  data.evidence.restart = verification({action:'restart',restarted:true});
  data.closure_tasks.find(t => t.id === 'cold_restart').status = 'passed';
  const result = step(data);
  assert.notEqual(result.action, 'restart');
  assert.notEqual(result.action, 'accept');
  assert.notEqual(result.kind, 'export');
  assert.ok(['copy:promote','run:recovery'].includes(action(result)));
});

test('matching current restore leads directly to restart even when signing is stale', () => {
  const data = restored();
  data.evidence.verify.completed_at = NOW - 901;
  data.closure_tasks.find(t => t.id === 'live_signing').status = 'stale';
  assert.equal(action(step(data)), 'run:restart', 'Restart refreshes signing itself');
  data.evidence.recovery.started_at = data.evidence.pending.completed_at - 1;
  assert.notEqual(step(data).action, 'restart', 'Restore must follow the tested pending rehearsal');
});

test('expected fingerprint changes across restart preserve valid pending evidence', () => {
  const data = restarted();
  assert.notEqual(data.evidence.pending.fingerprint, data.health.fingerprint);
  const result = step(data);
  notPending(result);
  assert.equal(result.kind, 'guide');
  assert.match(`${result.action} ${result.help || ''} ${result.title}`, /accept/i);
  data.health.completed_at = NOW - 61; data.health_stale = true;
  data.closure = 'outstanding';
  data.closure_tasks.find(t => t.id === 'current_controls').status = 'stale';
  const stale = step(data);
  notPending(stale);
  assert.equal(stale.kind, 'guide', 'Final acceptance refreshes health before submitting');
  assert.match(`${stale.action} ${stale.help || ''} ${stale.title}`, /accept/i);
});

test('expired or replaced rehearsal evidence after observed promotion needs reconciliation', () => {
  const expired = restored();
  expired.evidence.pending.completed_at = NOW - 86401;
  const replaced = restored();
  replaced.evidence.pending = {status:'failed',completed_at:NOW - 2,reason:'not_distinct'};
  const sameVersion = rehearsed();
  sameVersion.evidence.pending.status = 'failed';
  sameVersion.evidence.pending.recovery.secret_provenance.baseline_version_id = TESTED;
  for (const data of [expired, replaced, sameVersion]) {
    const result = step(data);
    notPending(result);
    assert.notEqual(action(result), 'copy:pending');
    assert.notEqual(action(result), 'copy:promote');
    assert.ok(['guide','none'].includes(result.kind));
    assert.match(`${result.id} ${result.title} ${result.description}`, /reconcil|evidence|version|review/i);
  }
});

test('recorded acceptance remains exportable without presenting stale health as current acceptance', () => {
  const data = restarted();
  data.acceptance = {actor:'node-admin-test',report_sha256:data.evidence.verify.sha256};
  data.handover_status = 'accepted'; data.closure = 'accepted';
  assert.equal(step(data).kind, 'export');
  data.closure = 'outstanding'; data.health.completed_at = NOW - 400;
  const historical = step(data);
  assert.equal(historical.kind, 'export');
  assert.notEqual(historical.status, 'accepted');
  assert.match(`${historical.description} ${historical.title}`, /record|histor|current/i);
});

test('incomplete server task data never implies acceptance eligibility', () => {
  for (const closureTasks of [undefined, null, [], 'passed', [{id:'live_signing',status:'passed'}]]) {
    const data = restarted(); data.closure = 'outstanding'; data.closure_tasks = closureTasks;
    const result = step(data);
    assert.notEqual(result.action, 'accept');
    assert.notEqual(result.kind, 'export');
    assert.ok(!/acceptance-ready|ready-to-accept/.test(result.id || ''));
  }
});
