import {viewModel, compact, duration} from './analytics-model.js';

const root = document.querySelector('[data-analytics-root]');
if (root) initAnalytics(root);

function $(id) { return document.getElementById(id); }
function text(value) { return String(value ?? ''); }
function css(name, fallback) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim() ||
    getComputedStyle(document.body).getPropertyValue(name).trim();
  return value || fallback;
}
function short(value, keep = 8) {
  const s = text(value);
  if (s.length <= keep * 2 + 3) return s || '—';
  return `${s.slice(0, keep)}…${s.slice(-keep)}`;
}
function safeCid(value) {
  const s = text(value).trim();
  return /^(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]{20,})$/i.test(s) ? s : '';
}
function setText(id, value) { const el = $(id); if (el) el.textContent = text(value); }
function pctWidth(value) { return `${Math.max(0, Math.min(100, Number(value) * 100 || 0))}%`; }

function initAnalytics(panel) {
  let loaded = false;
  let loading = false;
  let lastLoad = 0;
  let latest = null;
  let controller = null;
  let emptySyncPolls = 0;

  const windowSelect = $('analytics-window');
  const refresh = $('analytics-refresh');

  async function fetchSummary({force = false} = {}) {
    const days = ['7', '30', '90'].includes(windowSelect?.value) ? windowSelect.value : '30';
    const res = await fetch(`/api/analytics/summary?window=${encodeURIComponent(days)}`, {
      credentials: 'same-origin',
      headers: {Accept: 'application/json'},
      cache: force ? 'reload' : 'default',
      signal: controller?.signal
    });
    if (!res.ok) throw new Error(`Analytics API returned ${res.status}`);
    return res.json();
  }

  async function load({force = false, quiet = false} = {}) {
    if (loading) return;
    if (!force && loaded && Date.now() - lastLoad < 15000) return;
    loading = true;
    controller?.abort();
    controller = new AbortController();
    if (!quiet) status('Loading cached verification intelligence…');
    if (refresh) refresh.disabled = true;
    try {
      const summary = await fetchSummary({force});
      latest = summary;
      render(summary);
      loaded = true;
      lastLoad = Date.now();
      const vm = viewModel(summary);
      // The first request registers this authenticated account with the
      // server-side indexer. If its historical cache is still empty, poll a few
      // times while that bounded background import runs instead of requiring a
      // manual reload. Never turn this into an unbounded browser poller.
      if (vm.runs === 0 && vm.syncing && emptySyncPolls < 8) {
        emptySyncPolls += 1;
        window.setTimeout(() => load({force: true, quiet: true}), 2500);
      } else if (vm.runs > 0 || !vm.syncing) {
        emptySyncPolls = 0;
      }
    } catch (error) {
      if (error?.name !== 'AbortError') status(error.message || 'Analytics unavailable', 'error');
    } finally {
      loading = false;
      if (refresh) refresh.disabled = false;
    }
  }

  async function requestRefresh() {
    if (loading) return;
    if (refresh) refresh.disabled = true;
    status('Requesting background reconciliation…');
    try {
      const res = await fetch('/api/analytics/refresh', {
        method: 'POST', credentials: 'same-origin', cache: 'no-store',
        headers: {'Content-Type': 'application/json', Accept: 'application/json'},
        body: '{}'
      });
      if (!res.ok) throw new Error(`Refresh request returned ${res.status}`);
      status('Refresh queued. Cached results remain available while evidence is reconciled.');
      await load({force: true, quiet: true});
      window.setTimeout(() => load({force: true, quiet: true}), 2500);
    } catch (error) {
      status(error.message || 'Could not request refresh', 'error');
    } finally {
      if (refresh) refresh.disabled = false;
    }
  }

  function status(message, tone = '') {
    const el = $('analytics-status');
    if (!el) return;
    el.textContent = message;
    if (tone) el.dataset.tone = tone; else delete el.dataset.tone;
  }

  function render(summary) {
    const vm = viewModel(summary);
    setText('analytics-kpi-runs', compact(vm.runs));
    setText('analytics-kpi-pass-rate', vm.passRate);
    setText('analytics-kpi-duration', vm.median);
    setText('analytics-kpi-active', compact(vm.activeDays));
    setText('analytics-kpi-runs-note', `${vm.known} runs with known outcome · ${vm.unknown} unknown`);
    setText('analytics-kpi-pass-note', vm.trend);
    setText('analytics-kpi-duration-note', vm.runs ? 'Approximate cached percentile' : 'No timing metadata');
    setText('analytics-kpi-active-note', `${vm.uniqueFeatures} unique feature${vm.uniqueFeatures === 1 ? '' : 's'}`);

    setText('analytics-health-passed', compact(vm.passed));
    setText('analytics-health-failed', compact(vm.failed));
    setText('analytics-health-unknown', compact(vm.unknown));
    setText('analytics-health-p95', vm.p95);
    setText('analytics-health-features', compact(vm.uniqueFeatures));
    setText('analytics-evidence-percent', vm.evidenceCoverage);
    const meter = $('analytics-evidence-meter');
    if (meter) meter.style.width = pctWidth(vm.evidenceCoverageNumber);
    setText('analytics-evidence-note', `Report evidence ${vm.evidenceCoverage} · chain-confirmed ${vm.chainCoverage}`);

    const ecaiStatus = $('analytics-ecai-status');
    if (ecaiStatus) {
      const baseStatus = vm.ecai.status === 'active' ? 'Active' : vm.ecai.status === 'degraded' ? 'Degraded' : 'Unavailable';
      ecaiStatus.textContent = vm.ecai.projectionPending ? `${baseStatus} · ${vm.ecai.projectionPending} queued` : baseStatus;
      ecaiStatus.dataset.tone = vm.ecai.tone;
    }
    setText('analytics-ecai-indexed', compact(vm.ecai.indexed));
    setText('analytics-ecai-coverage', `${vm.ecai.coverage} of runs indexed for deterministic retrieval`);
    setText('analytics-ecai-relations', compact(vm.ecai.relations));
    setText('analytics-ecai-curves', compact(vm.ecai.curves));
    setText('analytics-ecai-geometry', vm.ecai.geometry === 'experimental' ? 'Curve geometry: experimental' : 'Curve geometry: unavailable');
    setText('analytics-ecai-curve-note', vm.ecai.geometry === 'experimental' ? `${vm.ecai.geometryBackend.replaceAll('_', ' ')} · measurement only; not semantic similarity` : 'Elliptic relation measurement unavailable');
    setText('analytics-cache-age', vm.cacheAge);
    setText('analytics-cache-source', vm.sourceHeight ? `Materialized through chain height ${vm.sourceHeight}` : 'Server-side materialized read model');

    renderSignals(vm.signals);
    renderRecent(vm.recent);
    drawChart(vm.series);

    const updatedMs = vm.lastSyncMs || vm.lastUpdatedMs;
    setText('analytics-last-updated', updatedMs ? `Updated ${new Date(updatedMs).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})}` : 'Awaiting first sync');
    if (vm.syncing) status(`Reconciling evidence in background · ${vm.runs} cached runs available`);
    else if (vm.stale) {
      const sources = vm.degradedSources.length ? ` (${vm.degradedSources.join(', ')})` : '';
      status(`Serving cached analytics while an upstream source is degraded${sources} · ${vm.runs} runs available`);
    }
    else if (vm.runs === 0 && vm.scannedTransactions > 0) {
      const pending = Array.isArray(vm.backfill?.pending_sources) ? vm.backfill.pending_sources.length : 0;
      status(`Historical import scanned ${vm.scannedTransactions} transaction${vm.scannedTransactions === 1 ? '' : 's'} · ${vm.decodedRuns} verification run${vm.decodedRuns === 1 ? '' : 's'} decoded${pending ? ` · ${pending} source${pending === 1 ? '' : 's'} still backfilling` : ''}`);
    }
    else status(`${vm.runs} published verification run${vm.runs === 1 ? '' : 's'} observed for this account.`);
  }

  function renderSignals(signals) {
    const el = $('analytics-signals');
    if (!el) return;
    const rows = signals.length ? signals : [{severity: 'info', message: 'No deterministic signals for this window.'}];
    el.replaceChildren(...rows.map(signal => {
      const row = document.createElement('div');
      row.className = 'analytics-signal';
      row.dataset.severity = text(signal.severity || 'info');
      const message = document.createElement('span');
      message.textContent = text(signal.message || signal.kind || 'Signal');
      row.append(message);
      if (signal.signature) {
        const code = document.createElement('code');
        code.textContent = text(signal.signature);
        row.append(code);
      } else if (signal.count != null) {
        const count = document.createElement('strong');
        count.textContent = compact(signal.count);
        row.append(count);
      }
      return row;
    }));
  }

  function renderRecent(rows) {
    const body = $('analytics-recent-body');
    if (!body) return;
    if (!rows.length) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 7; td.className = 'workspace-empty analytics-empty-row';
      td.textContent = 'No cached verification evidence was observed in this window.';
      tr.append(td); body.replaceChildren(tr); return;
    }
    body.replaceChildren(...rows.map(run => {
      const tr = document.createElement('tr');
      const resultTd = document.createElement('td');
      const badge = document.createElement('span');
      const result = ['passed', 'failed'].includes(text(run.status)) ? text(run.status) : 'unknown';
      badge.className = 'analytics-result-badge'; badge.dataset.result = result;
      badge.textContent = result[0].toUpperCase() + result.slice(1); resultTd.append(badge);

      const featureTd = document.createElement('td'); featureTd.className = 'analytics-feature-cell';
      const featureStrong = document.createElement('strong');
      featureStrong.textContent = text(run.feature_title) || short(run.feature_cid);
      const featureSmall = document.createElement('small'); featureSmall.textContent = short(run.feature_cid, 7);
      featureTd.append(featureStrong, featureSmall);

      const whenTd = document.createElement('td');
      whenTd.textContent = run.created_ms ? new Date(Number(run.created_ms)).toLocaleString() : '—';
      const durationTd = document.createElement('td'); durationTd.textContent = duration(run.duration_ms);
      const nodeTd = document.createElement('td'); nodeTd.className = 'analytics-mono'; nodeTd.textContent = short(run.node, 6);

      const ecaiTd = document.createElement('td');
      const ecai = run.ecai || {};
      ecaiTd.textContent = ecai.relation_count ? `${ecai.relation_count} rel` : '—';
      const fingerprint = text(ecai.geometry_fingerprint);
      ecaiTd.title = [
        ecai.search_indexed ? 'Indexed in ECAI search' : 'ECAI search projection unavailable',
        fingerprint ? `Experimental curve fingerprint ${fingerprint}` : ''
      ].filter(Boolean).join(' · ');

      const evidenceTd = document.createElement('td');
      const links = document.createElement('div'); links.className = 'analytics-evidence-links';
      const cid = safeCid(run.report_cid);
      if (cid) {
        const report = document.createElement('a'); report.href = `/reports/${encodeURIComponent(cid)}/`;
        report.textContent = 'Report'; links.append(report);
      }
      if (run.tx_hash) {
        const tx = document.createElement('span'); tx.className = 'analytics-mono';
        tx.textContent = short(run.tx_hash, 5); tx.title = text(run.tx_hash); links.append(tx);
      }
      evidenceTd.append(links);
      tr.append(resultTd, featureTd, whenTd, durationTd, nodeTd, ecaiTd, evidenceTd);
      return tr;
    }));
  }

  function drawChart(series) {
    const canvas = $('analytics-chart');
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const width = Math.max(320, Math.round(rect.width || 900));
    const height = Math.max(220, Math.round(rect.height || 286));
    canvas.width = width * dpr; canvas.height = height * dpr;
    const ctx = canvas.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, width, height);
    const pad = {left: 38, right: 12, top: 16, bottom: 32};
    const plotW = width - pad.left - pad.right, plotH = height - pad.top - pad.bottom;
    const max = Math.max(1, ...series.map(r => Number(r.total) || 0));
    ctx.font = '10px system-ui, sans-serif'; ctx.textBaseline = 'middle';
    for (let i = 0; i <= 4; i++) {
      const value = Math.round(max * i / 4); const y = pad.top + plotH - plotH * i / 4;
      ctx.strokeStyle = css('--ws-line', '#26364a'); ctx.globalAlpha = .65;
      ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + plotW, y); ctx.stroke();
      ctx.globalAlpha = 1; ctx.fillStyle = css('--ws-muted', '#8fa1b7'); ctx.fillText(String(value), 5, y);
    }
    if (!series.length) return;
    const slot = plotW / series.length; const barW = Math.max(2, Math.min(18, slot * .68));
    series.forEach((row, i) => {
      const x = pad.left + i * slot + (slot - barW) / 2;
      let y = pad.top + plotH;
      for (const [key, color] of [['passed', css('--ws-accent', '#86b36b')], ['failed', css('--ws-error', '#d96b78')], ['unknown', '#718096']]) {
        const value = Number(row[key]) || 0; if (!value) continue;
        const h = value / max * plotH; y -= h; ctx.fillStyle = color; ctx.fillRect(x, y, barW, Math.max(1, h));
      }
    });
    const labels = Math.min(7, series.length); const stride = Math.max(1, Math.floor(series.length / labels));
    ctx.fillStyle = css('--ws-muted', '#8fa1b7'); ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    series.forEach((row, i) => {
      if (i % stride !== 0 && i !== series.length - 1) return;
      const x = pad.left + i * slot + slot / 2; ctx.fillText(text(row.day).slice(5), x, pad.top + plotH + 10);
    });
  }

  windowSelect?.addEventListener('change', () => load({force: false}));
  refresh?.addEventListener('click', requestRefresh);
  document.addEventListener('damage:panelchange', event => {
    if (event.detail?.id === 'analytics-tab') load();
  });
  window.addEventListener('resize', () => { if (latest && !panel.closest('[hidden]')) drawChart(viewModel(latest).series); });
  if (!panel.closest('[hidden]')) load();
}
