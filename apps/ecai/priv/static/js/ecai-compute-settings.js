/* ECAI cloud connections and compute reservations; no cloud keys in browser. */
(() => {
  'use strict';
  const assetVersion = 'compute-only-v1';
  const $ = (id) => document.getElementById(id);
  let api, toast, openLogin, currentToken, state = null, quoted = null, requestKey = null;
  let ready = false;
  let activeProvider = 'aws_batch';
  function selectSection(id, focus = false) {
    const tabs = [...document.querySelectorAll('[data-compute-section]')];
    if (!tabs.some(tab => tab.dataset.computeSection === id)) return;
    for (const tab of tabs) {
      const active = tab.dataset.computeSection === id;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      $(tab.dataset.computeSection).hidden = !active;
      if (active && focus) tab.focus();
    }
  }
  function sectionKey(event, tab) {
    const tabs = [...document.querySelectorAll('[data-compute-section]')];
    const i = tabs.indexOf(tab);
    const next = {ArrowRight: (i + 1) % tabs.length,
      ArrowLeft: (i + tabs.length - 1) % tabs.length,
      Home: 0, End: tabs.length - 1}[event.key];
    if (next === undefined) return;
    event.preventDefault();
    selectSection(tabs[next].dataset.computeSection, true);
  }
  const money = (cents) => Number.isSafeInteger(cents) ?
    (cents / 100).toLocaleString(undefined, {style: 'currency', currency: 'USD'}) : 'Not reconciled';
  const label = (id, value) => { const el = $(id); if (el) el.textContent = String(value); };
  const el = (tag, cls, value) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (value !== undefined) n.textContent = String(value);
    return n;
  };
  const data = (response) => {
    if (response?.ok !== true) throw new Error('Unexpected compute API response');
    return response.data;
  };
  const errText = (error) => {
    const e = error?.body?.error;
    return e ? String(e) : (error?.message || 'Request failed');
  };
  function cents(input) {
    const text = String(input).trim();
    if (!/^\d+(?:\.\d{1,2})?$/.test(text)) throw new Error('Enter a positive USD amount with at most 2 decimals');
    const [a, b = ''] = text.split('.');
    const n = BigInt(a) * 100n + BigInt(b.padEnd(2, '0'));
    if (n > 100000000n) throw new Error('Amount exceeds the maximum accepted by the node');
    return Number(n);
  }
  const usdInput = (n) => (Number.isSafeInteger(n) ? (n / 100).toFixed(2) : '0.00');
  function authorized() {
    if (!currentToken?.()) { openLogin?.('Sign in to the ECAI console to obtain a bearer token before changing compute settings.'); throw new Error('An explicit bearer token is required'); }
  }
  async function call(path, opts = {}) {
    if (opts.method === 'POST') authorized();
    return data(await api(path, opts));
  }
  function fail(error) { label('computeNotice', errText(error)); toast?.(errText(error), true); }
  function setInputs(form, fields) {
    for (const [key, value] of Object.entries(fields || {})) {
      const field = form.elements.namedItem(key);
      if (field && typeof value === 'string') field.value = value;
    }
  }
  function providerStatus(name, id) {
    const p = state?.providers?.[name];
    label(id, p?.status === 'identity_verified' ? 'Identity verified' : p ? 'Saved · verify access' : 'Not configured');
    return p;
  }
  // Only the provider's first-party console origin may receive a project hint.
  // Do not interpolate an arbitrary URL or put credentials/external IDs in a URL.
  const gcpProject = () => $('computeGcpForm')?.elements.namedItem('project_id')?.value.trim() || '';
  function gcpConsoleLinks() {
    const project = gcpProject();
    const hint = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(project) ?
      `?project=${encodeURIComponent(project)}` : '';
    const pages = {
      computeGcpConsoleLink: 'run/jobs',
      computeGcpBucketsLink: 'storage/browser',
      computeGcpWifLink: 'iam-admin/workload-identity-pools',
      computeGcpServiceAccountsLink: 'iam-admin/serviceaccounts'
    };
    for (const [id, page] of Object.entries(pages)) {
      $(id).href = `https://console.cloud.google.com/${page}${hint}`;
    }
  }
  function awsBatchConsoleLink() {
    const region = $('computeAwsForm').elements.namedItem('region').value.trim();
    const hint = /^[a-z]{2}(?:-[a-z0-9]+)+-[1-9]$/.test(region) ?
      `?region=${encodeURIComponent(region)}` : '';
    $('computeAwsBatchLink').href = `https://console.aws.amazon.com/batch/home${hint}`;
  }
  const awsExternalId = () => state?.providers?.aws_batch?.external_id ||
    state?.provider_setup?.aws_batch_external_id || '';
  const validAwsPrincipal = (s) => typeof s === 'string' &&
    /^arn:aws:iam::[0-9]{12}:role\/[A-Za-z0-9_+=,.@/-]+$/.test(s);
  function awsTrustPolicy() {
    const principal = state?.connection_hints?.aws_coordinator_role_arn;
    const externalId = awsExternalId();
    if (!validAwsPrincipal(principal) || !/^[0-9a-f]{48}$/i.test(externalId)) return null;
    return JSON.stringify({
      Version: '2012-10-17',
      Statement: [{Effect: 'Allow', Principal: {AWS: principal},
        Action: 'sts:AssumeRole', Condition: {StringEquals: {'sts:ExternalId': externalId}}}]
    }, null, 2);
  }
  function selectProvider(name) {
    if (name !== 'aws_batch' && name !== 'cloud_run') return;
    activeProvider = name;
    $('computeAwsPanel').hidden = name !== 'aws_batch';
    $('computeGcpPanel').hidden = name !== 'cloud_run';
    for (const button of document.querySelectorAll('[data-compute-provider-choice]')) {
      button.setAttribute('aria-pressed', String(button.dataset.computeProviderChoice === name));
    }
    renderConnectionGuide();
  }
  function setStep(id, status) { $(id).dataset.status = status; }
  function syncGuideControls() {
    const aws = state?.providers?.aws_batch;
    const gcp = state?.providers?.cloud_run;
    const external = awsExternalId();
    $('computePrepareAws').disabled = Boolean(external);
    $('computePrepareAws').textContent = external ? 'Setup ID ready ✓' : 'Generate setup ID';
    $('computeCopyExternalId').disabled = !external;
    $('computeCopyTrustPolicy').disabled = !awsTrustPolicy();
    $('computeVerifyAws').disabled = !aws;
    $('computeVerifyGcp').disabled = !gcp;
    // Viewing/configuring a budget is not authorization to reserve or run work.
    $('computeNextBudget').disabled = false;
  }
  function renderConnectionGuide() {
    const aws = state?.providers?.aws_batch;
    const gcp = state?.providers?.cloud_run;
    const principal = state?.connection_hints?.aws_coordinator_role_arn;
    const external = awsExternalId();
    $('computeAwsBlocked').hidden = !state || validAwsPrincipal(principal);
    label('computeAwsExternalId', external || 'Generate setup ID to continue');
    label('computeAwsPrincipal', validAwsPrincipal(principal) ? principal :
      'Not configured on this ECAI node');
    label('computeAwsPolicyHelp', validAwsPrincipal(principal) ?
      'Copy the exact trust policy; paste it into the new IAM role in your AWS account.' :
      'Your ECAI node operator must configure compute_aws_coordinator_role_arn before you can copy a safe trust policy. Do not use a wildcard principal.');
    $('computeChooseAws').dataset.connectionState = aws?.status === 'identity_verified' ?
      'verified' : aws ? 'saved' : 'new';
    $('computeChooseGcp').dataset.connectionState = gcp?.status === 'identity_verified' ?
      'verified' : gcp ? 'saved' : 'new';
    if (aws && !$('computeAwsResources').open) $('computeAwsResources').open = true;
    if (gcp && !$('computeGcpResources').open) $('computeGcpResources').open = true;
    label('computeAwsGuideStatus', aws?.status === 'identity_verified' ?
      'AWS IAM identity verified. Batch execution and spending are still disabled.' :
      aws ? 'Connection saved. Verify the ECAI coordinator can assume this IAM role.' :
      external ? 'Setup ID prepared. Configure AWS trust and save your existing Batch resources.' :
      'Prepare your external ID before configuring IAM trust.');
    label('computeGcpGuideStatus', gcp?.status === 'identity_verified' ?
      'Cloud Run job visibility verified. Job execution and spending are still disabled.' :
      gcp ? 'Connection saved. Verify the ECAI node can describe the Cloud Run job.' :
      'Open your GCP project, delegate workload identity and save existing resource details.');
    const chosen = activeProvider === 'aws_batch' ? aws : gcp;
    const started = activeProvider === 'aws_batch' ? Boolean(external) : true;
    setStep('computeStepChoose', 'complete');
    setStep('computeStepAuthorize', chosen ? 'complete' : started ? 'current' : 'current');
    setStep('computeStepVerify', chosen?.status === 'identity_verified' ? 'complete' :
      chosen ? 'current' : 'pending');
    label('computeConnectionFootnote', chosen?.status === 'identity_verified' ?
      'Identity verified. Next: configure an opt-in budget; reservations still do not submit cloud jobs.' :
      chosen ? 'Settings saved. Verify identity access before enabling a budget.' :
      'Complete the provider setup and save its details to enable verification.');
    syncGuideControls();
    gcpConsoleLinks();
    awsBatchConsoleLink();
  }
  async function copyText(value, description) {
    if (!value) throw new Error('Prepare the connection details before copying.');
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(value);
    } else {
      // Fallback for private LAN dashboards served without a secure context.
      const textarea = document.createElement('textarea');
      textarea.value = value;
      textarea.setAttribute('readonly', '');
      textarea.style.position = 'fixed';
      textarea.style.opacity = '0';
      document.body.append(textarea);
      try {
        textarea.select();
        if (!document.execCommand('copy')) throw new Error('Copy is blocked by this browser.');
      } finally { textarea.remove(); }
    }
    toast?.(`${description} copied. Keep provider permissions least-privilege.`);
  }
  async function prepareAws() {
    await withBusy($('computePrepareAws'), async () => {
      const result = await call('/ecai/compute/providers/aws_batch/prepare',
        {method: 'POST', body: {}});
      if (!/^[0-9a-f]{48}$/i.test(result?.external_id || ''))
        throw new Error('The provider returned an invalid external ID.');
      toast?.('AWS setup ID prepared. Configure IAM trust in AWS next.');
      await refresh();
    });
  }
  function fillSettings() {
    const budget = state?.budget || {};
    const compute = state?.reserved_compute_cents || 0;
    label('computeBudgetLimit', money(budget.monthly_cents ?? 0));
    label('computeBudgetReserved', money(compute));
    label('computeBudgetAvailable', money(Math.max(0, (budget.monthly_cents || 0) - compute)));
    label('computeBudgetBilled', money(state?.actual_billed_cents));
    label('computeMonth', `Budget month: ${state?.period_utc || '—'} UTC`);
    label('computeNotice', `${money(compute)} reserved · ${money(Math.max(0, (budget.monthly_cents || 0) - compute))} unreserved · ${state?.period_utc || '—'} UTC`);
    const bf = $('computePolicyForm').elements;
    bf.namedItem('enabled').checked = budget.remote_enabled === true;
    bf.namedItem('monthly').value = usdInput(budget.monthly_cents);
    bf.namedItem('per_job').value = usdInput(budget.per_job_cents);
    const aws = providerStatus('aws_batch', 'computeAwsStatus');
    setInputs($('computeAwsForm'), aws);
    const gcp = providerStatus('cloud_run', 'computeGcpStatus');
    setInputs($('computeGcpForm'), gcp);
    renderConnectionGuide();
    renderReservations();
  }
  function renderReservations() {
    const host = $('computeReservations'); host.replaceChildren();
    const entries = state?.reservations || [];
    if (!entries.length) { host.append(el('div', 'empty-state', 'No remote reservations yet.')); return; }
    for (const r of entries) {
      const row = el('div', 'compute-row');
      const copy = el('div');
      copy.append(el('strong', '', `${r.spec?.provider || 'Compute'} · ${money(r.reserved_cents)}`),
        el('small', '', `${r.state} · ${r.id} · source ${r.spec?.source_job_id || '—'}`));
      row.append(copy);
      if (r.state === 'awaiting_dispatch') {
        const button = el('button', 'button button-outline button-sm', 'Release reservation');
        button.type = 'button';
        button.addEventListener('click', () => void withBusy(button, async () => {
          if (!window.confirm('Release this reservation? It has not been dispatched.')) return;
          await call(`/ecai/compute/reservations/${encodeURIComponent(r.id)}/cancel`, {method: 'POST', body: {}});
          await refresh();
        }));
        row.append(button);
      }
      host.append(row);
    }
  }
  async function refresh() {
    if (!ready) return;
    try {
      state = await call('/ecai/compute/settings');
      fillSettings();
      // Ancillary job lists must not break provider onboarding/status updates.
      await loadSources().catch(() => label('computeSourceCount', 'Source jobs unavailable'));
    } catch (error) {
      label('computeNotice', error?.status === 401 ? 'Sign in using DamageBDD to manage compute settings.' : errText(error));
      if (error?.status !== 401) toast?.(errText(error), true);
    }
  }
  async function withBusy(control, fn) {
    if (control.disabled) return;
    control.disabled = true;
    try { await fn(); } catch (error) { fail(error); }
    finally { control.disabled = false; if (state) syncGuideControls(); }
  }
  async function saveProvider(ev, name) {
    ev.preventDefault();
    const button = ev.currentTarget.querySelector('[type="submit"]');
    await withBusy(button, async () => {
      const fields = Object.fromEntries(new FormData(ev.currentTarget).entries());
      await call(`/ecai/compute/providers/${name}`, {method: 'POST', body: fields});
      toast?.('Connection saved. Complete the cloud delegation, then verify identity.');
      await refresh();
    });
  }
  async function verifyProvider(name, button) {
    await withBusy(button, async () => {
      await call(`/ecai/compute/providers/${name}/verify`, {method: 'POST', body: {}});
      toast?.('Identity verified. Cloud job launches are not active.');
      await refresh();
    });
  }
  function currentPolicy() {
    const bf = $('computePolicyForm').elements;
    // Domain-scoped write: the server preserves mint policy atomically.
    return {remote_enabled: bf.namedItem('enabled').checked,
      monthly_cents: cents(bf.namedItem('monthly').value),
      per_job_cents: cents(bf.namedItem('per_job').value)};
  }
  async function savePolicy(event) {
    event.preventDefault();
    const button = event.currentTarget.querySelector('[type="submit"]');
    await withBusy(button, async () => {
      const policy = currentPolicy();
      await call('/ecai/compute/budget', {method: 'POST', body: policy});
      toast?.('Compute budget saved.');
      await refresh();
    });
  }
  function jobSpec() {
    const f = $('computeJobForm').elements;
    const integer = (n) => {
      const text = String(f.namedItem(n).value);
      if (!/^\d+$/.test(text)) throw new Error(`Invalid ${n}`);
      return Number(text);
    };
    return {source_job_id: f.namedItem('source_job_id').value.trim(),
      provider: f.namedItem('provider').value,
      vcpus: integer('vcpus'), memory_mb: integer('memory_mb'),
      max_seconds: integer('max_seconds'), max_attempts: integer('max_attempts')};
  }
  function resetQuote() { quoted = null; $('computeReserveBtn').disabled = true; label('computeQuoteStatus', 'Estimate again after changing any job setting.'); }
  async function quoteJob() {
    const button = $('computeQuoteBtn');
    await withBusy(button, async () => {
      const spec = jobSpec();
      const quote = await call('/ecai/compute/quote', {method: 'POST', body: spec});
      quoted = {spec, quote};
      requestKey = `ecai-compute-${crypto.randomUUID()}`;
      label('computeQuoteStatus', `${money(quote.reserve_cents)} reservation maximum, USD · operator price ceiling · not a cloud invoice · no job launched`);
      $('computeReserveBtn').disabled = false;
    });
  }
  async function reserveJob(event) {
    event.preventDefault();
    await withBusy($('computeReserveBtn'), async () => {
      if (!quoted || JSON.stringify(jobSpec()) !== JSON.stringify(quoted.spec)) throw new Error('Requote the job after changing the form.');
      if (!window.confirm(`Reserve ${money(quoted.quote.reserve_cents)} from your monthly allowance? This will NOT launch compute.`)) return;
      await call('/ecai/compute/reservations', {method: 'POST',
        body: {...quoted.spec, expected_reserve_cents: quoted.quote.reserve_cents},
        headers: {'Idempotency-Key': requestKey}});
      quoted = null;
      toast?.('Budget reserved; no cloud job was launched.');
      await refresh();
    });
  }
  async function loadSources() {
    const sources = await call('/ecai/compute/eligible-sources');
    const list = $('computeSourceOptions');
    list.replaceChildren();
    for (const source of sources) {
      const opt = el('option');
      opt.value = source.id;
      opt.label = `${source.kind} · ${source.state}`;
      list.append(opt);
    }
    label('computeSourceCount', `${sources.length} eligible source jobs`);
  }
  function setSourceJob(id) {
    const field = $('computeJobForm')?.elements.namedItem('source_job_id');
    if (field && typeof id === 'string') {
      field.value = id;
      resetQuote();
      selectSection('computeJobs');
    }
  }
  // A persistent message also catches an old/missing controller: only this
  // controller may dismiss it, after matching the template AND loaded CSS.
  // Keep this separate from computeNotice, which API refreshes overwrite.
  function checkAssets() {
    const panel = $('computePanel');
    const notice = $('computeAssetNotice');
    if (!panel || !notice) return;
    const cssVersion = window.getComputedStyle?.(panel)
      .getPropertyValue('--compute-ui-version').trim();
    const matches = panel.dataset.computeUiVersion === assetVersion && cssVersion === assetVersion;
    notice.hidden = matches;
    panel.dataset.computeAssets = matches ? 'ready' : 'mismatch';
    if (!matches) notice.textContent = 'Cloud setup assets are missing or out of date. Reload the dashboard. If this persists, ask the node operator to deploy matching dashboard HTML, CSS and JavaScript to the running node’s static directory.';
  }
  function init(apiHooks) {
    if (ready || !$('computePolicyForm')) return;
    ({request: api, toast, openLogin, currentToken} = apiHooks);
    ready = true;
    $('computeRefresh').addEventListener('click', () => void refresh());
    for (const tab of document.querySelectorAll('[data-compute-section]')) {
      tab.addEventListener('click', () => selectSection(tab.dataset.computeSection));
      tab.addEventListener('keydown', event => sectionKey(event, tab));
    }
    selectSection('computeProviders');
    for (const choice of document.querySelectorAll('[data-compute-provider-choice]')) {
      choice.addEventListener('click', () => selectProvider(choice.dataset.computeProviderChoice));
    }
    $('computeGcpForm').elements.namedItem('project_id').addEventListener('input', gcpConsoleLinks);
    $('computeAwsForm').elements.namedItem('region').addEventListener('input', awsBatchConsoleLink);
    $('computePrepareAws').addEventListener('click', () => void prepareAws());
    $('computeCopyExternalId').addEventListener('click', () =>
      void copyText(awsExternalId(), 'External ID').catch(fail));
    $('computeCopyTrustPolicy').addEventListener('click', () =>
      void copyText(awsTrustPolicy(), 'IAM trust policy').catch(fail));
    $('computeNextBudget').addEventListener('click', () =>
      selectSection('computeBudget', true));
    $('computeAwsForm').addEventListener('submit', (e) => void saveProvider(e, 'aws_batch'));
    $('computeGcpForm').addEventListener('submit', (e) => void saveProvider(e, 'cloud_run'));
    $('computeVerifyAws').addEventListener('click', () => void verifyProvider('aws_batch', $('computeVerifyAws')));
    $('computeVerifyGcp').addEventListener('click', () => void verifyProvider('cloud_run', $('computeVerifyGcp')));
    $('computePolicyForm').addEventListener('submit', (e) => void savePolicy(e));
    $('computeJobForm').addEventListener('input', resetQuote);
    $('computeJobForm').addEventListener('change', resetQuote);
    $('computeQuoteBtn').addEventListener('click', () => void quoteJob());
    $('computeJobForm').addEventListener('submit', (e) => void reserveJob(e));
    $('computeLoadSources').addEventListener('click', () => void loadSources().catch(fail));
    selectProvider(activeProvider);
    checkAssets();
  }
  function clear() {
    state = null; quoted = null; requestKey = null;
    for (const id of ['computeAwsForm', 'computeGcpForm', 'computePolicyForm',
                      'computeJobForm']) {
      const form = $(id); if (form) form.reset();
    }
    label('computeBudgetLimit', money(0)); label('computeBudgetReserved', money(0));
    label('computeBudgetAvailable', money(0)); label('computeBudgetBilled', 'Not connected');
    label('computeAwsStatus', 'Not configured'); label('computeGcpStatus', 'Not configured');
    label('computeAwsExternalId', 'Generate setup ID to continue');
    label('computeAwsPrincipal', 'Not configured on this ECAI node');
    label('computeAwsPolicyHelp', 'The ECAI node operator must configure the coordinator IAM role.');
    label('computeAwsGuideStatus', 'Prepare an external ID before configuring IAM trust.');
    label('computeGcpGuideStatus', 'Use your existing GCP project and workload identity.');
    label('computeConnectionFootnote', 'Choose a provider and verify identity before enabling a budget.');
    label('computeNotice', 'Sign in to manage compute connections and reservation limits.');
    if ($('computeReservations')) $('computeReservations').replaceChildren();
    if ($('computeSourceOptions')) $('computeSourceOptions').replaceChildren();
    label('computeSourceCount', 'Sign in to load eligible sources');
    if ($('computeReserveBtn')) $('computeReserveBtn').disabled = true;
    resetQuote();
    if ($('computeVerifyAws')) $('computeVerifyAws').disabled = true;
    if ($('computeVerifyGcp')) $('computeVerifyGcp').disabled = true;
    if ($('computePrepareAws')) {
      $('computePrepareAws').disabled = false;
      $('computePrepareAws').textContent = 'Generate setup ID';
    }
    if ($('computeCopyExternalId')) $('computeCopyExternalId').disabled = true;
    if ($('computeCopyTrustPolicy')) $('computeCopyTrustPolicy').disabled = true;
    if ($('computeNextBudget')) $('computeNextBudget').disabled = false;
    selectSection('computeProviders');
    $('computeAwsResources').open = false;
    $('computeGcpResources').open = false;
    selectProvider('aws_batch');
  }
  window.EcaiComputeSettings = {init, refresh, clear, setSourceJob, selectSection, assetVersion};
})();
