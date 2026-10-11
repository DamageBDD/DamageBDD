/* Private jurisdiction-aware report history and backfill controls.
 * API values are inserted via textContent; browser exports contain metadata
 * only. Permission checks, source ownership and tax profile validation are
 * enforced again on the server.
 */
const TAX_API = '/api/node/tax';
const PAGE_SIZE = 20;
const SHA256 = /^[0-9a-f]{64}$/;
const REGION = /^[A-Z]{2}$/;
const CURRENCY = /^[A-Z]{3}$/;
const safeInteger = (v, fallback = 0) => Number.isSafeInteger(v) ? v : fallback;

export function normalizeTaxReport(source) {
  if (!source || typeof source !== 'object' || Array.isArray(source)) return null;
  const year = source.tax_year_end;
  const hash = source.manifest_sha256;
  if (!Number.isSafeInteger(year) || year < 2009 || year > 2200 ||
      typeof hash !== 'string' || !SHA256.test(hash)) return null;
  // Old v1 reports have no country/period metadata and are Australian.
  const jurisdiction = source.jurisdiction ?? 'AU';
  const currency = source.currency ?? 'AUD';
  if (typeof jurisdiction !== 'string' || !REGION.test(jurisdiction) ||
      typeof currency !== 'string' || !CURRENCY.test(currency)) return null;
  const summary = source.summary && typeof source.summary === 'object' ? source.summary : {};
  const minor = (key, legacy) => safeInteger(summary[key], jurisdiction === 'AU' ? safeInteger(summary[legacy]) : 0);
  return {
    jurisdiction, currency, tax_year_end: year, manifest_sha256: hash,
    minor_digits: source.minor_digits === 0 ? 0 : 2,
    start_utc: safeInteger(source.start_utc),
    end_utc_exclusive: safeInteger(source.end_utc_exclusive),
    period_start_month: safeInteger(source.period_start_month, jurisdiction === 'AU' ? 7 : 1),
    evidence_set_sha256: typeof source.evidence_set_sha256 === 'string' && SHA256.test(source.evidence_set_sha256)
      ? source.evidence_set_sha256 : '',
    generated_at: Math.max(0, safeInteger(source.generated_at)),
    attestable: source.attestable === true,
    review_count: Math.max(0, safeInteger(source.review_count)),
    summary: {
      total_events: Math.max(0, safeInteger(summary.total_events)),
      ordinary_income_minor: minor('ordinary_income_minor', 'ordinary_income_cents'),
      expense_candidates_minor: minor('expense_candidates_minor', 'expense_candidates_cents'),
      cgt_raw_gains_minor: minor('cgt_raw_gains_minor', 'cgt_raw_gains_cents'),
      cgt_raw_losses_minor: minor('cgt_raw_losses_minor', 'cgt_raw_losses_cents')
    }
  };
}

export function periodKey(r) {
  return `${r.jurisdiction}:${r.tax_year_end}:${r.start_utc}:${r.end_utc_exclusive}:${r.period_start_month}`;
}

export function normalizeTaxReports(rows) {
  if (!Array.isArray(rows)) return [];
  const seen = new Set();
  return rows.map(normalizeTaxReport).filter(report => {
    if (!report) return false;
    const id = `${report.tax_year_end}:${report.manifest_sha256}`;
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  }).sort((a, b) => b.tax_year_end - a.tax_year_end ||
      a.jurisdiction.localeCompare(b.jurisdiction) || b.generated_at - a.generated_at ||
      b.manifest_sha256.localeCompare(a.manifest_sha256));
}

export function reportStatus(report) {
  return report.attestable && report.review_count === 0 ? 'ready' : 'review';
}

export function filterTaxReports(rows, filters = {}) {
  const {year = 'all', jurisdiction = 'all', status = 'all', revisions = 'latest', search = ''} = filters;
  const ordered = normalizeTaxReports(rows);
  const latest = new Set();
  const revisionFiltered = revisions === 'all' ? ordered : ordered.filter(r => {
    const key = periodKey(r);
    if (latest.has(key)) return false;
    latest.add(key);
    return true;
  });
  const query = String(search).trim().toLowerCase().slice(0, 128);
  return revisionFiltered.filter(r =>
    (year === 'all' || String(r.tax_year_end) === String(year)) &&
    (jurisdiction === 'all' || jurisdiction === r.jurisdiction) &&
    (status === 'all' || reportStatus(r) === status) &&
    (!query || (`fy ${r.tax_year_end}`).includes(query) || String(r.tax_year_end).includes(query) ||
      r.jurisdiction.toLowerCase().includes(query) || r.currency.toLowerCase().includes(query) ||
      r.manifest_sha256.includes(query) || r.evidence_set_sha256.includes(query)));
}

