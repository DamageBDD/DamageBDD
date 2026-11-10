/* A single feature/context renderer. No feature-specific UI, descriptors, eval,
 * HTML injection, background executions or automatic POST retries. */
export function stateLabel(job) {
  const s = job?.state;
  if (s === 'running') return job.mode === 'preview' ? 'Preparing estimate' : 'Checks running';
  return ({ready: 'Ready for approval', passed: 'Checks passed', failed: 'Checks failed',
    blocked: 'Execution blocked', pending: 'Settlement pending', indeterminate: 'Outcome unconfirmed',
    error: 'Service error'})[s] || 'Not run';
}
export function costLabel(job) {
  if (Number.isFinite(job?.cost_damage)) return `${job.cost_damage.toLocaleString(undefined, {maximumFractionDigits: 8})} DAMAGE`;
  const hits = job?.cost_hits ?? job?.cost;
  return Number.isFinite(hits) ? `${hits.toLocaleString()} HITS` : 'Estimate unavailable';
}
export function canApprove(job, feature, now = Date.now()) {
  return job?.mode === 'preview' && job.state === 'ready' && !job.approved_job &&
    job.sha256 === feature?.sha256 && Number.isFinite(job.approval_expires_at) &&
    job.approval_expires_at * 1000 > now;
}
export function reportPath(hash) {
  // Construct a same-origin report path; do not accept URLs or arbitrary paths.
  return typeof hash === 'string' && /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{30,120})$/.test(hash)
    ? `/reports/${encodeURIComponent(hash)}/` : null;
}
export function previewPayload(feature, values, requestId) {
  const inputs = {};
  for (const field of feature.fields || []) {
    if (!field.editable) continue;
    const value = String(values[field.key] ?? '');
    if (value.trim() || !field.configured) inputs[field.key] = value;
  }
  return {feature_id: feature.id, sha256: feature.sha256, inputs, request_id: requestId};
}
export function friendlyError(error) {
  if (error?.status === 401) return 'Your session has expired. Sign in again.';
  if (error?.status === 403) return 'This account is not authorised for this operation.';
  if (error?.status === 429) return 'A verification is already running, or the node has reached its limit. Refresh recent checks.';
  const explanations = {
    context_required: 'Configure the missing context values before estimating this feature.',
    context_unavailable: 'The node could not read the required context. Check its secret store and configuration.',
    context_changed: 'Context changed after approval. Review the current inputs and create a new estimate.',
    context_or_code_changed: 'Context or executable code changed. Create and review a new estimate.',
    feature_changed: 'The deployed feature changed. Refresh the catalog and review it again.',
    step_validation_failed: 'Some steps are unavailable or not authorised for this account.',
    estimate_changed: 'The new cost exceeds the approved estimate. No execution was started.',
    approval_expired: 'This estimate expired. Review the inputs and request another estimate.',
    approval_consumed: 'This approval has already been used. Inspect run history before proceeding.',
    preview_not_ready: 'An approved, completed estimate is required before execution.',
    preview_failed: 'Preflight did not pass. Review the context, account balance and node prerequisites.',
    verification_failed: 'At least one check failed. Review the step results and the native report.',
    report_unavailable: 'A completed result was returned without report evidence. Do not assume the check passed.',
    settlement_pending: 'Execution ended but payment confirmation is pending. Do not rerun; inspect the settlement transaction.',
    deadline_exceeded: 'The workspace deadline was reached. The outcome may be partial; inspect native reports before rerunning.',
    not_found: 'This workspace record is no longer available. Inspect the native run history; do not assume nothing ran.',
    invalid_inputs: 'An input is invalid, protected or no longer editable. Refresh the feature and check its context.',
    runner_failed: 'The runner stopped without a confirmed outcome. Inspect native reports before rerunning.',
    worker_stopped: 'The worker stopped without a confirmed outcome. Inspect native reports before rerunning.',
    execution_unconfirmed: 'The execution outcome is unconfirmed. Inspect native reports before rerunning.'
  };
  return explanations[error?.code || error?.error] ||
    (error?.name === 'AbortError' ? 'The request timed out. Refresh status before submitting another operation.' :
      'Verification is unavailable. Check the node and refresh explicitly.');
}

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = String(text);
  if (className) node.className = className;
  return node;
}
function button(text, action, className = 'workspace-button') {
  const node = element('button', text, className); node.type = 'button';
  node.addEventListener('click', action); return node;
}
function timeLabel(seconds) {
  return Number.isFinite(seconds) ? new Date(seconds * 1000).toLocaleString() : '—';
}

