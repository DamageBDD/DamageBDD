import test from 'node:test';
import assert from 'node:assert/strict';
import { apiHeaders, promptBytes, filterSteps, appendStep, featureStats, canAcceptDraft,
  validationSummary, featureFilename } from '../../priv/static/js/bdd-composer-model.js';
import { readFileSync } from 'node:fs';
const catalog = JSON.parse(readFileSync(new URL('../fixtures/bdd-composer/catalog.json', import.meta.url)));
const draft = JSON.parse(readFileSync(new URL('../fixtures/bdd-composer/draft.json', import.meta.url)));

test('UTF-8 prompt limit counts bytes, not JavaScript code units', () => {
  assert.equal(promptBytes('abc'), 3); assert.equal(promptBytes('é'), 2); assert.equal(promptBytes('🧪'), 4);
});
test('headers preserve cookie auth without emitting Bearer null', () => {
  for (const bad of [null, undefined, '', 'null', 'undefined']) assert.equal(apiHeaders(bad).Authorization, undefined);
  assert.equal(apiHeaders('test-token').Authorization, 'Bearer test-token');
  assert.equal(apiHeaders().Accept, 'application/json'); assert.equal(apiHeaders()['X-Damage-BDD'], '1');
});
test('step search is case insensitive and all terms must match', () => {
  assert.equal(filterSteps(catalog.steps, 'HTTP GET').length, 1);
  assert.equal(filterSteps(catalog.steps, 'json nonexistent').length, 0);
  assert.equal(filterSteps(catalog.steps, '').length, 6);
});
test('step insertion scaffolds a feature and selects the parameter marker', () => {
  const insert = appendStep('', catalog.steps[0]);
  assert.match(insert.text, /^Feature: New behaviour/);
  assert.equal(insert.text.slice(insert.start, insert.end), '<Server>');
});
test('inserting a step preserves existing editor text', () => {
  const current = 'Feature: Mine\n  Scenario: Keep me\n';
  assert.ok(appendStep(current, catalog.steps[1]).text.startsWith(current));
});
test('statistics ignore apparent steps in docstrings', () => {
  assert.deepEqual(featureStats('Feature: A\nScenario: B\nWhen I send data\n  """\nGiven fake\nScenario: fake\n  """\nThen a result'), { scenarios: 1, steps: 2 });
});
test('only complete, validated drafts can be accepted', () => {
  assert.equal(canAcceptDraft(draft), true);
  assert.equal(canAcceptDraft({...draft, complete: false}), false);
  assert.equal(canAcceptDraft({...draft, missing_steps: ['unsupported']}), false);
  assert.equal(canAcceptDraft({...draft, validation: {valid: false}}), false);
  assert.equal(canAcceptDraft({...draft, validation: {valid: 'true'}}), false);
  assert.equal(canAcceptDraft({...draft, feature: ''}), false);
});
test('validation copy does not claim runtime success', () => {
  assert.match(validationSummary(draft.validation), /Runtime behaviour is not verified/);
  assert.match(validationSummary({valid:false, diagnostics:[{}]}), /1 issue/);
});
test('download filenames are bounded and contain no path traversal', () => {
  assert.equal(featureFilename('Feature: ../../Hello <script>'), 'hello-script.feature');
  assert.equal(featureFilename(''), 'feature.feature');
  assert.ok(featureFilename('Feature: ' + 'x'.repeat(300)).length <= 88);
});
