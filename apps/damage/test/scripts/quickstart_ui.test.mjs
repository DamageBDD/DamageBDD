import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

function node(id) {
  return {
    id, value: '', textContent: '', disabled: false, href: '',
    classList: {
      classes: new Set(['hidden']),
      add(c) { this.classes.add(c); },
      remove(c) { this.classes.delete(c); },
      toggle(c, on) { if (on) this.add(c); else this.remove(c); }
    },
    listeners: {},
    addEventListener(name, fn) { this.listeners[name] = fn; }
  };
}
const els = Object.fromEntries([
  'connect-form', 'target', 'generate', 'test-panel', 'result-panel',
  'feature', 'run', 'trial-note', 'result', 'share', 'schedule',
  'copy', 'download', 'status'
].map(id => [id, node(id)]));

// No DOM/HTTP side effects are needed for the view's functional checks.
globalThis.document = { getElementById(id) { return els[id]; } };
const requests = [];
const expectedFeature = 'Feature: First API verification\n  Scenario: GET endpoint returns HTTP 200\n    Given I am using server "https://example.com"\n    When I make a GET request to "/"\n    Then the response status must be "200"\n';
globalThis.fetch = async (path, opts) => {
  requests.push({ path, opts });
  if (path.endsWith('/generate')) return {
    ok: true, json: async () => ({ url: 'https://example.com/',
      feature: expectedFeature, trial_available: true })
  };
  if (path.endsWith('/run')) return {
    ok: true, json: async () => ({ passed: true, observed_status: 200,
      elapsed_ms: 8, report_url: '/try/report/abcdef' })
  };
  if (path.includes('/schedules/')) return {
    ok: true, text: async () => '{"status":"ok"}'
  };
  throw Error(`Unexpected endpoint ${path}`);
};
await import(pathToFileURL(resolve('apps/damage/priv/static/js/quickstart.js')).href);

test('generate, execute, report and schedule use distinct intended endpoints', async () => {
  els.target.value = 'https://example.com/';
  await els['connect-form'].listeners.submit({ preventDefault() {} });
  assert.equal(requests[0].path, '/api/quickstart/generate');
  assert.equal(els.feature.textContent, expectedFeature);
  assert.equal(els.run.disabled, false);
  await els.run.listeners.click();
  assert.equal(requests[1].path, '/api/quickstart/run');
  assert.match(els.result.textContent, /PASS/);
  assert.equal(els.share.href, '/try/report/abcdef');
  await els.schedule.listeners.click();
  assert.equal(requests[2].path, '/schedules/daily/every/1/day');
  assert.equal(requests[2].opts.body, expectedFeature);
  assert.equal(requests[2].opts.credentials, 'same-origin');
  assert.match(els.status.textContent, /Schedule request accepted/);
});