export function mountVerification(root) {
  if (!root || root.dataset.verificationMounted) return null;
  root.dataset.verificationMounted = 'true';
  const find = selector => root.querySelector(selector);
  const catalogNode = find('[data-v-catalog]'), detailNode = find('[data-v-detail]');
  const historyNode = find('[data-v-history]'), messageNode = find('[data-v-message]');
  const refresh = find('[data-v-refresh]'), search = find('[data-v-search]');
  const panel = root.closest('[data-dashboard-view]');
  const visible = () => !root.closest('[hidden]') && !document.hidden;
  const auth = () => { try { return window.TokenManager?.getToken(); } catch { return undefined; } };
  const state = {features: [], feature: null, job: null, loaded: false, loading: false,
    submitting: false, selecting: false, epoch: 0, selection: 0, pollBusy: false,
    inputs: {}, controllers: new Set(), timer: null, expiryTimer: null};
  const busy = () => state.submitting || state.selecting || state.job?.state === 'running';
  let destroyed = false;

  function notify(message, tone = 'info') {
    messageNode.textContent = message; messageNode.dataset.tone = tone;
  }
  async function api(path, body) {
    const controller = new AbortController(), epoch = state.epoch;
    state.controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), 20000);
    const token = auth();
    const headers = {'Accept': 'application/json', 'X-Damage-Auth': '1', 'X-Damage-Verification': '1'};
    if (typeof token === 'string' && token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    try {
      const response = await fetch(`/api/verification/${path}`, {
        method: body === undefined ? 'GET' : 'POST', headers,
        credentials: 'same-origin', cache: 'no-store', signal: controller.signal,
        ...(body === undefined ? {} : {body: JSON.stringify(body)})
      });
      const result = await response.json();
      if (epoch !== state.epoch || destroyed) throw new DOMException('Stale identity', 'AbortError');
      if (!response.ok) { const error = new Error('Request rejected'); error.status = response.status; error.code = result?.error; throw error; }
      if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('Invalid API result');
      return result;
    } finally { clearTimeout(timer); state.controllers.delete(controller); }
  }
  function stopPolling() { clearTimeout(state.timer); state.timer = null; }
  function controls() {
    const locked = busy();
    refresh.disabled = state.loading || state.submitting;
    root.querySelectorAll('[data-v-card]').forEach(n => { n.disabled = locked || n.dataset.unavailable === 'true'; });
    root.querySelectorAll('[data-v-input]').forEach(n => { n.disabled = locked; });
    const estimate = find('[data-v-estimate]');
    if (estimate) {
      const missing = (state.feature?.fields || []).some(f => !f.configured && (!f.editable || !state.inputs[f.key]?.trim()));
      estimate.disabled = locked || !state.feature?.runnable || missing || ['pending', 'indeterminate'].includes(state.job?.state);
    }
    const approval = find('[data-v-approval]'), run = find('[data-v-run]');
    if (run) run.disabled = locked || !approval?.checked || !canApprove(state.job, state.feature);
    if (approval) approval.disabled = locked || !canApprove(state.job, state.feature);
  }
  function renderCatalog() {
    const query = search.value.trim().toLowerCase(); catalogNode.replaceChildren();
    const matches = state.features.filter(f => `${f.title} ${f.description || ''} ${(f.tags || []).join(' ')}`.toLowerCase().includes(query));
    for (const feature of matches) {
      const card = button('', () => void selectFeature(feature.id), 'verification-card');
      card.dataset.vCard = feature.id; card.dataset.unavailable = String(!feature.available);
      card.setAttribute('aria-pressed', String(state.feature?.id === feature.id));
      card.append(element('span', feature.available ? 'CHECK' : 'UNAVAILABLE', 'verification-eyebrow'));
      card.append(element('strong', feature.title || 'Unnamed feature'));
      card.append(element('span', `${(feature.scenarios || []).length} scenarios`, 'verification-muted'));
      const tags = element('span', undefined, 'verification-tags');
      for (const tag of (feature.tags || []).slice(0, 8)) tags.append(element('span', tag, 'verification-tag'));
      card.append(tags); catalogNode.append(card);
    }
    if (!matches.length) catalogNode.append(element('p', state.features.length ? 'No matching checks.' : 'No deployed features are available.', 'verification-empty'));
    controls();
  }
  async function loadCatalog() {
    if (!visible() || state.loading || destroyed) return;
    state.loading = true; state.loaded = true; const epoch = state.epoch; controls();
    notify('Reading deployed features…');
    try {
      const data = await api('catalog');
      if (epoch !== state.epoch) return;
      state.features = Array.isArray(data.features) ? data.features : []; renderCatalog();
      notify('Choose a feature to review. Nothing executes until you approve its estimate.');
    } catch (error) { if (epoch === state.epoch) notify(friendlyError(error), 'error'); }
    finally { if (epoch === state.epoch) { state.loading = false; controls(); } }
  }
  async function loadHistory() {
    const epoch = state.epoch;
    try {
      const data = await api('history'); if (epoch !== state.epoch) return;
      historyNode.replaceChildren();
      for (const job of data.jobs || []) {
        const row = button('', () => void openJob(job), 'verification-history-row');
        const feature = state.features.find(f => f.id === job.feature_id);
        row.append(element('strong', feature?.title || 'Verification'));
        row.append(element('span', `${job.mode === 'preview' ? 'Estimate' : 'Execution'} · ${stateLabel(job)}`));
        row.append(element('span', timeLabel(job.created_at), 'verification-muted'));
        historyNode.append(row);
      }
      if (!historyNode.childNodes.length) historyNode.append(element('p', 'No recent checks on this node for this account.', 'verification-empty'));
    } catch (error) { if (epoch === state.epoch) historyNode.replaceChildren(element('p', friendlyError(error), 'verification-muted')); }
  }
  async function selectFeature(id, {job = null} = {}) {
    if (busy() && !job) return;
    const selection = ++state.selection, epoch = state.epoch;
    stopPolling(); clearTimeout(state.expiryTimer);
    state.selecting = true; state.job = null; state.feature = null; controls();
    detailNode.replaceChildren(element('p', 'Reading feature and safe context…', 'verification-empty'));
    try {
      const feature = await api(`features/${encodeURIComponent(id)}`);
      if (selection !== state.selection || epoch !== state.epoch) return;
      state.feature = feature;
      state.inputs = Object.fromEntries((feature.fields || []).filter(f => f.editable).map(f => [f.key, String(f.value || '')]));
      state.job = job; renderDetail(); renderCatalog();
      if (job) { renderJob(); schedulePoll(); }
      notify(feature.runnable ? 'Review the scope and context, then request an estimate.' : 'This feature has unavailable or unauthorised steps.', feature.runnable ? 'info' : 'error');
    } catch (error) { if (epoch === state.epoch && selection === state.selection) { detailNode.replaceChildren(element('p', friendlyError(error))); notify(friendlyError(error), 'error'); } }
    finally { if (epoch === state.epoch && selection === state.selection) { state.selecting = false; controls(); } }
  }
  function renderDetail() {
    const feature = state.feature; detailNode.replaceChildren();
    detailNode.append(element('p', 'FEATURE / CONTEXT / EVIDENCE', 'verification-eyebrow'));
    detailNode.append(element('h2', feature.title));
    detailNode.append(element('p', feature.description || 'Read the feature source to inspect its full scope.', 'verification-description'));
    const checks = element('section', undefined, 'verification-checks'); checks.append(element('h3', 'What will be checked'));
    for (const scenario of feature.scenarios || []) {
      const line = element('div', undefined, 'verification-scenario'); line.dataset.vScenario = scenario.line;
      line.append(element('span', '○', 'verification-check-icon'), element('span', scenario.title)); checks.append(line);
    }
    detailNode.append(checks);
    if (!feature.runnable) {
      const notices = element('div', undefined, 'verification-notice');
      notices.append(element('strong', 'Not executable for this account or build'));
      for (const d of feature.validation?.diagnostics || []) notices.append(element('p', `Line ${d.line || '—'}: ${d.message}`));
      detailNode.append(notices);
    }
    const form = element('form', undefined, 'verification-form'); form.dataset.vForm = '';
    form.append(element('h3', 'Execution context'));
    const fields = feature.fields || [];
    if (!fields.length) form.append(element('p', 'Uses this node’s configured context. There are no editable inputs.', 'verification-muted'));
    for (const f of fields) {
      const group = element('div', undefined, 'verification-field'), id = `verification-input-${f.key}`;
      const label = element('label', f.label || f.key); label.htmlFor = id; group.append(label);
      if (f.editable) {
        const input = element('input'); input.type = 'text'; input.id = id; input.name = f.key;
        input.dataset.vInput = f.key; input.value = state.inputs[f.key] || ''; input.maxLength = 1024;
        input.autocomplete = 'off'; input.spellcheck = false; input.required = !f.configured;
        input.addEventListener('input', () => {
          state.inputs[f.key] = input.value;
          if (state.job && state.job.state !== 'running') { state.job = null; renderJob(); }
          controls();
        });
        group.append(input, element('small', f.configured ? 'Safe context value; overridable for this run.' : 'Required input; kept in the run context.'));
      } else {
        group.append(element('p', f.sensitive && f.configured ? 'Provided securely by the server context' :
          f.configured ? (f.value || 'Configured; not editable here') : 'Missing: configure this protected value in the context workspace.', 'verification-fixed'));
      }
      form.append(group);
    }
    const estimate = element('button', 'Review & estimate', 'workspace-button verification-primary');
    estimate.type = 'submit'; estimate.dataset.vEstimate = ''; form.append(estimate);
    form.addEventListener('submit', event => { event.preventDefault(); if (!estimate.disabled && form.reportValidity()) void preview(); });
    detailNode.append(form);
    const jobArea = element('section', undefined, 'verification-job'); jobArea.dataset.vJob = ''; jobArea.setAttribute('aria-label', 'Execution status');
    detailNode.append(jobArea);
    const details = element('details', undefined, 'verification-source');
    details.append(element('summary', 'View the feature and execution steps'));
    details.append(element('p', `Source SHA-256: ${feature.sha256}`, 'verification-hash'));
    details.append(element('pre', feature.source || 'Source unavailable'));
    detailNode.append(details); renderJob(); controls();
  }
  function updateProgress() {
    const outcomes = new Map((state.job?.sha256 === state.feature?.sha256 ? (state.job?.progress || []) : []).map(p => [p.line, p.state]));
    for (const scenario of state.feature?.scenarios || []) {
      const node = root.querySelector(`[data-v-scenario="${Number(scenario.line)}"]`); if (!node) continue;
      const steps = [...(state.feature.background || []), ...(scenario.steps || [])];
      const states = steps.map(s => outcomes.get(s.line));
      const outcome = states.includes('failed') ? 'failed' : states.length && states.every(s => s === 'passed') ? 'passed' : states.includes('skipped') ? 'skipped' : 'pending';
      node.dataset.state = outcome;
      node.firstChild.textContent = ({passed: '✓', failed: '×', skipped: '−', pending: '○'})[outcome];
      node.setAttribute('aria-label', `${scenario.title}: ${outcome}`);
    }
  }
  function renderJob() {
    const area = find('[data-v-job]'); if (!area) return;
    clearTimeout(state.expiryTimer); area.replaceChildren(); updateProgress();
    const job = state.job; if (!job) { controls(); return; }
    area.dataset.state = job.state;
    const heading = element('h3', stateLabel(job)); heading.setAttribute('role', 'status'); area.append(heading);
    area.append(element('p', job.mode === 'preview' ? 'This is an estimate, not a verification result.' :
      'This result applies only to the feature, context and code recorded for this run.', 'verification-muted'));
    if (job.error) area.append(element('p', friendlyError({error: job.error}), 'verification-notice'));
    if (job.sha256 !== state.feature.sha256) area.append(element('p', 'The deployed feature has changed since this record. Its current scenario list is not evidence of what ran.', 'verification-notice'));
    if (job.state === 'ready' && job.mode === 'preview') {
      area.append(element('p', `Estimated execution charge: ${costLabel(job)}`, 'verification-cost'));
      if (Object.keys(job.input_values || {}).length) {
        area.append(element('strong', 'Input values bound to this estimate'));
        const inputs = element('dl', undefined, 'verification-quoted-inputs');
        for (const [key, value] of Object.entries(job.input_values)) {
          inputs.append(element('dt', key.replaceAll('_', ' ')), element('dd', value));
        }
        area.append(inputs);
      }
      if (job.context_fingerprint) area.append(element('p', `Context proof: ${job.context_fingerprint}`, 'verification-hash'));
      area.append(element('p', 'DamageBDD execution can incur its normal runner charge even when the feature uses synthetic payments. This approval does not authorise a wallet payment.', 'verification-muted'));
      area.append(element('p', `Approval expires: ${timeLabel(job.approval_expires_at)}`, 'verification-muted'));
      if (job.approved_job) {
        area.append(button('View the authorised execution', () => void openJobId(job.approved_job)));
      } else {
        const label = element('label', undefined, 'verification-approval'), check = element('input'); check.type = 'checkbox'; check.dataset.vApproval = '';
        check.addEventListener('change', controls);
        label.append(check, element('span', 'I have reviewed the scope, context and estimate. Run this entire feature.'));
        const run = button('Run verification', () => void approve(), 'workspace-button verification-primary'); run.dataset.vRun = '';
        area.append(label, run);
        if (!canApprove(job, state.feature)) area.append(element('p', 'Estimate expired or no longer matches this feature. Request a new estimate.', 'verification-notice'));
        else state.expiryTimer = setTimeout(() => { renderJob(); controls(); }, Math.max(1, job.approval_expires_at * 1000 - Date.now() + 20));
      }
    }
    if (job.mode === 'execute') {
      const complete = (job.progress || []).filter(p => p.state === 'passed' || p.state === 'failed').length;
      area.append(element('p', `${complete} step outcomes received. Unreported steps are not assumed to have passed.`, 'verification-muted'));
      if (job.state === 'passed') area.append(element('p', 'All assertions passed in this run. Read the feature’s scope before drawing broader conclusions.', 'verification-notice'));
      if (job.state !== 'running') {
        const path = reportPath(job.report_hash);
        if (path) { const link = element('a', 'Open native DamageBDD report', 'workspace-button'); link.href = path; link.target = '_blank'; link.rel = 'noopener noreferrer'; area.append(link); }
        area.append(button('Download workspace receipt', () => downloadReceipt(job)));
      }
      if (job.tx_hash) area.append(element('p', `Settlement transaction: ${job.tx_hash}`, 'verification-hash'));
    }
    area.append(element('p', `Run reference: ${job.id}`, 'verification-hash'));
    if (job.state === 'running' || ['pending', 'indeterminate'].includes(job.state)) area.append(button('Refresh status', () => void poll(true)));
    controls();
  }
  async function preview() {
    if (busy() || !state.feature?.runnable) return;
    const epoch = state.epoch; state.submitting = true; stopPolling(); controls();
    notify('Estimating against the current feature and context. No active verification has been approved.');
    const requestId = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() :
      Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
    try {
      const job = await api('preview', previewPayload(state.feature, state.inputs, requestId));
      if (epoch !== state.epoch) return;
      state.job = job; renderJob(); schedulePoll(); void loadHistory();
    } catch (error) { if (epoch === state.epoch) notify(friendlyError(error), 'error'); }
    finally { if (epoch === state.epoch) { state.submitting = false; controls(); } }
  }
  async function approve() {
    if (busy() || !find('[data-v-approval]')?.checked || !canApprove(state.job, state.feature)) return;
    const epoch = state.epoch, previewId = state.job.id;
    state.submitting = true; controls();
    try {
      const job = await api('run', {preview_id: previewId, approved: true});
      if (epoch !== state.epoch) return;
      state.job = job; renderJob(); notify('Execution accepted. Keep this run reference; duplicate approval uses the same execution.');
      schedulePoll(); void loadHistory();
    } catch (error) {
      if (epoch === state.epoch) {
        // No automatic retry: the server may have accepted a POST before the connection failed.
        notify(`${friendlyError(error)} Refresh recent checks to reconcile the outcome. Reusing this approval cannot create a second execution.`, 'error');
        const check = find('[data-v-approval]'); if (check) check.checked = false;
        void loadHistory();
      }
    } finally { if (epoch === state.epoch) { state.submitting = false; controls(); } }
  }
  function schedulePoll() {
    stopPolling(); if (!visible() || state.job?.state !== 'running' || destroyed) return;
    state.timer = setTimeout(() => void poll(), 1000);
  }
  async function poll(explicit = false) {
    if (!state.job || state.pollBusy || (!visible() && !explicit)) return;
    stopPolling(); const id = state.job.id, epoch = state.epoch;
    state.pollBusy = true;
    try {
      const job = await api(`jobs/${encodeURIComponent(id)}`);
      if (epoch !== state.epoch || state.job?.id !== id) return;
      state.job = job; renderJob();
      if (job.state !== 'running') { void loadHistory(); notify(stateLabel(job), ['failed', 'blocked', 'indeterminate', 'error'].includes(job.state) ? 'error' : 'info'); }
      schedulePoll();
    } catch (error) {
      if (epoch === state.epoch && state.job?.id === id) notify(`${friendlyError(error)} Use Refresh status or recent checks.`, 'error');
      // Deliberately stop rather than spinning on unavailable/unauthorised endpoints.
    } finally { if (epoch === state.epoch) state.pollBusy = false; }
  }
  async function openJob(job) {
    if (state.submitting || state.selecting) return;
    if (state.feature?.id === job.feature_id) { state.job = job; renderJob(); schedulePoll(); }
    else await selectFeature(job.feature_id, {job});
  }
  async function openJobId(id) {
    try { await openJob(await api(`jobs/${encodeURIComponent(id)}`)); }
    catch (error) { notify(friendlyError(error), 'error'); }
  }
  function downloadReceipt(job) {
    const receipt = {schema: 'damage-verification-workspace/v1',
      notice: 'A workspace status export, not an independently signed attestation. Inspect the native report for full evidence.',
      feature_title: state.feature?.title, ...job};
    const url = URL.createObjectURL(new Blob([JSON.stringify(receipt, null, 2)], {type: 'application/json'}));
    const a = element('a'); a.href = url; a.download = `verification-${job.id}.json`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function resetIdentity() {
    state.epoch++; state.selection++; stopPolling(); clearTimeout(state.expiryTimer);
    for (const controller of state.controllers) controller.abort(); state.controllers.clear();
    Object.assign(state, {features: [], feature: null, job: null, loaded: false, loading: false,
      submitting: false, selecting: false, inputs: {}, pollBusy: false});
    catalogNode.replaceChildren(); historyNode.replaceChildren(); detailNode.replaceChildren(element('p', 'Choose a check for this account.', 'verification-empty'));
    notify('Identity changed. Old estimates and results have been cleared.'); controls(); activate();
  }
  function activate() {
    if (!visible() || destroyed) { stopPolling(); return; }
    if (!state.loaded) { void loadCatalog(); void loadHistory(); }
    else if (state.job?.state === 'running') schedulePoll();
  }
  function onPanel(event) {
    if (!panel || event.detail?.id === panel.id) activate(); else stopPolling();
  }
  const onRefresh = () => { void loadCatalog(); void loadHistory(); if (state.job) void poll(true); };
  const onSearch = () => renderCatalog();
  refresh.addEventListener('click', onRefresh); search.addEventListener('input', onSearch);
  document.addEventListener('damage:panelchange', onPanel);
  document.addEventListener('visibilitychange', activate);
  document.addEventListener('auth:changed', resetIdentity);
  notify('Open this workspace to browse available checks.'); activate();
  return {destroy() {
    destroyed = true; state.epoch++; stopPolling(); clearTimeout(state.expiryTimer);
    for (const controller of state.controllers) controller.abort();
    document.removeEventListener('damage:panelchange', onPanel);
    document.removeEventListener('visibilitychange', activate);
    document.removeEventListener('auth:changed', resetIdentity);
    refresh.removeEventListener('click', onRefresh); search.removeEventListener('input', onSearch);
    delete root.dataset.verificationMounted;
  }};
}
if (typeof document !== 'undefined') {
  const boot = () => document.querySelectorAll('[data-verification-root]').forEach(root => mountVerification(root));
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, {once: true}); else boot();
}
