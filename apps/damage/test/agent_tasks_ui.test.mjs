import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const text = await readFile(new URL('../priv/static/js/agent-tasks.js',import.meta.url),'utf8');
const {isTerminal,controlsFor,budgetLabel} = await import(`data:text/javascript;base64,${Buffer.from(text).toString('base64')}`);
test('terminal states cannot dispatch approval or execution commands', () => {
  for (const status of ['completed','failed','cancelled','cancelled_unreconciled','exhausted']) {
    assert.equal(isTerminal(status),true); assert.deepEqual(controlsFor(status),['learning']);
  }
});
test('approval is visible only for pending approval', () => {
  assert(controlsFor('awaiting_approval').includes('approve'));
  for (const status of ['planning','executing','waiting','paused','interrupted']) assert(!controlsFor(status).includes('approve'));
});
test('model text is not rendered as HTML or Markdown', () => {
  assert(!text.includes('innerHTML')); assert(!text.includes('insertAdjacentHTML'));
  assert(text.includes("$('proposal').textContent"));
});
test('page teardown aborts requests and stops polling', () => {
  assert(text.includes('controller.abort()')); assert(text.includes('clearTimeout(timer)'));
});
test('task creation retries retain an idempotency key', () => {
  assert(text.includes('creation.payload !== payload')); assert(text.includes("'idempotency-key':creation.key"));
});

test('accounting pending is not a terminal success and cannot be cancelled away', () => {
  assert.equal(isTerminal('accounting_pending'), false);
  assert.deepEqual(controlsFor('accounting_pending'), ['reconcile','learning']);
});
test('in-flight accounting writes expose no retry or execution command', () => {
  for (const s of ['budget_reserving','settling','receipting','reconciling']) {
    assert.deepEqual(controlsFor(s), ['learning']);
  }
});
test('recovered uncertain settlement requires reconciliation', () => {
  assert.deepEqual(controlsFor('interrupted', {budget:{status:'settlement_pending'}}), ['reconcile','learning']);
});
test('uncertain execution cannot be resumed through the panel', () => {
  assert.deepEqual(controlsFor('interrupted', {interrupted_phase:'executing', budget:{status:'reserved'}}), ['cancel','learning']);
});
test('budget labels keep integer base units and separate AE transaction fees', () => {
  const label = budgetLabel({budget:{mode:'aeternity',status:'reserved',spent_units:8,max_cost_units:20,remaining_units:12}});
  assert.match(label, /8 \/ 20 DAMAGE base units/);
  assert.match(label, /AE transaction fees are separate/);
});
test('browser cannot set a task monetary ceiling in the creation payload', () => {
  assert(text.includes('JSON.stringify({template:select.value,goal:goal.value})'));
  assert(!text.includes('form.elements.max_cost_units'));
});
