/* Pure presentation helpers for the server-side analytics materialized view. */
export function number(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

export function percent(value, digits = 0) {
  if (value == null || value === '') return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return `${(n * 100).toFixed(digits)}%`;
}

export function duration(ms) {
  const n = Number(ms);
  if (!Number.isFinite(n) || n <= 0) return '—';
  if (n < 1000) return `${Math.round(n)} ms`;
  if (n < 60000) return `${(n / 1000).toFixed(n < 10000 ? 1 : 0)} s`;
  return `${(n / 60000).toFixed(1)} min`;
}

export function compact(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return '0';
  return new Intl.NumberFormat(undefined, {notation: n >= 10000 ? 'compact' : 'standard', maximumFractionDigits: 1}).format(n);
}

export function cacheAge(freshness = {}) {
  const age = Number(freshness.age_seconds);
  if (!Number.isFinite(age) || age < 0) return freshness.syncing ? 'Syncing' : 'Not synced';
  if (age < 60) return `${Math.round(age)}s`;
  if (age < 3600) return `${Math.round(age / 60)}m`;
  return `${(age / 3600).toFixed(1)}h`;
}

export function ecaiTone(status) {
  const s = String(status || '').toLowerCase();
  if (s === 'active') return 'active';
  if (s === 'degraded') return 'degraded';
  return 'unavailable';
}

export function trendLabel(trend = {}) {
  const delta = Number(trend.pass_rate_delta);
  if (!Number.isFinite(delta)) return 'No prior-window comparison';
  const pp = delta * 100;
  if (Math.abs(pp) < 0.05) return 'Pass rate unchanged vs previous window';
  return `${pp > 0 ? '+' : ''}${pp.toFixed(1)} pp vs previous window`;
}

export function chartSeries(summary = {}) {
  return Array.isArray(summary.series) ? summary.series.map(row => ({
    day: String(row.day || ''),
    passed: Math.max(0, number(row.passed)),
    failed: Math.max(0, number(row.failed)),
    unknown: Math.max(0, number(row.unknown)),
    total: Math.max(0, number(row.total))
  })) : [];
}

export function viewModel(summary = {}) {
  const totals = summary.totals || {};
  const durations = summary.durations || {};
  const evidence = summary.evidence || {};
  const ecai = summary.ecai || {};
  const freshness = summary.freshness || {};
  const known = number(totals.known);
  const runs = number(totals.runs);
  return {
    runs,
    passed: number(totals.passed),
    failed: number(totals.failed),
    unknown: number(totals.unknown),
    known,
    passRate: percent(totals.pass_rate, runs >= 100 ? 1 : 0),
    median: duration(durations.median_ms),
    p95: duration(durations.p95_ms),
    activeDays: number(totals.active_days),
    uniqueFeatures: number(totals.unique_features),
    evidenceCoverage: percent(evidence.report_coverage, 0),
    evidenceCoverageNumber: Number.isFinite(Number(evidence.report_coverage)) ? Math.max(0, Math.min(1, Number(evidence.report_coverage))) : 0,
    chainCoverage: percent(evidence.chain_coverage, 0),
    trend: trendLabel(summary.trend),
    ecai: {
      status: String(ecai.status || 'unavailable'),
      tone: ecaiTone(ecai.status),
      indexed: number(ecai.indexed_runs),
      coverage: percent(ecai.index_coverage, 0),
      relations: number(ecai.relation_count),
      curves: number(ecai.curve_feature_count),
      geometry: String(ecai.geometry_status || 'unavailable'),
      geometryBackend: String(ecai.geometry_backend || 'unavailable'),
      projectionPending: number(ecai.projection?.pending)
    },
    cacheAge: cacheAge(freshness),
    stale: freshness.stale === true,
    syncing: freshness.syncing === true,
    sourceHeight: freshness.source_height ?? null,
    scannedTransactions: number(freshness.scanned_transactions),
    decodedRuns: number(freshness.decoded_runs),
    hydratedRuns: number(freshness.hydrated_runs),
    backfill: freshness.backfill && typeof freshness.backfill === 'object' ? freshness.backfill : {},
    degradedSources: Array.isArray(freshness.degraded_sources) ? freshness.degraded_sources.map(String) : [],
    lastUpdatedMs: number(freshness.last_updated_ms),
    lastSyncMs: number(freshness.last_sync_ms),
    series: chartSeries(summary),
    recent: Array.isArray(summary.recent) ? summary.recent : [],
    signals: Array.isArray(summary.signals) ? summary.signals : []
  };
}
