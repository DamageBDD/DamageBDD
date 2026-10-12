import {timeMs} from './run-history-model.js';

export function isoDay(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

export function percentile(values, p) {
  const numbers = values.filter(Number.isFinite).filter(v => v >= 0).sort((a, b) => a - b);
  if (!numbers.length) return null;
  const idx = Math.max(0, Math.min(numbers.length - 1, Math.ceil(p * numbers.length) - 1));
  return numbers[idx];
}

export function aggregateRuns(rows, {days = 30, now = Date.now()} = {}) {
  const dayMs = 86400000;
  const start = now - days * dayMs;
  const filtered = rows.filter(row => Number.isFinite(row.createdMs) && row.createdMs >= start && row.createdMs <= now + dayMs);
  const buckets = new Map();
  const axis = [];
  for (let i = days - 1; i >= 0; i--) {
    const key = isoDay(now - i * dayMs);
    axis.push(key);
    buckets.set(key, {day: key, passed: 0, failed: 0, unknown: 0, total: 0});
  }
  for (const row of filtered) {
    const key = isoDay(row.createdMs);
    const bucket = buckets.get(key);
    if (!bucket) continue;
    const status = ['passed', 'failed'].includes(row.status) ? row.status : 'unknown';
    bucket[status] += 1;
    bucket.total += 1;
  }
  const passed = filtered.filter(r => r.status === 'passed').length;
  const failed = filtered.filter(r => r.status === 'failed').length;
  const unknown = filtered.length - passed - failed;
  const known = passed + failed;
  const durations = filtered.map(r => Number(r.duration)).filter(v => Number.isFinite(v) && v >= 0);
  const features = new Set(filtered.map(r => r.featureCid).filter(Boolean));
  const evidence = filtered.filter(r => r.evidenceLoaded).length;
  return {
    rows: filtered.sort((a, b) => b.createdMs - a.createdMs),
    series: axis.map(day => buckets.get(day)),
    total: filtered.length,
    passed, failed, unknown, known,
    passRate: known ? passed / known : null,
    activeDays: [...buckets.values()].filter(b => b.total > 0).length,
    medianDuration: percentile(durations, 0.5),
    p95Duration: percentile(durations, 0.95),
    uniqueFeatures: features.size,
    evidenceCoverage: filtered.length ? evidence / filtered.length : null
  };
}

export function durationSeconds(meta) {
  const v = Number(meta?.execution_time_hires ?? meta?.execution_time ?? 0);
  return Number.isFinite(v) && v >= 0 ? v : null;
}

export function createdMsFromMeta(meta, fallback = null) {
  if (!meta || typeof meta !== 'object') return fallback;
  return timeMs(meta.start_time_hires ?? meta.completed_at ?? meta.end_time_hires) || fallback;
}
