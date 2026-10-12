import test from 'node:test';
import assert from 'node:assert/strict';
import {percent, duration, cacheAge, ecaiTone, trendLabel, chartSeries, viewModel} from '../../priv/static/js/analytics-model.js';

test('formatters keep missing metrics distinct from zero', () => {
  assert.equal(percent(null), '—');
  assert.equal(percent(undefined), '—');
  assert.equal(duration(0), '—');
  assert.equal(duration(840), '840 ms');
  assert.equal(duration(2400), '2.4 s');
});

test('cache age and ECAI status are presentation-only', () => {
  assert.equal(cacheAge({age_seconds: 12}), '12s');
  assert.equal(cacheAge({age_seconds: 125}), '2m');
  assert.equal(cacheAge({syncing: true}), 'Syncing');
  assert.equal(ecaiTone('active'), 'active');
  assert.equal(ecaiTone('anything-else'), 'unavailable');
});

test('trend label reports percentage-point movement', () => {
  assert.equal(trendLabel({pass_rate_delta: 0.031}), '+3.1 pp vs previous window');
  assert.equal(trendLabel({pass_rate_delta: -0.02}), '-2.0 pp vs previous window');
});

test('chart series normalizes negative and missing counts', () => {
  assert.deepEqual(chartSeries({series: [{day: '2026-10-12', passed: 3, failed: -2}]}), [
    {day: '2026-10-12', passed: 3, failed: 0, unknown: 0, total: 0}
  ]);
});

test('view model preserves known/unknown outcome semantics', () => {
  const vm = viewModel({
    totals: {runs: 10, passed: 8, failed: 1, unknown: 1, known: 9, pass_rate: 8 / 9,
             active_days: 4, unique_features: 3},
    durations: {median_ms: 1200, p95_ms: 5000},
    evidence: {report_coverage: .8, chain_coverage: .7},
    trend: {pass_rate_delta: .01},
    ecai: {status: 'active', indexed_runs: 8, index_coverage: .8, relation_count: 54,
           curve_feature_count: 32, geometry_status: 'experimental', projection: {pending: 3}},
    freshness: {age_seconds: 9},
    series: [], recent: [], signals: []
  });
  assert.equal(vm.runs, 10);
  assert.equal(vm.passRate, '89%');
  assert.equal(vm.unknown, 1);
  assert.equal(vm.median, '1.2 s');
  assert.equal(vm.evidenceCoverage, '80%');
  assert.equal(vm.ecai.relations, 54);
  assert.equal(vm.ecai.curves, 32);
  assert.equal(vm.ecai.projectionPending, 3);
});

test('view model exposes historical import diagnostics', () => {
  const vm = viewModel({
    totals: {runs: 0},
    freshness: {
      scanned_transactions: 412,
      decoded_runs: 3,
      hydrated_runs: 2,
      backfill: {complete: false, pending_sources: ['account:ak_test']}
    }
  });
  assert.equal(vm.scannedTransactions, 412);
  assert.equal(vm.decodedRuns, 3);
  assert.equal(vm.hydratedRuns, 2);
  assert.deepEqual(vm.backfill.pending_sources, ['account:ak_test']);
});