export function latestYearSummary(rows) {
  const current = filterTaxReports(rows, {revisions: 'latest'});
  return {
    years: current.length,
    events: current.reduce((n, r) => n + r.summary.total_events, 0),
    review: current.reduce((n, r) => n + r.review_count, 0)
  };
}

export function formatMinor(value, digits = 2) {
  if (!Number.isSafeInteger(value) || !Number.isInteger(digits) || digits < 0 || digits > 2) return '';
  const sign = value < 0 ? '-' : '';
  const abs = Math.abs(value);
  if (digits === 0) return sign + String(abs);
  const denominator = 10 ** digits;
  return `${sign}${Math.floor(abs / denominator)}.${String(abs % denominator).padStart(digits, '0')}`;
}
export const audCents = value => formatMinor(value, 2); // legacy public helper

function exportRecord(r) {
  const income = formatMinor(r.summary.ordinary_income_minor, r.minor_digits);
  const expense = formatMinor(r.summary.expense_candidates_minor, r.minor_digits);
  const gains = formatMinor(r.summary.cgt_raw_gains_minor, r.minor_digits);
  const losses = formatMinor(r.summary.cgt_raw_losses_minor, r.minor_digits);
  return {
    jurisdiction: r.jurisdiction, fiat_currency: r.currency,
    tax_year_end: r.tax_year_end, period_start_utc: r.start_utc,
    period_end_utc_exclusive: r.end_utc_exclusive,
    generated_at_unix: r.generated_at, status: reportStatus(r),
    transactions: r.summary.total_events, review_items: r.review_count,
    ordinary_income_fiat: income, expense_candidates_fiat: expense,
    cgt_raw_gains_fiat: gains, cgt_raw_losses_fiat: losses,
    // Existing Australian index consumers keep working; no fake AUD values.
    ordinary_income_aud: r.currency === 'AUD' ? income : '',
    expense_candidates_aud: r.currency === 'AUD' ? expense : '',
    cgt_raw_gains_aud: r.currency === 'AUD' ? gains : '',
    cgt_raw_losses_aud: r.currency === 'AUD' ? losses : '',
    manifest_sha256: r.manifest_sha256, evidence_set_sha256: r.evidence_set_sha256
  };
}

export function reportIndexRecords(rows) {
  return rows.map(r => exportRecord(normalizeTaxReport(r) || r));
}

function csvField(value) {
  let str = String(value ?? '');
  if (!/^-[0-9]+(?:\.[0-9]+)?$/.test(str) && /^[\s]*[=+\-@]/.test(str)) str = `'${str}`;
  return `"${str.replaceAll('"', '""')}"`;
}

export function reportIndexCsv(rows) {
  const records = reportIndexRecords(rows);
  const columns = ['jurisdiction', 'fiat_currency', 'tax_year_end', 'period_start_utc',
    'period_end_utc_exclusive', 'generated_at_unix', 'status', 'transactions',
    'review_items', 'ordinary_income_fiat', 'expense_candidates_fiat',
    'cgt_raw_gains_fiat', 'cgt_raw_losses_fiat',
    'ordinary_income_aud', 'expense_candidates_aud',
    'cgt_raw_gains_aud', 'cgt_raw_losses_aud',
    'manifest_sha256', 'evidence_set_sha256'];
  return [columns.map(csvField).join(','),
    ...records.map(record => columns.map(key => csvField(record[key])).join(','))].join('\r\n') + '\r\n';
}

async function apiJson(path, opts = {}) {
  const response = await fetch(`${TAX_API}/${path}`, {credentials: 'same-origin', cache: 'no-store', ...opts});
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(typeof body.error === 'string' ? body.error : `HTTP ${response.status}`);
  return body;
}

function textCell(row, text, className = '') {
  const cell = document.createElement('td');
  cell.textContent = String(text ?? '—');
  if (className) cell.className = className;
  row.appendChild(cell);
  return cell;
}

function dateLabel(seconds) {
  if (!Number.isSafeInteger(seconds) || seconds <= 0) return '—';
  return `${new Date(seconds * 1000).toLocaleString(undefined,
    {timeZone: 'UTC', dateStyle: 'medium', timeStyle: 'short'})} UTC`;
}

