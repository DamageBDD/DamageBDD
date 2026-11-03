const LABELS = { service_ready: 'Signing service', aws_only: 'AWS-only custody',
  local_secret_absent: 'No local passphrase', identity_pinned: 'Pinned signing identity',
  aws_provenance: 'AWS retrieval provenance', narrow_policy: 'Signing policy',
  runtime_policy_matches: 'Running policy matches deployment', client_allowlist: 'Approved clients', relays_subscribed: 'Relay subscription',
  backend_artifact: 'Crypto backend executable', vault_permissions: 'Encrypted vault permissions', audit_permissions: 'Audit file permissions' };
const CLOSING_GUIDES = {
  current_controls: ['bunker-health-guide', '1. Resolve health controls'],
  live_signing: ['bunker-signing-guide', '2. Verify every relay'],
  version_promotion: ['bunker-pending-guide', '3–4. Prepare, test and promote the exact version'],
  backup_restore: ['bunker-restore-guide', '4. Verify the promoted version and restore'],
  cold_restart: ['bunker-restart-guide', '5. Restart under the runtime role'],
  operator_acceptance: ['bunker-acceptance-guide', '6. Gather references and record acceptance']
};
const CONTROL_GUIDES = {
  service_ready: 'bunker-identity-guide', identity_pinned: 'bunker-identity-guide',
  aws_only: 'bunker-custody-guide', local_secret_absent: 'bunker-custody-guide', aws_provenance: 'bunker-custody-guide',
  narrow_policy: 'bunker-relay-guide', runtime_policy_matches: 'bunker-relay-guide',
  client_allowlist: 'bunker-relay-guide', relays_subscribed: 'bunker-relay-guide',
  backend_artifact: 'bunker-files-guide', vault_permissions: 'bunker-files-guide', audit_permissions: 'bunker-files-guide'
};
export function freshness(report, seconds, now = Date.now() / 1000) {
  const at = report?.completed_at;
  return Number.isInteger(at) && at > 0 && now >= at && now - at <= seconds;
}
export function displayStatus(report, seconds, now) {
  if (!report?.status) return 'not_checked';
  return freshness(report, seconds, now) ? report.status : 'stale';
}
// Read older reports without rewriting their hashed evidence. Decode only
// named text fields, never arbitrary arrays such as event kinds.
export function setupText(value) {
  if (value == null || value === '' || (Array.isArray(value) && !value.length)) return 'Not configured';
  if (typeof value === 'string') return value;
  if (Array.isArray(value) && value.length <= 8192 && value.every(c =>
    Number.isInteger(c) && c >= 0 && c <= 0x10ffff && !(c >= 0xd800 && c <= 0xdfff))) {
    return String.fromCodePoint(...value);
  }
  return 'Invalid text value';
}
export function controlAction(control, state) {
  if (state === 'stale') return 'Run Check health for a current observation.';
  return state === 'passed' ? 'No corrective action required for this recorded check.' : control.next_action;
}
const root = typeof document === 'undefined' ? null : document.querySelector('[data-bunker-root]');
if (root) {
  let data = null, timer = null, loading = false, loadFailed = false;
  const byId = id => root.querySelector(`#${id}`);
  const el = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (cls) n.className = cls; return n; };
  const words = v => String(v ?? 'not_checked').replaceAll('_', ' ');
  const badge = state => { const n = el('span', words(state), 'bunker-badge'); n.dataset.status = state; return n; };
  const time = r => r?.completed_at ? new Date(r.completed_at * 1000).toLocaleString() : 'Not checked';
  const message = (text, error = false) => { byId('bunker-message').textContent = text; byId('bunker-message').classList.toggle('bunker-error', error); };
  const guideLink = (id, title) => { const a = el('a', title, 'bunker-guide-link'); a.href = `#${id}`; a.dataset.bunkerGo = ''; return a; };
  function showPane(name) {
    for (const t of root.querySelectorAll('[data-bunker-tab]')) t.setAttribute('aria-pressed', String(t.dataset.bunkerTab === name));
    for (const p of root.querySelectorAll('[data-bunker-pane]')) p.hidden = p.dataset.bunkerPane !== name;
  }
  async function request(body) {
    const response = await fetch('/api/admin/bunker', { method: body ? 'POST' : 'GET',
      credentials: 'same-origin', cache: 'no-store', headers: body ? {
        'content-type': 'application/json', 'x-damage-bunker-action': '1'
      } : { accept: 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    const result = await response.json();
    if (!response.ok) throw new Error(words(result.error || `HTTP ${response.status}`));
    return result;
  }
  function render() {
    if (!data) return;
    const evidence = data.evidence || {}, health = data.health || {}, verification = evidence.verify || {};
    const healthy = loadFailed ? 'stale' : displayStatus(health, 60);
    const signed = loadFailed || (health.fingerprint && health.fingerprint !== verification.fingerprint) ? 'stale' : displayStatus(verification, 900);
    const controls = health.checks || [];
    const custody = controls.find(c => c.id === 'aws_provenance');
    const summary = byId('bunker-summary'); summary.replaceChildren();
    for (const [title, status, description] of [
      ['Service health', healthy === 'stale' ? 'stale' : health.checks?.find(c => c.id === 'service_ready')?.status || 'not_checked', time(health)], ['Live signing', signed, time(verification)],
      ['AWS custody', healthy === 'stale' ? 'stale' : custody?.status || 'not_checked', 'Named controls; last observed ' + time(health)],
      ['Handover', loadFailed ? 'verification_required' : data.handover_status === 'accepted' ? 'accepted' : data.closure, data.handover_status === 'accepted' ? 'Acceptance retained; consult current check timestamps' : 'Complete required checks and acceptance']
    ]) { const card = el('article'); card.append(el('h2', title), el('strong', words(status)), el('small', description)); summary.append(card); }
    const tbody = byId('bunker-checks'); tbody.replaceChildren();
    for (const c of controls) { const row = el('tr'); const status = healthy === 'stale' ? 'stale' : c.status;
      const cell = el('td'), action = el('td', controlAction(c, status)); cell.append(badge(status));
      if (status !== 'passed' && CONTROL_GUIDES[c.id]) action.append(guideLink(CONTROL_GUIDES[c.id], 'Open setup instructions'));
      row.append(el('td', LABELS[c.id] || words(c.id)), cell, action); tbody.append(row); }
    if (!controls.length) { const row = el('tr'); const cell = el('td', 'No checks recorded. Select Check health to begin.'); cell.colSpan = 3; row.append(cell); tbody.append(row); }
    const closing = byId('bunker-closing-checks'); closing.replaceChildren();
    for (const c of data.closure_tasks || []) { const row=el('tr'), cell=el('td'); cell.append(badge(loadFailed?'stale':c.status));
      const attested = !loadFailed && c.id === 'operator_acceptance' && c.status === 'operator_attested';
      const action = el('td', attested ? 'Acceptance recorded. Export the evidence and retain it with the supporting records.' :
        !loadFailed && c.status === 'passed' ? 'Complete for the recorded evidence. Repeat only if stale or invalidated.' : c.next_action);
      if (attested) action.append(guideLink('bunker-acceptance-guide', 'Export the completed handover'));
      else if (CLOSING_GUIDES[c.id]) action.append(guideLink(...CLOSING_GUIDES[c.id]));
      row.append(el('td',words(c.id)),cell,action); closing.append(row); }
    const setup = health.setup || {}; const config = byId('bunker-setup'); config.replaceChildren();
    for (const [label, value] of [['Signing public key', setup.signing_public_key], ['AWS secret', setupText(setup.aws?.secret_id)],
      ['Region', setupText(setup.aws?.region)], ['Expected role', setupText(setup.aws?.expected_role_name)],
      ['Expected account', setupText(setup.aws?.expected_account_id)], ['Approved clients', setup.clients?.join('\n')],
      ['Methods', setup.methods?.join(', ')], ['Event kinds', setup.kinds?.join(', ')], ['Relays', setup.relays?.join('\n')]]) {
      config.append(el('dt', label), el('dd', value || 'Not configured')); }
    const exchanges = byId('bunker-exchanges'); exchanges.replaceChildren();
    for (const x of verification.exchanges || []) { const row = el('tr'), cell = el('td'); cell.append(badge(signed === 'stale' ? 'stale' : x.status));
      const refs = x.proof ? `request ${x.proof.request_event.id.slice(0, 12)}… / reply ${x.proof.response_event.id.slice(0, 12)}…` : words(x.reason);
      row.append(el('td', x.relay), el('td', x.test), cell, el('td', refs)); exchanges.append(row); }
    byId('bunker-report-detail').textContent = JSON.stringify({ report_sha256: verification.sha256,
      fingerprint: verification.fingerprint, started: time({ completed_at: verification.started_at }),
      completed: time(verification), reason: verification.reason || null }, null, 2);
    const maintenance = byId('bunker-maintenance-results'); maintenance.replaceChildren();
    for (const [key, label] of [['restart', 'Restart and live verification'], ['pending', 'AWSPENDING rehearsal'], ['recovery', 'AWSCURRENT restore verification']]) {
      const r = evidence[key], row = el('div', null, 'bunker-maintenance-result');
      row.append(el('span', `${label} · ${time(r)}${r?.reason ? ` · ${words(r.reason)}` : ""}`), badge(loadFailed ? 'stale' : displayStatus(r, 86400))); maintenance.append(row); }
    const pending = evidence.pending?.recovery?.secret_provenance || {}, restored = evidence.recovery?.recovery?.secret_provenance || {};
    const versions = byId('bunker-version-evidence'); versions.replaceChildren();
    for (const [label, value] of [
      ['Baseline current ID before rehearsal', pending.baseline_version_id], ['Tested pending ID', pending.version_id],
      ['Restored current ID', restored.version_id], ['Active version at restart', evidence.restart?.active_secret_version],
      ['Latest signing report SHA-256', verification.sha256]
    ]) versions.append(el('dt', label), el('dd', value || 'Not recorded — complete the corresponding check'));
    byId('bunker-acceptance-state').textContent = data.acceptance ?
      `Operator declaration recorded by ${data.acceptance.actor}. Current closure: ${words(data.closure)}.` :
      'Acceptance becomes available after fresh technical checks, restart, and pending-to-current restore evidence pass.';
    for (const b of root.querySelectorAll('[data-bunker-action]')) b.disabled = data.busy || loading;
    byId('bunker-accept').disabled = loading || data.busy || !!data.last_error || loadFailed || data.closure !== 'awaiting_acceptance';
    for (const b of root.querySelectorAll('[data-bunker-export]')) b.disabled = !Object.keys(evidence).length;
  }
  async function refresh() {
    clearTimeout(timer);
    try { data = await request(); loadFailed = false; render(); message(data.last_error ? `Evidence recording failed: ${words(data.last_error)}. Run a fresh check after resolving storage access.` : data.busy ? 'Verification in progress. You can leave this page and return to the recorded result.' :
      data.health_stale ? 'Health evidence is stale or has not been collected. Run Check health.' : 'Recorded evidence loaded.');
    } catch (error) { loadFailed = true; message(`Could not refresh: ${error.message}. Previously displayed results may be stale.`, true); render(); }
    if (!root.closest('[hidden]') && !document.hidden) timer = setTimeout(refresh, data?.busy ? 2000 : 10000);
  }
  const maintenanceText = {
    restart: 'This restarts the live bunker and briefly interrupts signing. It then repeats the relay verification under the configured runtime role. Continue during your maintenance window.',
    pending: 'This retrieves AWSPENDING and opens an isolated encrypted-vault copy. It does not change AWS labels or the live vault. A distinct pending version must have been prepared by your AWS administrator.',
    recovery: 'This retrieves AWSCURRENT and verifies an encrypted backup restored to an isolated copy. It does not replace the live vault or export the unlock value.'
  };
  async function confirmAction(action) {
    if (!maintenanceText[action]) return true;
    const dialog = byId('bunker-confirm'); byId('bunker-confirm-title').textContent = words(action) + ' verification';
    byId('bunker-confirm-text').textContent = maintenanceText[action]; dialog.returnValue = 'cancel';
    return new Promise(resolve => { dialog.addEventListener('close', () => resolve(dialog.returnValue === 'proceed'), { once: true }); dialog.showModal(); });
  }
  root.addEventListener('click', async event => {
    const guide = event.target.closest('[data-bunker-go]');
    if (guide) {
      // Keep the dashboard's own URL hash; guide links only navigate this pane.
      event.preventDefault();
      const target = document.getElementById(guide.getAttribute('href').slice(1));
      if (!target || !root.contains(target)) return;
      const pane = target.closest('[data-bunker-pane]'); if (pane) showPane(pane.dataset.bunkerPane);
      target.focus({ preventScroll: true }); target.scrollIntoView({ block: 'start' }); return;
    }
    const tab = event.target.closest('[data-bunker-tab]');
    if (tab) { showPane(tab.dataset.bunkerTab); return; }
    const button = event.target.closest('[data-bunker-action]'); if (!button || loading || data?.busy) return;
    const action = button.dataset.bunkerAction; if (!await confirmAction(action)) return;
    loading = true; render();
    try { await request({ action, ...(maintenanceText[action] ? { confirmed: true } : {}) }); await refresh(); }
    catch (error) { message(error.message, true); } finally { loading = false; render(); }
  });
  byId('bunker-acceptance').addEventListener('submit', async event => {
    event.preventDefault(); if (loading || !data || data.closure !== 'awaiting_acceptance') return;
    loading = true; render();
    try { const references = Object.fromEntries(new FormData(event.target)); await request({ action: 'accept',
      report_sha256: data.evidence.verify.sha256, references }); await refresh(); }
    catch (error) { message(error.message, true); } finally { loading = false; render(); }
  });
  for (const button of root.querySelectorAll('[data-bunker-export]')) button.addEventListener('click', () => {
    if (!data) return; const url = URL.createObjectURL(new Blob([JSON.stringify({...data, exported_at: new Date().toISOString(), observation_note: loadFailed ? 'Cached observations; refresh unavailable' : 'Recorded observations; consult individual timestamps'}, null, 2)], { type: 'application/json' }));
    const a = el('a'); a.href = url; a.download = 'bunker-handoff-evidence.json'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  new MutationObserver(() => { if (!root.closest('[hidden]')) refresh(); else clearTimeout(timer); }).observe(root.closest('[data-dashboard-view]') || root, { attributes: true, attributeFilter: ['hidden'] });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && !root.closest('[hidden]')) refresh(); else clearTimeout(timer); });
  refresh();
}
