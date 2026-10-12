/* DamageBDD analytics — derived from the same public verification evidence used
 * by Run history. No direct cross-origin middleware calls and no raw contract
 * log JSON is rendered into the dashboard.
 */
import {
  aeAddress, normalizeSpend, plausibleRunTransaction, normalizeRunMeta,
  txHashOf, DEFAULT_TOKEN_CONTRACT
} from './run-history-model.js';
import {aggregateRuns} from './analytics-model.js';

const $ = id => document.getElementById(id);
const text = value => String(value ?? '').trim();
const compact = (value, n = 8) => {
  const s = text(value);
  return s.length > n * 2 + 3 ? `${s.slice(0, n)}…${s.slice(-n)}` : s;
};
const state = {rows: [], rawRows: new Map(), config: null, loading: false, chart: null, scanned: 0, loaded: false};
const MAX_RECENT = 12;
const TX_PARALLEL = 7;
const EVIDENCE_PARALLEL = 6;

function host() { return $('analytics-workspace'); }
function isActive() { const panel = $('analytics-tab'); return !!panel && !panel.hidden; }
function setStatus(message, tone = '') {
  const el = $('analytics-status');
  if (!el) return;
  el.textContent = message;
  if (tone) el.dataset.tone = tone; else delete el.dataset.tone;
}
function safeAccount(value) { return aeAddress(value, ['ak_']); }
function reportUrl(cid) { return `/reports/${encodeURIComponent(cid)}/`; }
function txUrl(hash) { return `https://aescan.io/transactions/${encodeURIComponent(hash)}`; }

async function fetchJson(url, opts = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeout || 11000);
  try {
    const res = await fetch(url, {credentials: opts.credentials || 'same-origin', signal: controller.signal,
      headers: {accept: 'application/json'}});
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  } finally { clearTimeout(timer); }
}

async function config() {
  if (state.config) return state.config;
  let remote = {};
  try { remote = await fetchJson('/api/analytics/config'); } catch { /* compatibility with older nodes */ }
  const h = host();
  state.config = {
    account: safeAccount(remote.account) || safeAccount(h?.dataset.account),
    node: aeAddress(remote.node) || aeAddress(h?.dataset.node),
    token: aeAddress(remote.token_contract, ['ct_']) || DEFAULT_TOKEN_CONTRACT,
    pageLimit: Math.min(100, Math.max(10, Number(remote.page_limit) || 100)),
    maxPages: Math.min(8, Math.max(1, Number(remote.max_pages) || 4))
  };
  return state.config;
}

function proxyPath(path) {
  return `/api/run-history/activities?path=${encodeURIComponent(path)}`;
}
async function publicPage(path) { return fetchJson(proxyPath(path), {credentials: 'omit'}); }
async function transaction(hash) {
  if (!hash) return null;
  if (!state.rawRows.has(hash)) {
    state.rawRows.set(hash, publicPage(`/v3/transactions/${encodeURIComponent(hash)}`).catch(() => null));
  }
  return state.rawRows.get(hash);
}
async function runMeta(cid) {
  try { return await fetchJson(`${reportUrl(cid)}run.meta`, {credentials: 'omit'}); }
  catch { return null; }
}
async function taskQueue(items, count, fn) {
  let index = 0;
  await Promise.all(Array.from({length: Math.min(count, items.length)}, async () => {
    while (index < items.length) { const i = index++; await fn(items[i], i); }
  }));
}

async function normalizeCandidate(item, trusted, token) {
  if (!plausibleRunTransaction(item, token)) return null;
  let row = normalizeSpend(item, {contract: token, trustedContractScope: trusted});
  const hash = txHashOf(item);
  if (!row && hash) {
    const full = await transaction(hash);
    if (full) row = normalizeSpend(full, {contract: token, trustedContractScope: trusted});
  }
  return row;
}