function makeRow(report) {
  const tr = document.createElement('tr');
  textCell(tr, report.jurisdiction);
  textCell(tr, report.currency);
  textCell(tr, `FY ${report.tax_year_end}`);
  textCell(tr, dateLabel(report.generated_at));
  textCell(tr, report.summary.total_events);
  textCell(tr, report.review_count);
  const status = reportStatus(report);
  textCell(tr, status === 'ready' ? 'Evidence review complete' : 'Review required', `tax-status tax-status-${status}`);
  const digest = textCell(tr, report.manifest_sha256, 'tax-digest');
  digest.title = report.manifest_sha256;
  const actions = document.createElement('td');
  actions.className = 'tax-download-links';
  for (const [fmt, label] of [['csv', 'Transactions CSV'], ['worksheet', 'Regional workpaper'],
    ['json', 'Manifest JSON'], ['sha256', 'SHA-256']]) {
    const a = document.createElement('a');
    a.href = `${TAX_API}/download/${report.tax_year_end}/${report.manifest_sha256}/${fmt}`;
    a.download = '';
    a.textContent = label;
    a.setAttribute('aria-label', `Download ${report.jurisdiction} FY ${report.tax_year_end} ${label}`);
    actions.appendChild(a);
  }
  tr.appendChild(actions);
  return tr;
}

