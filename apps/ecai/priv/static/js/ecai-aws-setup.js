/* Automatic AWS setup. No AWS keys, session tokens or credentials in storage. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const ROOT = '/ecai/compute/aws/setup';
  let hooks, initialized = false, generation = 0, mutation = 0, busy = false, loading = false;
  let config = null, session = null, sessionOperation = null, operation = null, operations = [];
  let selectedId = '', planKey = null, timer = null;
  const text = (id, value) => { if ($(id)) $(id).textContent = String(value ?? ''); };
  const validId = value => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
  const hasSession = () => session && session.expires_at_ms > Date.now();
  const matchingSession = () => hasSession() && operation && session.region === operation.region && session.identity.account_id === operation.account_id;
  const messages = {
    AccessDenied: 'AWS denied the request. Review the setup IAM permissions, permission boundary and organization policies.',
    AccessDeniedException: 'AWS denied the request. Review the setup identity permissions.',
    root_credentials_rejected: 'Root credentials are not accepted. Use a dedicated setup identity or temporary role credentials.',
    session_token_required: 'Temporary ASIA credentials require their session token.',
    setup_session_expired: 'The setup session expired. Reconnect in the same AWS account and region, then reconcile the recorded deployment.',
    setup_session_not_found: 'Reconnect AWS credentials for this browser session before continuing.',
    setup_session_limit: 'A setup session is already active for your account, or the node is at capacity. Discard it or wait for expiry.',
    aws_account_or_region_mismatch: 'These credentials belong to a different AWS account or region than the recorded plan.',
    https_same_origin_required: 'Open the dashboard over HTTPS. The node must trust the exact TLS proxy address, if a proxy is used.',
    aws_sdk_not_installed: 'The node needs the Python environment and pinned boto3 requirements configured.',
    node_coordinator_identity_mismatch: 'The node’s AWS identity does not match its configured coordinator role. Ask the operator to fix the workload identity.',
    provider_changed_import_not_applied: 'AWS provisioning completed, but the provider connection changed after review. Existing settings were preserved; inspect the stack outputs before connecting manually.',
    probe_submission_needs_reconciliation: 'The verification submission is uncertain. Do not submit another job. Reconcile this recorded request or inspect AWS Batch.',
    reconnect_aws_to_reconcile: 'AWS may still be deploying. Reconnect setup credentials for the same account and region, then reconcile.',
    node_setup_required_or_invalid_request: 'The operator must complete the Automatic AWS Setup prerequisites before credentials are accepted.'
  };
  const message = error => {
    const code = error?.body?.error || error?.message || String(error);
    return messages[code] || String(code);
  };
  function notice(value, error = false) {
    text('awsSetupNotice', value);
    $('awsSetupNotice').dataset.error = String(error);
  }
  function clearSecrets() {
    for (const id of ['awsSetupAccessKey', 'awsSetupSecretKey', 'awsSetupSessionToken']) $(id).value = '';
  }
  async function call(path, options = {}) {
    const epoch = generation, token = hooks.currentToken?.();
    if (!token) { hooks.openLogin?.('Managed email sign-in is required for automatic AWS setup.'); throw new Error('explicit_bearer_required'); }
    const response = await hooks.request(ROOT + path, options);
    if (epoch !== generation || token !== hooks.currentToken?.()) throw new DOMException('Session changed', 'AbortError');
    if (response?.ok !== true) throw Object.assign(new Error(response?.error || 'Unexpected setup response'), {body: response});
    return response.data;
  }
  async function work(fn) {
    if (busy) return;
    const epoch = generation; mutation++; busy = true; updateControls();
    try { await fn(); }
    catch (error) { if (epoch === generation && error.name !== 'AbortError') notice(message(error), true); }
    finally { if (epoch === generation) { busy = false; updateControls(); schedule(); } }
  }
  function updateControls() {
    if (!initialized) return;
    const secure = location.protocol === 'https:';
    const enabled = config?.ready === true && secure && !!hooks.currentToken?.();
    $('awsSetupCredentialFields').disabled = busy || !enabled || !!hasSession();
    $('awsSetupPlanFields').disabled = busy || !enabled || !hasSession();
    $('awsSetupDisconnect').disabled = busy || !session;
    $('awsSetupHistory').disabled = busy;
    $('awsSetupRefresh').disabled = busy;
    const active = enabled && operation && !operation.busy && !busy;
    const deployable = operation?.status === 'planned' || (operation?.status === 'reconcile_required' && operation?.intent === 'deploy');
    $('awsSetupApproval').hidden = !deployable;
    $('awsSetupReplaceLabel').hidden = !operation?.replaces_provider;
    $('awsSetupDeploy').disabled = !active || !deployable || !matchingSession() || !$('awsSetupAcknowledge').checked || (operation.replaces_provider && !$('awsSetupReplace').checked);
    $('awsSetupDeploy').textContent = operation?.status === 'reconcile_required' ? 'Retry the same deployment' : 'Create AWS environment';
    $('awsSetupDiscard').disabled = !active || !!operation.intent || !['planned','plan_failed'].includes(operation.status);
    $('awsSetupReconcile').disabled = !active || !matchingSession() || !operation?.intent;
    $('awsSetupVerify').disabled = !active || operation.status !== 'deployed';
    $('awsSetupProbe').disabled = !active || operation.status !== 'deployed' || operation.runtime_status !== 'verified' || !!operation.probe || !config?.probe_enabled || !$('awsSetupProbeConsent').checked;
    $('awsSetupProbeStatus').disabled = !active || !operation?.probe;
    const settled = !operation?.probe || ['VERIFIED', 'FAILED'].includes(operation.probe.status);
    const canDelete = active && ['deployed', 'connection_conflict', 'deployment_failed', 'delete_failed'].includes(operation.status);
    $('awsSetupDelete').disabled = !canDelete || !settled || !matchingSession() || !$('awsSetupRetain').checked || $('awsSetupDeleteName').value !== operation.plan?.stack_name;
    $('awsSetupDownloadTemplate').disabled = !operation?.plan?.template;
  }
  function renderConfig() {
    const blockers = [...(config?.blockers || [])];
    if (!config?.enabled && !blockers.length) blockers.push('Automatic setup is not enabled for this account. Manual provider setup remains available below.');
    if (location.protocol !== 'https:') blockers.push('Use HTTPS before entering AWS credentials.');
    const host = $('awsSetupBlockers'); host.replaceChildren(); host.hidden = blockers.length === 0;
    for (const item of blockers) { const p = document.createElement('p'); p.textContent = item; host.append(p); }
    const region = $('awsSetupRegion'), chosen = region.value;
    region.replaceChildren();
    for (const value of config?.regions || []) { const option = document.createElement('option'); option.value = value; option.textContent = value; region.append(option); }
    if ([...(region.options || [])].some(o => o.value === chosen)) region.value = chosen;
    if (hasSession()) text('awsSetupIdentity', `Account ${session.identity.account_id}\n${session.identity.caller_arn}\nIdentity confirmed; provisioning permissions not yet established.\nSetup credentials expire ${new Date(session.expires_at_ms).toLocaleTimeString()}.`);
    else { session = null; sessionOperation = null; text('awsSetupIdentity', 'Not connected. Keys are never saved in provider settings.'); }
    updateControls();
  }
  function renderHistory() {
    const select = $('awsSetupHistory'); select.replaceChildren();
    const blank = document.createElement('option'); blank.value = ''; blank.textContent = 'Choose a recorded setup'; select.append(blank);
    for (const item of operations) {
      const option = document.createElement('option'); option.value = item.id;
      option.textContent = `${item.region} · ${item.account_id} · ${item.status} · ${item.id.slice(0, 8)}`;
      select.append(option);
    }
    select.value = selectedId;
  }
  function renderOperation() {
    $('awsSetupOperation').hidden = !operation;
    if (!operation) { updateControls(); return; }
    const op = operation, plan = op.plan;
    text('awsSetupOperationState', `${op.status}${op.busy ? ' · working' : ''}`);
    if (plan) {
      const p = plan.options;
      text('awsSetupPlanSummary', `AWS account ${op.account_id} · ${op.region}\nStack: ${plan.stack_name}\n${p.profile} · up to ${p.max_vcpus} vCPUs · job timeout ${p.job_timeout_seconds}s · logs ${p.log_retention_days} days\nImage: ${plan.worker_image}\nThis plan is fixed. Changing the choices above creates a new plan.`);
      text('awsSetupPlanHash', `Plan SHA-256: ${plan.plan_sha256}\nTemplate SHA-256: ${plan.template_sha256}`);
      const warning = $('awsSetupWarnings'); warning.replaceChildren();
      for (const value of plan.warnings || []) { const p = document.createElement('p'); p.textContent = value; warning.append(p); }
      const resources = $('awsSetupResourceList'); resources.replaceChildren();
      for (const resource of plan.resources || []) { const row = document.createElement('div'); row.textContent = `${resource.logical_id} · ${resource.type}`; resources.append(row); }
    } else {
      text('awsSetupPlanSummary', 'Generating the immutable plan. No AWS resources have been created.');
      text('awsSetupPlanHash', ''); $('awsSetupWarnings').replaceChildren(); $('awsSetupResourceList').replaceChildren();
    }
    const error = op.last_error ? (messages[op.last_error] || op.last_error) : '';
    text('awsSetupRuntime', `Runtime access: ${op.runtime_status || 'unchecked'}. Production index dispatch: not integrated.\n${op.credential_session_active ? 'Temporary setup session may still be active.' : 'This operation has no active setup credential session.'}${error ? '\n' + error : ''}`);
    if (sessionOperation === op.id && !op.credential_session_active) { session = null; sessionOperation = null; renderConfig(); }
    const probe = op.probe;
    text('awsSetupProbeState', probe ? `${probe.status} · ${probe.job_id || 'submission not yet confirmed'}${probe.status === 'VERIFIED' ? ' · synthetic output hash matched; this is not an index artifact test.' : ''}` : config?.probe_enabled ? 'Not requested. One diagnostic submission is allowed per setup operation.' : 'Diagnostic submissions are disabled by the node operator.');
    const link = $('awsSetupCloudConsole');
    const stackPrefix = `arn:aws:cloudformation:${op.region}:${op.account_id}:stack/`;
    link.hidden = !(typeof op.stack_id === 'string' && op.stack_id.startsWith(stackPrefix));
    if (!link.hidden) link.href = `https://console.aws.amazon.com/cloudformation/home?region=${encodeURIComponent(op.region)}#/stacks/stackinfo?stackId=${encodeURIComponent(op.stack_id)}`;
    const events = $('awsSetupEvents'); events.replaceChildren();
    for (const event of op.events || []) { const line = document.createElement('div'); line.textContent = `${event.status} · ${event.logical_id} · ${event.resource_type}`; events.append(line); }
    if (!events.childNodes.length) events.textContent = 'No deployment events yet.';
    updateControls();
  }
  async function refresh() {
    if (!initialized || loading || busy || !hooks.currentToken?.()) return;
    const epoch = generation, revision = mutation; loading = true;
    try {
      const result = await call('');
      if (revision !== mutation) return;
      config = result.config; operations = result.operations || [];
      // Restore only the backend's session bound to this exact bearer identity.
      session = result.session || null;
      renderConfig(); renderHistory();
      if (selectedId && validId(selectedId)) {
        const requestedId = selectedId;
        const loaded = await call('/' + requestedId);
        if (requestedId === selectedId && revision === mutation) { operation = loaded; renderOperation(); }
      }
    } catch (error) { if (epoch === generation && error.name !== 'AbortError') notice(message(error), true); }
    finally { if (epoch === generation) { loading = false; schedule(); } }
  }
  function schedule() {
    clearTimeout(timer); timer = null;
    const panel = $('computePanel');
    if (!initialized || !hooks.currentToken?.() || panel?.hidden || document.hidden) return;
    if (session || operation?.busy || ['deploying', 'deleting'].includes(operation?.status) || operation?.probe) timer = setTimeout(() => void refresh(), 5000);
  }
  async function connect(event) {
    event.preventDefault();
    if (!$('awsSetupConnectForm').reportValidity()) return;
    const credentials = {access_key_id:$('awsSetupAccessKey').value.trim(), secret_access_key:$('awsSetupSecretKey').value.trim(), session_token:$('awsSetupSessionToken').value.trim()};
    if (credentials.access_key_id.startsWith('ASIA') && !credentials.session_token) { notice(messages.session_token_required, true); return; }
    const region = $('awsSetupRegion').value;
    clearSecrets();
    await work(async () => {
      try {
        session = await call('/connect', {method:'POST', body:{region, credentials}});
        sessionOperation = null; notice('AWS identity confirmed. Choose a profile and generate a plan; no infrastructure has been created.'); renderConfig();
      } finally { for (const key of Object.keys(credentials)) credentials[key] = ''; clearSecrets(); }
    });
  }
  async function plan(event) {
    event.preventDefault();
    if (!hasSession() || !$('awsSetupPlanForm').reportValidity()) return;
    const options = {profile:$('awsSetupProfile').value, max_vcpus:Number($('awsSetupCapacity').value), log_retention_days:Number($('awsSetupLogDays').value), job_timeout_seconds:Number($('awsSetupTimeout').value)};
    if (options.profile === 'cpu-medium' && options.max_vcpus < 2) { notice('The medium profile needs at least 2 vCPUs of total capacity.', true); return; }
    planKey ||= crypto.randomUUID();
    await work(async () => {
      operation = await call('/plan', {method:'POST', headers:{'Idempotency-Key':planKey}, body:{session_id:session.session_id, options}});
      selectedId = operation.id; sessionOperation = selectedId;
      $('awsSetupAcknowledge').checked = false; $('awsSetupReplace').checked = false;
      notice('Plan requested. Review the exact resources and permissions before deployment.'); renderOperation();
    });
  }
  async function perform(action, body) {
    if (!validId(operation?.id)) return;
    const id = operation.id;
    await work(async () => {
      operation = await call(`/${id}/${action}`, {method:'POST', body});
      if (body.session_id) sessionOperation = id;
      if (action === 'discard') planKey = null;
      notice('Operation accepted. Progress is durable; closing this page does not cancel an AWS deployment.');
      renderOperation();
    });
  }
  function clear() {
    generation++; clearTimeout(timer); timer = null;
    session = null; sessionOperation = null; selectedId = ''; operation = null; operations = []; config = null;
    planKey = null; busy = false; loading = false;
    if (!initialized) return;
    clearSecrets();
    for (const id of ['awsSetupAcknowledge','awsSetupReplace','awsSetupRetain','awsSetupProbeConsent']) $(id).checked = false;
    $('awsSetupDeleteName').value = ''; notice(''); renderHistory(); renderConfig(); renderOperation();
  }
  function init(apiHooks) {
    if (initialized || !$('awsSetupPanel')) return;
    hooks = apiHooks; initialized = true;
    $('awsSetupConnectForm').addEventListener('submit', event => void connect(event));
    $('awsSetupPlanForm').addEventListener('submit', event => void plan(event));
    $('awsSetupPlanForm').addEventListener('input', () => { planKey = null; });
    $('awsSetupDisconnect').addEventListener('click', () => void work(async () => {
      const sid = session?.session_id, epoch = generation;
      try { if (sid) await call('/disconnect', {method:'POST', body:{session_id:sid}}); }
      finally { if (epoch === generation) { session = null; sessionOperation = null; clearSecrets(); renderConfig(); } }
      notice('Setup credential copy discarded. Any AWS deployment continues; the AWS key itself has not been revoked.');
    }));
    $('awsSetupRefresh').addEventListener('click', () => void refresh());
    $('awsSetupBudgets').addEventListener('click', () => window.EcaiComputeSettings?.selectSection('computeBudget', true));
    $('awsSetupHistory').addEventListener('change', () => {
      selectedId = $('awsSetupHistory').value; operation = null;
      for (const id of ['awsSetupAcknowledge','awsSetupReplace','awsSetupProbeConsent','awsSetupRetain']) $(id).checked = false;
      $('awsSetupDeleteName').value = ''; renderOperation(); void refresh();
    });
    for (const id of ['awsSetupAcknowledge','awsSetupReplace','awsSetupProbeConsent','awsSetupDeleteName','awsSetupRetain']) $(id).addEventListener('input', updateControls);
    $('awsSetupDeploy').addEventListener('click', () => {
      if (!matchingSession() || !$('awsSetupAcknowledge').checked) return;
      void perform('deploy', {session_id:session.session_id, plan_sha256:operation.plan.plan_sha256, confirm:'create aws environment', acknowledge_costs_and_iam:true, replace_connection:$('awsSetupReplace').checked});
    });
    $('awsSetupReconcile').addEventListener('click', () => { if (matchingSession()) void perform('reconcile', {session_id:session.session_id}); });
    $('awsSetupDiscard').addEventListener('click', () => { if (confirm('Discard this unused plan? No AWS resources will be changed.')) void perform('discard', {}); });
    $('awsSetupVerify').addEventListener('click', () => void perform('verify', {}));
    $('awsSetupProbe').addEventListener('click', () => {
      if (!$('awsSetupProbeConsent').checked || !confirm('Run one chargeable synthetic AWS job? This is separate from your indexing allowance.')) return;
      void perform('probe', {confirm:'run paid verification job'});
    });
    $('awsSetupProbeStatus').addEventListener('click', () => void perform('probe-status', {}));
    $('awsSetupDelete').addEventListener('click', () => {
      if (!matchingSession() || !$('awsSetupRetain').checked || $('awsSetupDeleteName').value !== operation.plan?.stack_name) return;
      if (!confirm('Remove this AWS environment and its logs? The S3 bucket and stored artifacts will remain and may continue to incur charges.')) return;
      void perform('delete', {session_id:session.session_id, confirm:$('awsSetupDeleteName').value, retain_artifacts:true});
    });
    $('awsSetupDownloadTemplate').addEventListener('click', () => {
      if (!operation?.plan?.template) return;
      const url = URL.createObjectURL(new Blob([JSON.stringify(operation.plan.template, null, 2)], {type:'application/json'}));
      const a = document.createElement('a'); a.href = url; a.download = `ecai-aws-${operation.id}.json`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) void refresh(); else clearTimeout(timer); });
    renderConfig(); updateControls();
  }
  window.EcaiAwsSetup = {init, refresh, clear, version:'automatic-aws-v1'};
})();