async function scanEvidence(cfg) {
  const account = cfg.account;
  if (!account) throw new Error('No authenticated account is available for analytics');
  const base = `/v3/transactions?contract=${encodeURIComponent(cfg.token)}&type=contract_call&type=paying_for&direction=backward&limit=${cfg.pageLimit}`;
  const accountPath = `/v3/accounts/${encodeURIComponent(account)}/activities?owned_only=false&type=transactions&direction=backward&limit=${cfg.pageLimit}`;
  const sources = [
    {next: base, trusted: true, pages: 0, done: false},
    {next: accountPath, trusted: false, pages: 0, done: false}
  ];
  const candidates = [];
  let scanned = 0;
  for (let round = 0; round < cfg.maxPages; round++) {
    const active = sources.filter(s => !s.done);
    if (!active.length) break;
    const pages = await Promise.all(active.map(async source => {
      try { return {source, page: await publicPage(source.next)}; }
      catch (error) { return {source, error}; }
    }));
    for (const result of pages) {
      const source = result.source;
      source.pages += 1;
      if (result.error) { source.done = true; continue; }
      const data = Array.isArray(result.page?.data) ? result.page.data : [];
      scanned += data.length;
      candidates.push(...data.map(row => ({row, trusted: source.trusted})));
      const next = result.page?.next;
      source.next = next ? normalizeNext(next) : null;
      source.done = !source.next || source.pages >= cfg.maxPages;
    }
  }

  const normalized = [];
  await taskQueue(candidates, TX_PARALLEL, async candidate => {
    const row = await normalizeCandidate(candidate.row, candidate.trusted, cfg.token).catch(() => null);
    if (row) normalized.push(row);
  });

  const distinct = new Map();
  for (const row of normalized) {
    const key = row.txHash || `${row.reportCid}:${row.callerId}:${row.nodePublicKey}`;
    const old = distinct.get(key);
    const score = r => (r.callerId ? 2 : 0) + (r.nodePublicKey ? 2 : 0) + (r.createdMs ? 1 : 0);
    if (!old || score(row) > score(old)) distinct.set(key, row);
  }
  const rows = [...distinct.values()];
  await taskQueue(rows, EVIDENCE_PARALLEL, async (row, i) => {
    const meta = await runMeta(row.reportCid);
    rows[i] = normalizeRunMeta(row, meta);
  });
  return {rows: rows.filter(r => r.callerId === account), scanned};
}

function normalizeNext(next) {
  try {
    const u = new URL(next, location.origin);
    const marker = '/v3/';
    const idx = u.pathname.indexOf(marker);
    if (idx >= 0) return u.pathname.slice(idx) + u.search;
    const mdw = '/mdw/v3/';
    const midx = u.pathname.indexOf(mdw);
    if (midx >= 0) return '/v3/' + u.pathname.slice(midx + mdw.length) + u.search;
    return null;
  } catch { return null; }
}