function downloadIndex(filename, data, mime) {
  const blob = new Blob([data], {type: mime});
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function validateRegionProfile(p) {
  return p && typeof p === 'object' && REGION.test(p.code || '') &&
    CURRENCY.test(p.currency || '') && Number.isInteger(p.start_month) &&
    p.start_month >= 1 && p.start_month <= 12 &&
    Number.isInteger(p.start_day) && p.start_day >= 1 && p.start_day <= 28 &&
    Number.isInteger(p.default_offset_minutes) && p.default_offset_minutes >= -720 &&
    p.default_offset_minutes <= 840 && typeof p.name === 'string' && p.name.length > 0;
}

export function taxYearForDate(profile, date = new Date(), startMonth = profile.start_month,
  offset = profile.default_offset_minutes) {
  const local = new Date(date.getTime() + offset * 60000);
  const y = local.getUTCFullYear();
  const m = local.getUTCMonth() + 1;
  const d = local.getUTCDate();
  const day = startMonth === profile.start_month ? profile.start_day : 1;
  return startMonth === 1 && day === 1 ? y : (m > startMonth || (m === startMonth && d >= day) ? y + 1 : y);
}

export function buildBackfillPayload(region, offset, month, selected, journal) {
  if (!REGION.test(region) || !Number.isInteger(offset) || offset < -720 || offset > 840 ||
      !Number.isInteger(month) || month < 1 || month > 12) throw Error('Invalid tax reporting period');
  const payload = selected === 'all' ? {scope: 'all'} : {year: Number(selected)};
  if (payload.year !== undefined && (!Number.isSafeInteger(payload.year) || payload.year < 2009 || payload.year > 2200)) {
    throw Error('Invalid reporting year');
  }
  if (journal) payload.source = 'journal';
  return {...payload, jurisdiction: region, standard_utc_offset_minutes: offset, period_start_month: month};
}

export function initDashboardTaxReports() {
  if (typeof document === 'undefined') return null;
  const panel = document.getElementById('node-tax-reports-tab');
  const root = document.getElementById('tax-reports-enabled');
  if (!panel || !root) return null;
  const byId = id => root.querySelector(`#${id}`);
  const filterYear = byId('tax-filter-year');
  const filterRegion = byId('tax-filter-jurisdiction');
  const backfillYear = byId('tax-backfill-year');
  const backfillRegion = byId('tax-backfill-jurisdiction');
  const offsetInput = byId('tax-backfill-offset');
  const monthInput = byId('tax-backfill-month');
  let reports = [], visible = [], page = 0, loaded = false, refreshing = false;
  let previousJobStatus, jobRunning = false, profilesReady = false;
  let profiles = new Map();

  function filters() {
    return {jurisdiction: filterRegion.value, year: filterYear.value,
      status: byId('tax-filter-status').value,
      revisions: byId('tax-filter-revisions').value,
      search: byId('tax-filter-search').value};
  }

  function populate(select, values, prefix) {
    const existing = select.value;
    while (select.options.length > 1) select.remove(1);
    for (const value of values) {
      const option = document.createElement('option');
      option.value = String(value);
      option.textContent = `${prefix}${value}`;
      select.appendChild(option);
    }
    select.value = [...select.options].some(o => o.value === existing) ? existing : 'all';
  }

  function syncYears() {
    const years = [...new Set(reports.filter(r =>
      filterRegion.value === 'all' || r.jurisdiction === filterRegion.value).map(r => r.tax_year_end))]
      .sort((a, b) => b - a);
    const p = profiles.get(backfillRegion.value);
    const current = p ? taxYearForDate(p, new Date(), Number(monthInput.value), Number(offsetInput.value)) :
      new Date().getUTCFullYear();
    const historical = Array.from({length: 16}, (_, n) => current - n);
    const reported = reports.filter(r => r.jurisdiction === backfillRegion.value)
      .map(r => r.tax_year_end);
    populate(filterYear, years, 'FY ');
    populate(backfillYear, [...new Set([...reported, ...historical])].sort((a, b) => b - a), 'FY ');
  }

  function applyRegion() {
    const p = profiles.get(backfillRegion.value);
    if (!p) { profilesReady = false; byId('tax-backfill-run').disabled = true; return; }
    offsetInput.value = String(p.default_offset_minutes);
    monthInput.value = String(p.start_month);
    monthInput.disabled = p.custom_period !== true;
    profilesReady = true;
    byId('tax-backfill-run').disabled = jobRunning;
    syncYears();
  }

  async function loadRegions() {
    try {
      const body = await apiJson('jurisdictions');
      if (!Array.isArray(body.jurisdictions)) throw Error('invalid_jurisdiction_catalog');
      const incoming = body.jurisdictions.filter(validateRegionProfile);
      if (!incoming.length) throw Error('empty_jurisdiction_catalog');
      profiles = new Map(incoming.map(p => [p.code, p]));
      for (const sel of [filterRegion, backfillRegion]) {
        const old = sel.value;
        if (sel === filterRegion) while (sel.options.length > 1) sel.remove(1);
        else sel.replaceChildren();
        for (const p of incoming) {
          const opt = document.createElement('option');
          opt.value = p.code;
          opt.textContent = `${p.name} (${p.code})`;
          sel.appendChild(opt);
        }
        if (sel === filterRegion) sel.value = old && (old === 'all' || profiles.has(old)) ? old : 'all';
        else sel.value = profiles.has(body.default_jurisdiction) ? body.default_jurisdiction : incoming[0].code;
      }
      applyRegion();
    } catch (err) {
      profilesReady = false;
      byId('tax-backfill-run').disabled = true;
      byId('tax-backfill-status').textContent = `Reporting countries unavailable: ${err.message}`;
    }
  }

  function render() {
    visible = filterTaxReports(reports, filters());
    const maxPage = Math.max(0, Math.ceil(visible.length / PAGE_SIZE) - 1);
    page = Math.min(page, maxPage);
    const tbody = byId('tax-reports-rows');
    const rows = visible.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    tbody.replaceChildren(...rows.map(makeRow));
    if (!rows.length) {
      const tr = document.createElement('tr');
      const td = textCell(tr, reports.length ? 'No reports match these filters.' :
        'No reports found. Generate a country-specific draft below.');
      td.colSpan = 9;
      tbody.appendChild(tr);
    }
    const summary = latestYearSummary(reports);
    byId('tax-years-count').textContent = String(summary.years);
    byId('tax-events-count').textContent = String(summary.events);
    byId('tax-review-count').textContent = String(summary.review);
    byId('tax-reports-count').textContent = `${visible.length} matching report${visible.length === 1 ? '' : 's'} (${reports.length} revisions)`;
    byId('tax-page-label').textContent = `Page ${page + 1} of ${maxPage + 1}`;
    byId('tax-prev-page').disabled = page === 0;
    byId('tax-next-page').disabled = page >= maxPage;
    byId('tax-export-csv').disabled = visible.length === 0;
    byId('tax-export-json').disabled = visible.length === 0;
  }

  async function refreshReports() {
    if (refreshing) return;
    refreshing = true;
    byId('tax-reports-refresh').disabled = true;
    try {
      const body = await apiJson('reports');
      if (!Array.isArray(body.reports)) throw Error('invalid_report_catalog');
      reports = normalizeTaxReports(body.reports);
      loaded = true;
      syncYears();
      render();
    } catch (err) {
      if (!loaded) { reports = []; render(); }
      byId('tax-reports-count').textContent = `Reports unavailable: ${err.message}`;
    } finally {
      refreshing = false;
      byId('tax-reports-refresh').disabled = false;
    }
  }

  async function refreshJob() {
    try {
      const {job = {}} = await apiJson('jobs');
      const state = typeof job.status === 'string' ? job.status : 'unknown';
      jobRunning = state === 'running';
      const info = [`Backfill: ${state.replaceAll('_', ' ')}`];
      if (typeof job.jurisdiction === 'string') info.push(job.jurisdiction);
      if (Number.isSafeInteger(job.source_events)) info.push(`${job.source_events} source events`);
      if (Number.isSafeInteger(job.imported_new_events)) info.push(`${job.imported_new_events} imported`);
      if (Number.isSafeInteger(job.price_requests)) info.push(`${job.price_requests} price requests`);
      if (Array.isArray(job.quote_failures) && job.quote_failures.length) info.push(`${job.quote_failures.length} unresolved items`);
      byId('tax-backfill-status').textContent = info.join(' · ');
      byId('tax-backfill-detail').textContent = typeof job.error === 'string' ? job.error : '';
      byId('tax-backfill-run').disabled = jobRunning || !profilesReady;
      if (previousJobStatus === 'running' && state === 'completed') void refreshReports();
      previousJobStatus = state;
    } catch (err) {
      byId('tax-backfill-status').textContent = `Backfill unavailable: ${err.message}`;
      byId('tax-backfill-run').disabled = true;
    }
  }

  function applyFilters() { page = 0; syncYears(); render(); }
  filterRegion.addEventListener('change', applyFilters);
  for (const id of ['tax-filter-year', 'tax-filter-status', 'tax-filter-revisions']) {
    byId(id).addEventListener('change', applyFilters);
  }
  byId('tax-filter-search').addEventListener('input', applyFilters);
  backfillRegion.addEventListener('change', applyRegion);
  offsetInput.addEventListener('change', syncYears);
  monthInput.addEventListener('change', syncYears);
  byId('tax-prev-page').addEventListener('click', () => { page -= 1; render(); });
  byId('tax-next-page').addEventListener('click', () => { page += 1; render(); });
  byId('tax-reports-refresh').addEventListener('click', () => void Promise.all([refreshReports(), refreshJob()]));
  byId('tax-export-csv').addEventListener('click', () => {
    if (visible.length) downloadIndex('damagebdd-tax-report-index.csv', '\ufeff' + reportIndexCsv(visible), 'text/csv;charset=utf-8');
  });
  byId('tax-export-json').addEventListener('click', () => {
    if (visible.length) downloadIndex('damagebdd-tax-report-index.json', JSON.stringify({
      schema: 'damagebdd-tax-catalog-export/v2', filters: filters(),
      caution: 'Metadata only. Country workpapers are not official tax filings.',
      reports: reportIndexRecords(visible)
    }, null, 2) + '\n', 'application/json;charset=utf-8');
  });
  byId('tax-backfill-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (!profilesReady) return;
    byId('tax-backfill-run').disabled = true;
    try {
      const p = profiles.get(backfillRegion.value);
      const offset = Number(offsetInput.value), month = Number(monthInput.value);
      if (!p || (p.custom_period !== true && month !== p.start_month)) {
        throw Error('Unsupported country reporting period');
      }
      const payload = buildBackfillPayload(p.code, offset, month, backfillYear.value,
        byId('tax-backfill-journal').checked);
      await apiJson('backfill', {method: 'POST', headers: {
        'Content-Type': 'application/json', 'X-Damage-Tax-Request': '1'
      }, body: JSON.stringify(payload)});
      byId('tax-backfill-status').textContent = `${p.name} (${p.currency}) backfill started. Review draft workpapers when complete.`;
      previousJobStatus = 'running';
    } catch (err) {
      byId('tax-backfill-status').textContent = `Backfill not started: ${err.message}`;
      byId('tax-backfill-run').disabled = !profilesReady;
    }
    await refreshJob();
  });

  function onActive() {
    if (!loaded) void Promise.all([loadRegions(), refreshReports(), refreshJob()]);
    else void refreshJob();
  }
  document.addEventListener('damage:panelchange', event => {
    if (event.detail?.id === 'node-tax-reports-tab') onActive();
  });
  if (!panel.hidden || window.location.hash === '#node-tax-reports-tab') onActive();
  window.setInterval(() => { if (!panel.hidden) void refreshJob(); }, 8000);
  return {refreshReports, refreshJob, loadRegions};
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initDashboardTaxReports, {once: true});
  else initDashboardTaxReports();
}
