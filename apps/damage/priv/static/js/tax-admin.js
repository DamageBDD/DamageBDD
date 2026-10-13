/* Legacy standalone private tax view. Keep in sync with the main dashboard:
 * only fixed, server-provided jurisdictions and explicit financial periods.
 */
const api = '/api/node/tax';
const $ = id => document.getElementById(id);
const number = n => Number.isFinite(n) ? n.toLocaleString() : '—';
let profiles = new Map();
let configured = false;
let running = false;

async function json(url, options = {}) {
  const response = await fetch(url, {credentials: 'same-origin', cache: 'no-store', ...options});
  const data = await response.json().catch(() => ({error: `HTTP ${response.status}`}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function cell(row, value, className) {
  const td = document.createElement('td');
  td.textContent = String(value ?? '—');
  if (className) td.className = className;
  row.appendChild(td);
  return td;
}

function reportRow(report) {
  const row = document.createElement('tr');
  const year = Number(report.tax_year_end);
  const digest = report.manifest_sha256;
  const region = report.jurisdiction || 'AU';
  const currency = report.currency || 'AUD';
  const summary = report.summary || {};
  cell(row, region);
  cell(row, currency);
  cell(row, `FY ${year}`);
  cell(row, number(summary.total_events));
  cell(row, number(report.review_count));
  const statusCell = cell(row, '');
  const status = document.createElement('span');
  status.className = `status ${report.attestable ? 'ready' : 'review'}`;
  status.textContent = report.attestable ? 'Evidence review complete' : 'Review required';
  statusCell.appendChild(status);
  const fingerprint = cell(row, digest, 'mono');
  fingerprint.title = digest;
  const linksCell = cell(row, '');
  const links = document.createElement('div');
  links.className = 'downloads';
  for (const [ext, label] of [['csv', 'CSV'], ['worksheet', 'Workpaper'],
                              ['json', 'JSON'], ['sha256', 'SHA-256']]) {
    const link = document.createElement('a');
    link.textContent = label;
    link.href = `${api}/download/${year}/${encodeURIComponent(digest)}/${ext}`;
    link.setAttribute('download', '');
    link.setAttribute('aria-label', `Download ${region} FY ${year} ${label}`);
    links.appendChild(link);
  }
  linksCell.appendChild(links);
  return row;
}

async function loadReports() {
  const feedback = $('feedback');
  try {
    const {reports = []} = await json(`${api}/reports`);
    const rows = $('reportRows');
    rows.replaceChildren(...reports.map(reportRow));
    $('reportCount').textContent = number(reports.length);
    const latest = new Map();
    for (const report of reports) {
      const key = [report.jurisdiction || 'AU', report.tax_year_end,
        report.start_utc || 0, report.end_utc_exclusive || 0].join(':');
      const prev = latest.get(key);
      if (!prev || report.generated_at > prev.generated_at) latest.set(key, report);
    }
    const current = [...latest.values()];
    $('eventCount').textContent = number(current.reduce((n, r) => n + (r.summary?.total_events || 0), 0));
    $('reviewCount').textContent = number(current.reduce((n, r) => n + (r.review_count || 0), 0));
    feedback.textContent = reports.length ? `${reports.length} immutable report revision(s).` :
      'No reports yet. Run a historical backfill to create a regional draft.';
  } catch (err) {
    feedback.textContent = `Could not list reports: ${err.message}`;
  }
}

async function loadJob() {
  try {
    const {job = {}} = await json(`${api}/jobs`);
    const state = job.status || 'unknown';
    running = state === 'running';
    $('jobStatus').textContent = `Historical backfill: ${state.replaceAll('_', ' ')}`;
    $('jobDot').className = `dot ${state}`;
    const parts = [];
    if (job.jurisdiction) parts.push(`Country: ${job.jurisdiction}`);
    if (job.source_events !== undefined) parts.push(`${number(job.source_events)} source events`);
    if (job.imported_new_events !== undefined) parts.push(`${number(job.imported_new_events)} imported`);
    if (job.price_requests !== undefined) parts.push(`${number(job.price_requests)} historical price requests`);
    if (job.quote_failures?.length) parts.push(`${job.quote_failures.length} price/report issues`);
    if (job.error) parts.push(`Error: ${job.error}`);
    $('jobDetail').textContent = parts.join(' · ');
    $('startBackfill').disabled = running || !configured;
    if (state === 'completed') await loadReports();
  } catch (err) {
    $('jobStatus').textContent = `Backfill status unavailable: ${err.message}`;
    $('startBackfill').disabled = true;
  }
}

function syncYearOptions() {
  const p = profiles.get($('region').value);
  if (!p) return;
  const month = Number($('startMonth').value);
  const offset = Number($('offset').value);
  const now = new Date(Date.now() + offset * 60000);
  const y = now.getUTCFullYear(), m = now.getUTCMonth() + 1, d = now.getUTCDate();
  const day = month === p.start_month ? p.start_day : 1;
  const fy = month === 1 && day === 1 ? y : (m > month || (m === month && d >= day) ? y + 1 : y);
  const select = $('scope');
  const old = select.value;
  while (select.options.length > 1) select.remove(1);
  for (let year = fy; year >= fy - 15; year--) {
    const o = document.createElement('option');
    o.value = String(year);
    o.textContent = `FY ${year}`;
    select.appendChild(o);
  }
  select.value = [...select.options].some(o => o.value === old) ? old : 'all';
}

function applyRegion() {
  const p = profiles.get($('region').value);
  if (!p) {configured = false; $('startBackfill').disabled = true; return;}
  $('offset').value = String(p.default_offset_minutes);
  $('startMonth').value = String(p.start_month);
  $('startMonth').disabled = p.custom_period !== true;
  configured = true;
  $('startBackfill').disabled = running;
  syncYearOptions();
}

async function loadRegions() {
  try {
    const body = await json(`${api}/jurisdictions`);
    const rows = Array.isArray(body.jurisdictions) ? body.jurisdictions.filter(p =>
      /^[A-Z]{2}$/.test(p.code) && /^[A-Z]{3}$/.test(p.currency) &&
      Number.isInteger(p.start_month) && p.start_month >= 1 && p.start_month <= 12 &&
      Number.isInteger(p.default_offset_minutes) && p.default_offset_minutes >= -720 &&
      p.default_offset_minutes <= 840) : [];
    if (!rows.length) throw Error('invalid_jurisdiction_catalog');
    profiles = new Map(rows.map(p => [p.code, p]));
    for (const p of rows) {
      const o = document.createElement('option');
      o.value = p.code;
      o.textContent = `${p.name} (${p.code})`;
      $('region').appendChild(o);
    }
    $('region').value = profiles.has(body.default_jurisdiction) ? body.default_jurisdiction : rows[0].code;
    applyRegion();
  } catch (err) {
    $('jobStatus').textContent = `Jurisdictions unavailable: ${err.message}`;
    $('startBackfill').disabled = true;
  }
}

$('backfillForm').addEventListener('submit', async ev => {
  ev.preventDefault();
  const p = profiles.get($('region').value);
  if (!configured || !p) return;
  const month = Number($('startMonth').value);
  const offset = Number($('offset').value);
  if (!Number.isInteger(month) || month < 1 || month > 12 ||
      (!p.custom_period && month !== p.start_month) ||
      !Number.isInteger(offset) || offset < -720 || offset > 840) {
    $('jobStatus').textContent = 'Invalid reporting period or time zone offset';
    return;
  }
  const scope = $('scope').value;
  const body = scope === 'all' ? {scope: 'all'} : {year: Number(scope)};
  body.jurisdiction = p.code;
  body.standard_utc_offset_minutes = offset;
  body.period_start_month = month;
  if ($('journalOnly').checked) body.source = 'journal';
  $('startBackfill').disabled = true;
  $('jobDetail').textContent = '';
  try {
    await json(`${api}/backfill`, {
      method: 'POST', headers: {'Content-Type': 'application/json', 'X-Damage-Tax-Request': '1'},
      body: JSON.stringify(body)
    });
    $('jobStatus').textContent = `${p.name} (${p.currency}) backfill started. Reports are draft workpapers.`;
  } catch (err) {
    $('jobStatus').textContent = `Backfill not started: ${err.message}`;
    $('startBackfill').disabled = !configured;
  }
  await loadJob();
});
$('region').addEventListener('change', applyRegion);
$('startMonth').addEventListener('change', syncYearOptions);
$('offset').addEventListener('change', syncYearOptions);
$('refresh').addEventListener('click', async () => Promise.all([loadReports(), loadJob()]));
$('startBackfill').disabled = true;
void Promise.all([loadRegions(), loadReports(), loadJob()]);
setInterval(() => { void loadJob(); }, 6000);