function fmtPercent(value) { return value == null ? '—' : `${Math.round(value * 100)}%`; }
function fmtDuration(value) {
  if (value == null || !Number.isFinite(value)) return '—';
  if (value < 1) return `${Math.round(value * 1000)} ms`;
  if (value < 60) return `${value.toFixed(value < 10 ? 2 : 1)} s`;
  return `${(value / 60).toFixed(1)} min`;
}
function setKpi(name, value, detail) {
  const el = document.querySelector(`[data-kpi="${name}"]`);
  if (!el) return;
  const strong = el.querySelector('strong'); if (strong) strong.textContent = value;
  const small = el.querySelector('small'); if (small && detail) small.textContent = detail;
}
function statusBadge(status) {
  const span = document.createElement('span');
  const normalized = ['passed', 'failed'].includes(status) ? status : 'unknown';
  span.className = `analytics-result analytics-result-${normalized}`;
  span.textContent = normalized === 'passed' ? 'Passed' : normalized === 'failed' ? 'Failed' : 'Unknown';
  return span;
}
function appendLink(cell, label, href) {
  const a = document.createElement('a'); a.textContent = label; a.href = href;
  if (/^https?:/.test(href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
  cell.append(a);
}

function renderRecent(summary) {
  const body = $('analytics-recent-body'); if (!body) return;
  body.replaceChildren();
  const rows = summary.rows.slice(0, MAX_RECENT);
  if (!rows.length) {
    const tr = document.createElement('tr'), td = document.createElement('td');
    td.colSpan = 6; td.className = 'workspace-empty'; td.textContent = 'No published verification evidence was observed in this window.';
    tr.append(td); body.append(tr); return;
  }
  for (const row of rows) {
    const tr = document.createElement('tr');
    const result = document.createElement('td'); result.append(statusBadge(row.status));
    const feature = document.createElement('td');
    const title = document.createElement('strong'); title.textContent = row.featureTitle || compact(row.featureCid, 10) || 'Untitled feature';
    feature.append(title);
    if (row.featureTitle && row.featureCid) {
      const cid = document.createElement('small'); cid.textContent = compact(row.featureCid, 8); feature.append(cid);
    }
    const when = document.createElement('td'); when.textContent = row.createdMs ? new Date(row.createdMs).toLocaleString() : 'Unknown';
    const duration = document.createElement('td'); duration.textContent = fmtDuration(Number(row.duration));
    const node = document.createElement('td'); node.textContent = row.nodePublicKey ? compact(row.nodePublicKey, 8) : 'Unresolved';
    const evidence = document.createElement('td'); evidence.className = 'analytics-evidence-links';
    if (row.reportCid) appendLink(evidence, 'Report', reportUrl(row.reportCid));
    if (row.txHash) appendLink(evidence, 'Chain', txUrl(row.txHash));
    tr.append(result, feature, when, duration, node, evidence); body.append(tr);
  }
}

function renderChart(summary) {
  const el = $('analytics-activity-chart'); if (!el || !window.echarts) return;
  state.chart ||= window.echarts.init(el);
  const muted = getComputedStyle(document.body).getPropertyValue('--ws-muted').trim() || '#93a5bb';
  const line = getComputedStyle(document.body).getPropertyValue('--ws-line').trim() || '#293648';
  state.chart.setOption({
    animationDuration: 250,
    tooltip: {trigger: 'axis'},
    grid: {left: 38, right: 16, top: 18, bottom: 34},
    xAxis: {type: 'category', data: summary.series.map(x => x.day.slice(5)), axisLabel: {color: muted}, axisLine: {lineStyle: {color: line}}},
    yAxis: {type: 'value', minInterval: 1, axisLabel: {color: muted}, splitLine: {lineStyle: {color: line}}},
    series: [
      {name: 'Passed', type: 'bar', stack: 'runs', data: summary.series.map(x => x.passed), itemStyle: {color: '#87c95f'}},
      {name: 'Failed', type: 'bar', stack: 'runs', data: summary.series.map(x => x.failed), itemStyle: {color: '#db6b78'}},
      {name: 'Unknown', type: 'bar', stack: 'runs', data: summary.series.map(x => x.unknown), itemStyle: {color: '#718096'}}
    ]
  }, true);
  const legend = $('analytics-legend');
  if (legend) legend.innerHTML = '<span data-tone="passed">Passed</span><span data-tone="failed">Failed</span><span data-tone="unknown">Unknown</span>';
}

function render(summary, scanned) {
  setKpi('runs', String(summary.total), `${scanned} public transactions scanned`);
  setKpi('pass-rate', fmtPercent(summary.passRate), `${summary.known} run${summary.known === 1 ? '' : 's'} with known outcome`);
  setKpi('duration', fmtDuration(summary.medianDuration), `${summary.medianDuration == null ? 'No' : 'Published'} timing metadata`);
  setKpi('active-days', String(summary.activeDays), `Days with published runs in window`);
  $('analytics-passed').textContent = String(summary.passed);
  $('analytics-failed').textContent = String(summary.failed);
  $('analytics-unknown').textContent = String(summary.unknown);
  $('analytics-p95').textContent = fmtDuration(summary.p95Duration);
  $('analytics-features').textContent = String(summary.uniqueFeatures);
  $('analytics-coverage').textContent = summary.evidenceCoverage == null ? 'No runs observed' :
    `${fmtPercent(summary.evidenceCoverage)} include run.meta evidence`;
  renderChart(summary); renderRecent(summary);
  $('analytics-updated').textContent = `Updated ${new Date().toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})}`;
}

async function refresh() {
  if (state.loading || !isActive()) return;
  state.loading = true;
  $('analytics-refresh').disabled = true;
  setStatus('Reading published run evidence…');
  try {
    const cfg = await config();
    const {rows, scanned} = await scanEvidence(cfg);
    state.rows = rows;
    state.scanned = scanned;
    state.loaded = true;
    const days = Math.max(1, Number($('analytics-range').value) || 30);
    const summary = aggregateRuns(rows, {days});
    render(summary, scanned);
    const unknownNote = summary.unknown ? ` ${summary.unknown} outcome${summary.unknown === 1 ? '' : 's'} could not be established from published metadata.` : '';
    setStatus(`${summary.total} published verification run${summary.total === 1 ? '' : 's'} observed for this account.${unknownNote}`);
  } catch (error) {
    console.error('Analytics refresh failed', error);
    setStatus(`Analytics unavailable: ${error.message}`, 'error');
  } finally {
    state.loading = false;
    $('analytics-refresh').disabled = false;
  }
}

function reaggregate() {
  const days = Math.max(1, Number($('analytics-range').value) || 30);
  const summary = aggregateRuns(state.rows, {days});
  render(summary, state.scanned);
  setStatus(`${summary.total} published verification runs in the selected window.`);
}

function init() {
  if (!host()) return;
  $('analytics-refresh')?.addEventListener('click', () => { state.config = null; refresh(); });
  $('analytics-range')?.addEventListener('change', reaggregate);
  document.addEventListener('damage:panelchange', event => {
    if (event.detail?.id === 'analytics-tab' && !state.loaded) refresh();
  });
  const observer = new MutationObserver(() => { if (isActive() && !state.loaded) refresh(); });
  const panel = $('analytics-tab'); if (panel) observer.observe(panel, {attributes: true, attributeFilter: ['hidden']});
  window.addEventListener('resize', () => state.chart?.resize());
  if (isActive()) refresh();
}

document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
