import test from 'node:test';
import assert from 'node:assert/strict';
import {stateLabel, costLabel, canApprove, reportPath, previewPayload, friendlyError}
  from '../../priv/static/js/verification.js';

test('an estimate is not presented as a passed verification', () => {
  assert.equal(stateLabel({mode:'preview',state:'ready'}), 'Ready for approval');
  assert.equal(stateLabel({mode:'preview',state:'running'}), 'Preparing estimate');
  assert.equal(stateLabel({mode:'execute',state:'passed'}), 'Checks passed');
  assert.equal(stateLabel({state:'indeterminate'}), 'Outcome unconfirmed');
});
test('approval binds the exact feature, state, expiry and single-use quote', () => {
  const feature={sha256:'same'},job={mode:'preview',state:'ready',sha256:'same',approval_expires_at:200};
  assert.equal(canApprove(job,feature,100000),true);
  assert.equal(canApprove({...job,approved_job:'already-used'},feature,100000),false);
  assert.equal(canApprove(job,{sha256:'changed'},100000),false);
  assert.equal(canApprove(job,feature,200000),false);
  assert.equal(canApprove({...job,state:'passed'},feature,100000),false);
});
test('only editable fields enter a request; protected fields cannot be injected', () => {
  const f={id:'f',sha256:'h',fields:[
    {key:'input_limit',editable:true,configured:false},
    {key:'secret_key',editable:false,configured:true,sensitive:true},
    {key:'public_key',editable:false,configured:true},
    {key:'input_default',editable:true,configured:true}]};
  assert.deepEqual(previewPayload(f,{input_limit:'100',secret_key:'no',public_key:'attacker',extra:'no'},'request'),
    {feature_id:'f',sha256:'h',inputs:{input_limit:'100'},request_id:'request'});
});
test('report links are local, CID-shaped paths', () => {
  const cid='Qm'+'1'.repeat(44);
  assert.equal(reportPath(cid),`/reports/${cid}/`);
  for (const x of ['https://evil.test/', '//evil.test', '../../etc/passwd', '<svg>', '', null]) assert.equal(reportPath(x),null);
});
test('cost labels use returned denominations and do not invent sats', () => {
  assert.equal(costLabel({cost:400000000,cost_damage:4}), '4 DAMAGE');
  assert.match(costLabel({cost:10}), /10 HITS/);
  assert.equal(costLabel({}), 'Estimate unavailable');
});
test('indeterminate and settlement messages do not encourage automatic reruns', () => {
  assert.match(friendlyError({error:'settlement_pending'}), /Do not rerun/);
  assert.match(friendlyError({error:'not_found'}), /do not assume nothing ran/);
  assert.match(friendlyError({status:403}), /not authorised/);
  assert.doesNotMatch(friendlyError({message:'secret leaked'}), /secret leaked/);
});
