import test from 'node:test';
import assert from 'node:assert/strict';
import {aggregateRuns, isoDay, percentile} from '../../priv/static/js/analytics-model.js';

const DAY = 86400000;
const NOW = Date.UTC(2026, 9, 12, 12, 0, 0);

test('isoDay keeps UTC dates stable', () => {
  assert.equal(isoDay(Date.UTC(2026, 9, 12, 23, 59, 59)), '2026-10-12');
});

test('aggregateRuns separates known and unknown outcomes', () => {
  const rows = [
    {createdMs: NOW - DAY, status: 'passed', duration: 1.2, featureCid: 'A', evidenceLoaded: true},
    {createdMs: NOW - DAY, status: 'failed', duration: 2.4, featureCid: 'A', evidenceLoaded: true},
    {createdMs: NOW, status: 'unknown', duration: null, featureCid: 'B', evidenceLoaded: false},
    {createdMs: NOW - 40 * DAY, status: 'passed', duration: 9, featureCid: 'OLD', evidenceLoaded: true}
  ];
  const out = aggregateRuns(rows, {days: 30, now: NOW});
  assert.equal(out.total, 3);
  assert.equal(out.passed, 1);
  assert.equal(out.failed, 1);
  assert.equal(out.unknown, 1);
  assert.equal(out.known, 2);
  assert.equal(out.passRate, 0.5);
  assert.equal(out.activeDays, 2);
  assert.equal(out.uniqueFeatures, 2);
  assert.equal(out.evidenceCoverage, 2 / 3);
});

test('percentiles are deterministic for sparse duration samples', () => {
  assert.equal(percentile([1, 2, 3, 4], 0.5), 2);
  assert.equal(percentile([1, 2, 3, 4], 0.95), 4);
  assert.equal(percentile([], 0.95), null);
});
