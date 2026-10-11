/* Private node tax reporting view. All external content goes via textContent. */
const api = '/api/node/tax';
const $ = (id) => document.getElementById(id);
const number = (n) => Number.isFinite(n) ? n.toLocaleString('en-AU') : '—';

async function json(url, options = {}) {
  const response = await fetch(url, { credentials: 'same-origin', cache: 'no-store', ...options });
  const data = await response.json().catch(() => ({ error: `HTTP ${response.status}` }));
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
  const summary = report.summary || {};
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
  for (const [ext, label] of [['csv', 'CSV'], ['json', 'JSON'], ['sha256', 'SHA-256']]) {
    const link = document.createElement('a');
    link.textContent = label;
    link.href = `${api}/download/${year}/${encodeURIComponent(digest)}/${ext}`;
    link.setAttribute('download', '');
    link.setAttribute('aria-label', `Download FY ${year} ${label}`);
    links.appendChild(link);
  }
  linksCell.appendChild(links);
  return row;
}

async function loadReports() {
  const feedback = $('feedback');
  try {
    const { reports = [] } = await json(`${api}/reports`);
    const rows = $('reportRows');
    rows.replaceChildren(...reports.map(reportRow));
    $('reportCount').textContent = number(reports.length);
    // Old immutable report revisions contain many of the same transactions.
    // Count the most recently generated report from each FY exactly once.
    const latest = new Map();
    for (const report of reports) {
      const prev = latest.get(report.tax_year_end);
      if (!prev || report.generated_at > prev.generated_at) latest.set(report.tax_year_end, report);
    }
    const currentYears = [...latest.values()];
    $('eventCount').textContent = number(currentYears.reduce((n, r) => n + (r.summary?.total_events || 0), 0));
    $('reviewCount').textContent = number(currentYears.reduce((n, r) => n + (r.review_count || 0), 0));
    feedback.textContent = reports.length ? `${reports.length} immutable report revision(s) found.` : 'No reports yet. Run a historical backfill to create drafts from settled transactions.';
  } catch (err) {
    feedback.textContent = `Could not list reports: ${err.message}`;
  }
}

async function loadJob() {
  try {
    const { job = {} } = await json(`${api}/jobs`);
    const state = job.status || 'unknown';
    $('jobStatus').textContent = `Historical backfill: ${state.replaceAll('_', ' ')}`;
    $('jobDot').className = `dot ${state}`;
    const parts = [];
    if (job.source_events !== undefined) parts.push(`${number(job.source_events)} indexed source events`);
    if (job.imported_new_events !== undefined) parts.push(`${number(job.imported_new_events)} newly imported`);
    if (job.price_requests !== undefined) parts.push(`${number(job.price_requests)} historical price requests`);
    if (job.quote_failures?.length) parts.push(`${number(job.quote_failures.length)} price/report issues — review missing evidence in the manifests`);
    if (job.error) parts.push(`Error: ${job.error}`);
    $('jobDetail').textContent = parts.join(' · ');
    $('startBackfill').disabled = state === 'running';
    if (state === 'completed') await loadReports();
  } catch (err) {
    $('jobStatus').textContent = `Backfill status unavailable: ${err.message}`;
    $('startBackfill').disabled = true;
  }
}

function initYears() {
  const now = new Date();
  const currentFY = now.getUTCMonth() >= 6 ? now.getUTCFullYear() + 1 : now.getUTCFullYear();
  const select = $('scope');
  for (let year = currentFY; year >= currentFY - 15; year--) {
    const option = document.createElement('option');
    option.value = String(year);
    option.textContent = `FY ${year}`;
    select.appendChild(option);
  }
}

$('backfillForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const scope = $('scope').value;
  const body = scope === 'all' ? { scope: 'all' } : { year: Number(scope) };
  if ($('journalOnly').checked) body.source = 'journal';
  $('startBackfill').disabled = true;
  $('jobDetail').textContent = '';
  try {
    await json(`${api}/backfill`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Damage-Tax-Request': '1' },
      body: JSON.stringify(body)
    });
    $('jobStatus').textContent = 'Historical backfill started. Reports will be generated in the background.';
  } catch (err) {
    $('jobStatus').textContent = `Backfill not started: ${err.message}`;
    $('startBackfill').disabled = false;
  }
  await loadJob();
});
$('refresh').addEventListener('click', async () => {
  await Promise.all([loadReports(), loadJob()]);
});
initYears();
void Promise.all([loadReports(), loadJob()]);
setInterval(() => { void loadJob(); }, 6000);
