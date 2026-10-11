import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../../priv/static/js/dashboard-tax-settings.js', import.meta.url), 'utf8');
const {TAX_KEYS, allowedTaxFields, readTaxControl, changedTaxSettings, initDashboardTaxSettings} =
  await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const owner = 'ak_' + '2'.repeat(52);
const fields = [
  {name: 'tax_enabled', label: 'Enable', type: 'boolean', value: false},
  {name: 'tax_cln_owner', label: 'Owner', type: 'ae_account', value: null},
  {name: 'tax_max_prices_per_backfill', label: 'Maximum', type: 'integer', min: 1, max: 500, value: 200}
];

test('only the eight tax fields are editable', () => {
  assert.equal(TAX_KEYS.length, 8);
  assert.deepEqual(allowedTaxFields([{name: 'tax_admins', type: 'string'},
    {name: 'node_admins', type: 'string'}, fields[2], fields[2], ...fields.slice(0, 2)]).map(x => x.name),
  ['tax_enabled', 'tax_cln_owner', 'tax_max_prices_per_backfill']);
  assert.equal(initDashboardTaxSettings(), null); // SSR only, no side effects on import.
});

test('validates owner and price budgets without coercion', () => {
  assert.equal(readTaxControl(fields[1], {value: owner}), owner);
  assert.throws(() => readTaxControl(fields[1], {value: 'ak_invalidO0'}));
  assert.equal(readTaxControl(fields[2], {value: '200'}), 200);
  assert.throws(() => readTaxControl(fields[2], {value: '10.5'}));
  assert.throws(() => readTaxControl(fields[2], {value: '501'}));
});

test('diffs only changed values including an initially absent owner', () => {
  const controls = new Map([
    ['tax_enabled', {checked: true}],
    ['tax_cln_owner', {value: owner}],
    ['tax_max_prices_per_backfill', {value: '200'}]
  ]);
  assert.deepEqual(changedTaxSettings(fields, controls),
    {tax_enabled: true, tax_cln_owner: owner});
});

test('country selection validates against server supplied allowed options', () => {
  const region = {name: 'tax_jurisdiction', label: 'Country', type: 'tax_jurisdiction',
    value: 'AU', options: [{value: 'AU', label: 'Australia'}, {value: 'US', label: 'United States'}]};
  assert.equal(readTaxControl(region, {value: 'US'}), 'US');
  assert.throws(() => readTaxControl(region, {value: 'ZZ'}));
  assert.throws(() => readTaxControl(region, {value: 'tax_admins'}));
  assert.deepEqual(changedTaxSettings([region], new Map([['tax_jurisdiction', {value: 'US'}]])),
    {tax_jurisdiction: 'US'});
});
