import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../../priv/static/js/dashboard-navigation.js', import.meta.url), 'utf8');
const {panelIdFromHash, initDashboardNavigation} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

test('accepts existing dashboard anchors with or without hash', () => {
  for (const id of ['execution-tab', 'activity-tab', 'billing-tab', 'node-cln-admin-tab', 'node-context-tab']) {
    assert.equal(panelIdFromHash(id), id);
    assert.equal(panelIdFromHash('#' + id), id);
  }
});
test('decodes a percent-encoded local panel id', () => {
  assert.equal(panelIdFromHash('#activity%2Dtab'), 'activity-tab');
});
test('rejects malformed percent encoding', () => {
  for (const input of ['#%ZZ-tab', '#%E0%A4%A-tab']) assert.equal(panelIdFromHash(input), null);
});
test('rejects CSS injection, HTML and nonlocal URLs', () => {
  for (const input of ['#x\"] [hidden]-tab', '#<script>-tab', 'https://evil.test/#activity-tab', '//evil.test/tab', '#node-tab\\', '#activity-tab/child']) {
    assert.equal(panelIdFromHash(input), null);
  }
});
test('does not consume ordinary workspace or modal anchors', () => {
  for (const input of ['#bdd-step-library', '#wallet-modal', '#dashboard-main', '', '#']) assert.equal(panelIdFromHash(input), null);
});
test('limits hash length and rejects non-string input', () => {
  for (const input of [null, undefined, 42, {}, [], '#' + 'x'.repeat(200) + '-tab']) assert.equal(panelIdFromHash(input), null);
});
test('does not require a DOM in tooling or create a navigation singleton', () => {
  assert.equal(initDashboardNavigation(), null);
});
