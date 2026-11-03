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
// Public configuration and recorded version IDs only. Shell-quote every value;
// the browser never reads the secret or invokes AWS. The admin runs these blocks.
export function shellQuote(value) {
  return "'" + String(value).replaceAll("'", "'\\''") + "'";
}
export function awsAdminCommands(data, now = Date.now() / 1000) {
  const health = data?.health || {}, aws = health.setup?.aws || {};
  const region = setupText(aws.region), account = setupText(aws.expected_account_id);
  const secret = setupText(aws.secret_id), role = setupText(aws.expected_role_name);
  const result = {inspect: '', pending: '', promote: '', reason: ''};
  if (!/^[a-z]{2}(?:-[a-z]+)+-\d+$/.test(region) || !/^\d{12}$/.test(account) ||
      !/^[\w+=,.@-]{1,64}$/.test(role) || !/^[A-Za-z0-9/_+=.@:-]{1,2048}$/.test(secret)) {
    result.reason = 'Run Check health with the configured AWS account, region, secret and role to generate commands.';
    return result;
  }
  const common = (beforeAws = '') => `(
set +x
set -euo pipefail
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off
: "\${BUNKER_ADMIN_PROFILE:?Export BUNKER_ADMIN_PROFILE with your authorised AWS CLI profile first}"
bunker_aws() { command aws --no-cli-pager --no-cli-auto-prompt --profile "$BUNKER_ADMIN_PROFILE" --region ${shellQuote(region)} "$@"; }
${beforeAws}BUNKER_ACCOUNT=${shellQuote(account)}
BUNKER_SECRET=${shellQuote(secret)}
[[ "$(bunker_aws sts get-caller-identity --query Account --output text)" == "$BUNKER_ACCOUNT" ]] || { echo 'Wrong AWS account' >&2; exit 1; }
BUNKER_META=$(bunker_aws secretsmanager describe-secret --secret-id "$BUNKER_SECRET" --output json)
BUNKER_ARN=$(jq -er --arg account "$BUNKER_ACCOUNT" --arg region ${shellQuote(region)} '
  .ARN | select(split(":")[3] == $region and split(":")[4] == $account)
' <<< "$BUNKER_META")
`;
  const noRotation = `jq -e '.RotationEnabled != true' <<< "$BUNKER_META" >/dev/null || { echo 'Coordinate the existing rotation before continuing' >&2; exit 1; }
`;
  const list = `bunker_aws secretsmanager list-secret-version-ids --secret-id "$BUNKER_ARN" \\
  --query 'Versions[].{VersionId:VersionId,Stages:VersionStages}' --output table`;
  result.inspect = common() + `bunker_aws sts get-caller-identity
${list}
bunker_aws iam get-role --role-name ${shellQuote(role)} \\
  --query 'Role.{Arn:Arn,Trust:AssumeRolePolicyDocument,Boundary:PermissionsBoundary}' --output json
bunker_aws iam list-attached-role-policies --role-name ${shellQuote(role)} --output table
bunker_aws iam list-role-policies --role-name ${shellQuote(role)} --output table
bunker_aws secretsmanager get-resource-policy --secret-id "$BUNKER_ARN" --output json
)`;
  result.pending = common() + noRotation + `# Do not replace an existing pending rehearsal or rotation.
jq -e '[.VersionIdsToStages[] | select(index("AWSPENDING"))] | length == 0' <<< "$BUNKER_META" >/dev/null || { echo 'AWSPENDING already exists; inspect its owner and evidence' >&2; exit 1; }
BUNKER_BASELINE=$(jq -er '.VersionIdsToStages | to_entries | map(select(.value | index("AWSCURRENT"))) | if length == 1 then .[0].key else error("Expected one current version") end' <<< "$BUNKER_META")
BUNKER_PENDING=$(python3 -c 'import uuid; print(uuid.uuid4())')
BUNKER_STAGE="HANDOFF-$BUNKER_PENDING"
# AWS CLI history can record secret responses. Disable it for this profile.
bunker_aws configure set cli_history disabled
# The existing SecretString travels through pipes, never shell arguments/files.
bunker_aws secretsmanager get-secret-value --secret-id "$BUNKER_ARN" \\
  --version-id "$BUNKER_BASELINE" --version-stage AWSCURRENT --output json |
jq -e --arg secret "$BUNKER_ARN" --arg token "$BUNKER_PENDING" --arg stage "$BUNKER_STAGE" --arg baseline "$BUNKER_BASELINE" '
  if .VersionId != $baseline or (.SecretString | type) != "string" or (.SecretString | length) == 0
  then error("Expected the current nonempty SecretString")
  else {SecretId:$secret, ClientRequestToken:$token, SecretString:.SecretString, VersionStages:[$stage]} end
' | bunker_aws secretsmanager put-secret-value --cli-input-json file:///dev/stdin \\
  --query '{VersionId:VersionId,Stages:VersionStages}' --output json
# Attach AWSPENDING only if no other version holds it; never steal that label.
bunker_aws secretsmanager update-secret-version-stage --secret-id "$BUNKER_ARN" \\
  --version-stage AWSPENDING --move-to-version-id "$BUNKER_PENDING"
bunker_aws secretsmanager update-secret-version-stage --secret-id "$BUNKER_ARN" \\
  --version-stage "$BUNKER_STAGE" --remove-from-version-id "$BUNKER_PENDING"
BUNKER_META=$(bunker_aws secretsmanager describe-secret --secret-id "$BUNKER_ARN" --output json)
jq -e --arg baseline "$BUNKER_BASELINE" --arg pending "$BUNKER_PENDING" '
  (.VersionIdsToStages[$baseline] | index("AWSCURRENT")) != null and
  (.VersionIdsToStages[$pending] | index("AWSPENDING")) != null
' <<< "$BUNKER_META" >/dev/null || { echo 'Version labels changed; stop and reconcile' >&2; exit 1; }
printf 'Baseline: %s\\nPending:  %s\\nNext: run Check pending version in the dashboard.\\n' "$BUNKER_BASELINE" "$BUNKER_PENDING"
)`;
  const report = data.evidence?.pending || {};
  const provenance = report.recovery?.secret_provenance || {};
  const baseline = provenance.baseline_version_id, pending = provenance.version_id;
  const version = v => typeof v === 'string' && /^[A-Za-z0-9-]{32,64}$/.test(v);
  // This enables a command template, not acceptance. The backend owns closure.
  if (health.status !== 'passed' || !freshness(health, 60, now)) {
    result.reason = 'Run Check health and resolve its controls before copying promotion commands. Retain the existing pending evidence.';
    return result;
  }
  if (data.busy || data.last_error || report.status !== 'passed' || !freshness(report, 86400, now) ||
      !report.target || report.target !== health.target || !report.fingerprint || report.fingerprint !== health.fingerprint ||
      !version(baseline) || !version(pending) || baseline === pending) {
    result.reason = 'Promotion requires a passing, unexpired pending rehearsal for this deployment. If already promoted, continue to restore and restart; do not rerun pending.';
    return result;
  }
  const expiry = `BUNKER_NOW=$(date +%s)
[[ "$BUNKER_NOW" -ge ${report.completed_at} && "$BUNKER_NOW" -le ${report.completed_at + 86400} ]] || { echo 'Pending evidence expired or clock is behind it; return to the dashboard' >&2; exit 1; }
`;
  result.promote = common(expiry) + noRotation + `# IDs from the passing pending rehearsal; do not substitute the latest AWS IDs.
BUNKER_BASELINE=${shellQuote(baseline)}
BUNKER_TESTED=${shellQuote(pending)}
jq -e --arg baseline "$BUNKER_BASELINE" --arg tested "$BUNKER_TESTED" '
  (.VersionIdsToStages[$baseline] | index("AWSCURRENT")) != null and
  (.VersionIdsToStages[$tested] | index("AWSPENDING")) != null
' <<< "$BUNKER_META" >/dev/null || { echo 'AWS labels differ from the tested evidence; stop and reconcile' >&2; exit 1; }
bunker_aws secretsmanager update-secret-version-stage --secret-id "$BUNKER_ARN" \\
  --version-stage AWSCURRENT --move-to-version-id "$BUNKER_TESTED" \\
  --remove-from-version-id "$BUNKER_BASELINE"
BUNKER_META=$(bunker_aws secretsmanager describe-secret --secret-id "$BUNKER_ARN" --output json)
jq -e --arg tested "$BUNKER_TESTED" '(.VersionIdsToStages[$tested] | index("AWSCURRENT")) != null' <<< "$BUNKER_META" >/dev/null
${list}
printf 'Next: Verify current version & restore, then Restart & verify. Do not rerun Check pending version.\\n'
)`;
  return result;
}
// Navigation only: backend closure remains the authority to accept a handover.
export function acceptanceReady(data) {
  if (!data || data.busy || data.last_error) return false;
  if (data.closure === 'awaiting_acceptance') return true;
  const tasks = new Map((Array.isArray(data.closure_tasks) ? data.closure_tasks : []).map(task => [task.id, task.status]));
  return ['live_signing', 'cold_restart', 'backup_restore', 'version_promotion'].every(id => tasks.get(id) === 'passed') &&
    ['stale', 'passed'].includes(tasks.get('current_controls'));
}
export function nextHandoverStep(data, context = {}, now = Date.now() / 1000) {
  const step = (id, phase, owner, status, title, description, kind, action, label, help, alternate) =>
    ({id, phase, owner, status, title, description, kind, action, label, help, alternate});
  if (!data || context.loadFailed) return step('refresh', 'prepare', 'Node operator', 'blocked', 'Refresh the recorded status',
    'Current observations are unavailable. Refresh before running checks or copying commands.', 'refresh', null, 'Refresh status');
  if (data.busy || context.loading) return step('busy', 'prepare', 'Node operator', 'running', 'Verification in progress',
    'Wait for the recorded result. You can return to this page; opening it does not rerun checks.', 'none', null, 'Working…');
  if (data.last_error) return step('storage', 'prepare', 'Host administrator', 'blocked', 'Restore evidence recording',
    'Resolve the evidence storage error, then run Check health to confirm a new result can be recorded.', 'run', 'health', 'Check health', 'bunker-files-guide');
  const h = data.health || {}, e = data.evidence || {}, p = e.pending || {}, r = e.recovery || {}, v = e.verify || {}, restart = e.restart || {};
  const tasks = new Map((Array.isArray(data.closure_tasks) ? data.closure_tasks : []).map(task => [task.id, task.status]));
  const pass = id => tasks.get(id) === 'passed';
  const freshHealth = freshness(h, 60, now), bad = (h.checks || []).find(c => c.status !== 'passed');
  const healthStep = () => step('health', 'prepare', 'Node operator', h.status === 'failed' ? 'failed' : 'not_checked',
    bad && freshHealth ? `Resolve ${LABELS[bad.id] || bad.id.replaceAll('_', ' ')}` : 'Check the bunker health',
    bad && freshHealth ? bad.next_action : 'Check the deployed identity, AWS custody, policy, relays and file controls.',
    'run', 'health', 'Check health', bad ? CONTROL_GUIDES[bad.id] || 'bunker-health-guide' : 'bunker-health-guide');
  const accepted = data.handover_status === 'accepted' && data.acceptance;
  if (accepted) {
    const current = data.closure === 'accepted' && typeof v.sha256 === 'string' && /^[a-f0-9]{64}$/.test(v.sha256) && data.acceptance.report_sha256 === v.sha256 && freshHealth && h.status === 'passed' && !bad;
    return step('export', 'close', 'Node operator', current ? 'accepted' : 'recorded', 'Handover recorded',
      current ? 'Export the accepted evidence and attach it to the handover ticket with the supporting references.' :
      bad && freshHealth ? `Acceptance is historical. Current control needs attention: ${LABELS[bad.id] || bad.id}. ${bad.next_action}` :
      data.acceptance.report_sha256 !== v.sha256 ? 'Acceptance refers to an earlier signing report. Export includes current observations and the retained declaration; keep the original accepted report in the handover ticket.' :
      'Acceptance is historical; it does not certify current health. Export the record or check the running service.',
      'export', null, 'Export handover evidence', 'bunker-acceptance-guide', {kind: 'run', action: 'health', label: 'Check current health'});
  }
  if (freshHealth && (h.status !== 'passed' || bad)) return healthStep();
  if (acceptanceReady(data)) return step('acceptance', 'close', 'Node operator', 'ready', 'Record operator acceptance',
    'Review the four evidence references. Submission refreshes health and records acceptance only if every server check still passes.',
    'guide', 'bunker-acceptance-guide', 'Review acceptance', 'bunker-acceptance-guide');
  const target = report => typeof h.target === 'string' && !!h.target && report.target === h.target;
  const version = id => typeof id === 'string' && /^[A-Za-z0-9-]{32,64}$/.test(id);
  const provenance = p.recovery?.secret_provenance || {}, tested = provenance.version_id, baseline = provenance.baseline_version_id;
  const validIds = version(tested) && version(baseline) && tested !== baseline;
  const pendingGood = p.status === 'passed' && freshness(p, 86400, now) && target(p) && validIds;
  const rd = r.recovery || {}, restoredId = rd.secret_provenance?.version_id;
  const afterPending = Number.isInteger(p.completed_at) && Number.isInteger(r.started_at) && r.started_at >= p.completed_at;
  const promotedObserved = validIds && (restoredId === tested && afterPending || restart.active_secret_version === tested || v.active_secret_version === tested);
  const restoreGood = pendingGood && r.status === 'passed' && freshness(r, 86400, now) && target(r) &&
    afterPending && restoredId === tested && rd.backup_restored === true && rd.metadata_restore?.restored === true && rd.wrong_unlock_rejected === true;
  const reconcile = () => step('reconcile', 'admin', 'AWS administrator + node operator', 'blocked', 'Reconcile the recorded versions',
    'Retain the existing evidence. Compare the AWS labels and recorded IDs before starting another rehearsal; do not rerun pending on an already promoted version.',
    'guide', 'bunker-versions-guide', 'Review version evidence', 'bunker-custody-guide');
  const retainedVersionEvidence = !validIds &&
    (r.status === 'passed' && version(restoredId) || restart.status === 'passed' && version(restart.active_secret_version));
  if (!pendingGood && (promotedObserved || retainedVersionEvidence || version(tested) && tested === baseline || p.status === 'passed')) return reconcile();
  if (restoreGood) {
    const bootMatches = target(restart) && restart.active_secret_version === tested && v.active_secret_version === tested &&
      restart.runtime_instance && restart.runtime_instance === v.runtime_instance;
    if (!bootMatches || !pass('cold_restart')) return step('restart', 'close', 'Node operator', restart.status === 'failed' ? 'failed' : 'ready',
      'Restart under the runtime role', 'Confirm temporary administrator access is removed and retain its reference. Restart briefly interrupts signing and also verifies every relay.',
      'run', 'restart', 'Restart & verify', 'bunker-restart-guide');
    if (!pass('live_signing')) return step('signing', 'close', 'Node operator', 'verification_required', 'Refresh signing evidence',
      'The matching restart is recorded. Refresh only the signing checks required by the current checklist.', 'run', 'verify', 'Verify signing', 'bunker-signing-guide');
    if (!freshHealth || !pass('current_controls')) return healthStep();
    // Local inference cannot manufacture server eligibility.
    return step('checklist', 'close', 'Node operator', 'blocked', 'Resolve the remaining requirement',
      'The server has not marked every technical requirement passed. Open the checklist and resolve its outstanding row.',
      'guide', 'bunker-closing-guide', 'Open closing checklist', 'bunker-closing-guide');
  }
  if (pendingGood) {
    const recoveryAttempted = afterPending && target(r) && r.status === 'failed';
    if (promotedObserved || context.promotedFor && context.promotedFor === p.sha256 || recoveryAttempted) {
      return step('restore', 'close', 'Node operator', recoveryAttempted ? 'failed' : 'verification_required', 'Verify promotion and restore',
        recoveryAttempted ? 'The restore check failed. Resolve its recorded cause and retry; retain the passing pending rehearsal.' :
        'After the administrator runs promotion successfully, verify AWS current and the isolated backup restore. Copied commands alone do not prove promotion.',
        'run', 'recovery', 'Verify current version & restore', 'bunker-restore-guide', {kind: 'guide', action: 'bunker-restore-guide', label: 'Review promotion commands'});
    }
    if (!freshHealth) return step('promotion_health', 'admin', 'Node operator', 'stale', 'Refresh health before promotion',
      'Keep the administrator in this session. Refresh health to enable the exact-version promotion commands; preserve the pending rehearsal.',
      'run', 'health', 'Check health', 'bunker-restore-guide');
    const commands = awsAdminCommands(data, now);
    if (!commands.promote) return reconcile();
    return step('promote', 'admin', 'AWS administrator', 'ready', 'Promote the tested version',
      'Run the copied commands in the administrator shell, then return here to verify restore. Keep this one administrator session open through promotion.',
      'copy', 'promote', 'Copy promotion commands', 'bunker-restore-guide', {kind: 'run', action: 'recovery', label: 'Already promoted? Verify restore'});
  }
  if (!h.completed_at || !h.target || h.status !== 'passed') return healthStep();
  if (!pass('live_signing')) return step('signing', 'prepare', 'Node operator', v.status === 'failed' ? 'failed' : 'not_checked',
    'Verify every configured relay', 'Resolve any signing failure before bringing the AWS administrator into the session.',
    'run', 'verify', 'Verify signing', 'bunker-signing-guide');
  if (context.preparedFor && context.preparedFor === h.target || p.status === 'failed') return step('pending', 'admin', 'Node operator',
    p.status === 'failed' ? 'failed' : 'verification_required', 'Check the prepared version',
    'Run the copied prepare commands successfully first, then check the pending version. This check establishes the evidence; copying does not.',
    'run', 'pending', 'Check pending version', 'bunker-pending-guide', {kind: 'copy', action: 'pending', label: 'Copy prepare commands again'});
  const commands = awsAdminCommands(data, now);
  if (!commands.pending) return step('config', 'prepare', 'Node operator', 'blocked', 'Confirm AWS configuration', commands.reason,
    'guide', 'bunker-custody-guide', 'Open AWS setup', 'bunker-custody-guide');
  return step('prepare', 'admin', 'AWS administrator', 'ready', 'Begin the single administrator session',
    'Set BUNKER_ADMIN_PROFILE in the administrator shell, then run the prepare commands. Stay together for pending verification and promotion.',
    'copy', 'pending', 'Copy prepare commands', 'bunker-pending-guide', {kind: 'run', action: 'pending', label: 'Already prepared? Check pending'});
}
// Presentation stays separate from evidence eligibility.
export function handoverView(step) {
  const copy = {
    refresh: ['Connection lost', 'Reconnect to load the latest result.', 'Retry'],
    busy: ['Checking…', 'You can leave this page and return later.', 'Checking…'],
    storage: ['Evidence could not be saved', 'Fix storage access, then retry the health check.', 'Check health'],
    health: ['Check health', 'Check the signer, AWS access and relays.', 'Check health'],
    signing: ['Test signing', 'Test every configured relay.', 'Verify signing'],
    prepare: ['Prepare a test version', 'Run these commands, then test the prepared version.', 'Copy prepare commands'],
    pending: ['Test the prepared version', 'Run after the prepare commands succeed.', 'Test prepared version'],
    promotion_health: ['Refresh health', 'A fresh check is needed before promotion.', 'Check health'],
    promote: ['Activate the tested version', 'Run these commands, then test recovery.', 'Copy promotion commands'],
    restore: ['Test recovery', 'Run after promotion succeeds. The live vault stays in place.', 'Test recovery'],
    restart: ['Restart and test', 'Remove temporary admin access first. Signing pauses briefly.', 'Restart and test'],
    acceptance: ['Complete handover', 'Add the four review references and sign off.', 'Complete handover'],
    reconcile: ['Check AWS versions', 'Compare recorded IDs with AWS. Do not repeat the pending test after promotion.', 'Review versions'],
    checklist: ['A check needs attention', 'Open the failed check for its next action.', 'View checks'],
    config: ['Check AWS settings', 'Confirm account, region, secret and runtime role.', 'Open settings'],
    export: ['Handover recorded', 'Download the report for your handover ticket.', 'Download report']
  }[step.id];
  if (!copy) return step;
  let [title, description, label] = copy;
  if (step.status === 'failed') { title = step.title; description = step.description; }
  if (step.id === 'export' && step.status !== 'accepted') description = step.description;
  return {...step, title, description, label};
}
const root = typeof document === 'undefined' ? null : document.querySelector('[data-bunker-root]');
if (root) {
  let data = null, timer = null, loading = false, loadFailed = false;
  const flowHints = {preparedFor: null, promotedFor: null};
  let accepting = false, refreshEpoch = 0;
  const byId = id => root.querySelector(`#${id}`);
  const el = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (cls) n.className = cls; return n; };
  const words = v => String(v ?? 'not_checked').replaceAll('_', ' ');
  const badge = state => { const n = el('span', words(state), 'bunker-badge'); n.dataset.status = state; return n; };
  const time = r => r?.completed_at ? new Date(r.completed_at * 1000).toLocaleString() : 'Not checked';
  const message = (text, error = false) => { byId('bunker-message').hidden = !error && /^(Recorded evidence loaded|Health evidence is stale)/.test(text); byId('bunker-message').textContent = text; byId('bunker-message').classList.toggle('bunker-error', error); };
  const guideLink = (id, title) => { const a = el('a', title, 'bunker-guide-link'); a.href = `#${id}`; a.dataset.bunkerGo = ''; return a; };
  function showPane(name) {
    for (const t of root.querySelectorAll('[data-bunker-tab]')) t.setAttribute('aria-pressed', String(t.dataset.bunkerTab === name));
    for (const p of root.querySelectorAll('[data-bunker-pane]')) p.hidden = p.dataset.bunkerPane !== name;
  }
  function openGuide(id) {
    const target = document.getElementById(id);
    if (!target || !root.contains(target)) return;
    for (let parent = target.parentElement; parent && parent !== root; parent = parent.parentElement) {
      if (parent.tagName === 'DETAILS') parent.open = true;
    }
    const signoff = target.closest('#bunker-signoff-panel'); if (signoff) signoff.hidden = false;
    const pane = target.closest('[data-bunker-pane]'); if (pane) showPane(pane.dataset.bunkerPane);
    target.focus({preventScroll: true}); target.scrollIntoView({block: 'start'});
  }
  function flowStep() { return nextHandoverStep(data, {...flowHints, loading, loadFailed}); }
  function renderNext() {
    const next = handoverView(flowStep());
    byId('bunker-next-phase').textContent = {prepare: 'Handover · Check', admin: 'Handover · Activate', close: 'Handover · Finish'}[next.phase];
    byId('bunker-next-owner').textContent = next.owner === 'AWS administrator + node operator' ? 'AWS admin + dashboard node admin' : next.owner.includes('AWS') ? 'AWS admin' : next.owner === 'Host administrator' ? 'Host admin' : 'Dashboard node admin';
    byId('bunker-next-status').textContent = ({not_checked:'To do',verification_required:'To do',ready:'Ready',running:'Running',stale:'Recheck',failed:'Needs attention',blocked:'Blocked',accepted:'Complete',recorded:'Recorded'})[next.status] || words(next.status);
    byId('bunker-next-status').dataset.status = next.status;
    byId('bunker-next-title').textContent = next.title;
    byId('bunker-next-description').textContent = next.description;
    byId('bunker-next-action').textContent = next.label;
    byId('bunker-next-action').disabled = next.kind === 'none';
    byId('bunker-next-action').hidden = next.id === 'health';
    const healthButton = root.querySelector('.bunker-live [data-bunker-action]');
    healthButton.disabled = !data || loading || !!data.busy || loadFailed;
    healthButton.classList.toggle('bunker-primary', next.id === 'health');
    const alternate = byId('bunker-next-alternate'); alternate.hidden = !next.alternate;
    alternate.textContent = next.alternate?.label || '';
    const help = byId('bunker-next-help'); help.hidden = !next.help;
    if (next.help) { help.href = `#${next.help}`; help.textContent = 'Help'; }
    const health = data?.health || {}, recent = !loadFailed && freshness(health, 60);
    byId('bunker-live-status').textContent = loadFailed ? 'Health unavailable' : !health.completed_at ? 'Health not checked' : !recent ? 'Health check due' : health.status === 'passed' ? 'Healthy' : 'Needs attention';
    byId('bunker-live-status').dataset.status = recent ? health.status : 'stale';
    byId('bunker-live-time').textContent = health.completed_at ? `Checked ${time(health)}` : 'Run a health check to begin';
    const inline = byId('bunker-inline-commands');
    const command = next.kind === 'copy' && !loadFailed ? awsAdminCommands(data)[next.action] : '';
    inline.hidden = !command;
    if (byId('bunker-inline-code').textContent !== (command || '')) byId('bunker-inline-code').textContent = command || '';
    const passed = (Array.isArray(data?.closure_tasks) ? data.closure_tasks : []).filter(task => task.id !== 'operator_acceptance' && task.status === 'passed').length;
    byId('bunker-next-progress').textContent = data ? `${passed} of 5 technical requirements currently passed · ${data.acceptance ? 'Acceptance record retained' : 'Operator acceptance still required'}` : 'Loading recorded progress…';
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
  function renderAwsCommands() {
    const commands = loadFailed ? {reason: 'Refresh health before copying commands; current observations are unavailable.'} : awsAdminCommands(data);
    for (const action of ['inspect', 'pending', 'promote']) {
      const code = byId(`bunker-cli-${action}`), text = commands[action];
      if (code && code.textContent !== (text || commands.reason)) code.textContent = text || commands.reason;
      const button = root.querySelector(`[data-bunker-copy="${action}"]`);
      if (button) button.disabled = !text || loading || !!data?.busy;
    }
  }
  function render() {
    renderNext();
    if (!data) return;
    renderAwsCommands();
    const evidence = data.evidence || {}, health = data.health || {}, verification = evidence.verify || {};
    const healthy = loadFailed ? 'stale' : displayStatus(health, 60);
    const signed = loadFailed || (health.fingerprint && health.fingerprint !== verification.fingerprint) ? 'stale' : displayStatus(verification, 900);
    const controls = health.checks || [];
    const custody = controls.find(c => c.id === 'aws_provenance');
    const summary = byId('bunker-summary'); summary.replaceChildren();
    for (const [title, status, description] of [
      ['Service health', healthy === 'stale' ? 'stale' : health.checks?.find(c => c.id === 'service_ready')?.status || 'not_checked', time(health)], ['Live signing', signed, time(verification)],
      ['AWS custody', healthy === 'stale' ? 'stale' : custody?.status || 'not_checked', 'Named controls; last observed ' + time(health)],
      ['Handover', loadFailed ? 'verification_required' : data.handover_status === 'accepted' ? (data.closure === 'accepted' ? 'accepted' : 'recorded') : data.closure, data.handover_status === 'accepted' ? 'Acceptance retained; consult current check timestamps' : 'Complete required checks and acceptance']
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
    for (const b of root.querySelectorAll('[data-bunker-action]')) b.disabled = data.busy || loading || loadFailed;
    byId('bunker-accept').disabled = loading || data.busy || !!data.last_error || loadFailed || !acceptanceReady(data);
    for (const b of root.querySelectorAll('[data-bunker-export]')) b.disabled = !Object.keys(evidence).length;
  }
  async function refresh() {
    if (accepting) return;
    const epoch = ++refreshEpoch;
    clearTimeout(timer); timer = null;
    try { const observed = await request(); if (epoch !== refreshEpoch) return; data = observed; loadFailed = false; render(); message(data.last_error ? `Evidence recording failed: ${words(data.last_error)}. Run a fresh check after resolving storage access.` : data.busy ? 'Verification in progress. You can leave this page and return to the recorded result.' :
      data.health_stale ? 'Health evidence is stale or has not been collected. Run Check health.' : 'Recorded evidence loaded.');
    } catch (error) { if (epoch !== refreshEpoch) return; loadFailed = true; message(`Could not refresh: ${error.message}. Previously displayed results may be stale.`, true); render(); }
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
  async function runAction(action, guided = false) {
    if (loading || data?.busy || loadFailed) return;
    const maintenanceContext = () => JSON.stringify([data?.health?.target,
      ...['pending', 'recovery', 'restart'].map(key => {
        const report = data?.evidence?.[key];
        return report ? [report.sha256, report.completed_at, report.status] : null;
      })]);
    const beforeConfirmation = maintenanceContext();
    if (!await confirmAction(action)) return;
    // Re-evaluate after the confirmation; another operator may have started work.
    if (loading || data?.busy || loadFailed) return;
    if (maintenanceText[action] && beforeConfirmation !== maintenanceContext()) {
      render(); message('Maintenance evidence changed while the confirmation was open. Review the current step before continuing.', true); return;
    }
    if (guided) {
      const current = flowStep();
      if (!(current.kind === 'run' && current.action === action) &&
          !(current.alternate?.kind === 'run' && current.alternate.action === action)) {
        render(); message('The next action changed. Review the current result before continuing.', true); return;
      }
    }
    loading = true; render();
    try { await request({action, ...(maintenanceText[action] ? {confirmed: true} : {})}); await refresh(); }
    catch (error) { message(error.message, true); } finally { loading = false; render(); }
  }
  async function copyCommands(action) {
    if (loading || data?.busy || loadFailed) return;
    renderAwsCommands();
    const commands = awsAdminCommands(data), text = commands[action];
    const copiedTarget = data.health?.target, copiedReport = data.evidence?.pending?.sha256;
    if (!text) { render(); message(commands.reason, true); return; }
    try { await navigator.clipboard.writeText(text); message('Commands copied. Run them in the administrator shell, then use the next verification action.'); }
    catch {
      openGuide(action === 'inspect' ? 'bunker-custody-guide' : action === 'pending' ? 'bunker-pending-guide' : 'bunker-restore-guide');
      const code = byId(`bunker-cli-${action}`); code.closest('details').open = true;
      const selection = window.getSelection(), range = document.createRange(); range.selectNodeContents(code); selection.removeAllRanges(); selection.addRange(range);
      message('Clipboard unavailable. Commands selected; copy and run them before verification.');
    }
    if (action === 'pending') flowHints.preparedFor = copiedTarget;
    if (action === 'promote') flowHints.promotedFor = copiedReport;
    renderNext();
  }
  function exportEvidence() {
    if (!data) return; const url = URL.createObjectURL(new Blob([JSON.stringify({...data, exported_at: new Date().toISOString(), observation_note: loadFailed ? 'Cached observations; refresh unavailable' : 'Recorded observations; consult individual timestamps'}, null, 2)], {type: 'application/json'}));
    const a = el('a'); a.href = url; a.download = 'bunker-handoff-evidence.json'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  async function takeStep(next) {
    if (next.kind === 'refresh') { await refresh(); return; }
    if (next.kind === 'guide') { openGuide(next.action); return; }
    if (next.kind === 'copy') { await copyCommands(next.action); return; }
    if (next.kind === 'export') { exportEvidence(); return; }
    if (next.kind === 'run') await runAction(next.action, true);
  }
  byId('bunker-next-action').addEventListener('click', () => void takeStep(flowStep()));
  byId('bunker-next-alternate').addEventListener('click', () => { const next = flowStep().alternate; if (next) void takeStep(next); });
  root.addEventListener('click', async event => {
    const copy = event.target.closest('[data-bunker-copy]');
    if (copy) { await copyCommands(copy.dataset.bunkerCopy); return; }
    const guide = event.target.closest('[data-bunker-go]');
    if (guide) { event.preventDefault(); openGuide(guide.getAttribute('href').slice(1)); return; }
    const tab = event.target.closest('[data-bunker-tab]');
    if (tab) { showPane(tab.dataset.bunkerTab); return; }
    const button = event.target.closest('[data-bunker-action]');
    if (button) await runAction(button.dataset.bunkerAction);
  });
  byId('bunker-acceptance').addEventListener('submit', async event => {
    event.preventDefault(); if (loading || loadFailed || !acceptanceReady(data)) return;
    const form = event.target; if (!form.reportValidity()) return;
    const reportHash = data.evidence?.verify?.sha256;
    const references = Object.fromEntries(new FormData(form));
    if (!reportHash) { message('No signing report is available for acceptance.', true); return; }
    loading = true; accepting = true; refreshEpoch++; clearTimeout(timer); timer = null; render();
    try {
      // One explicit submission refreshes health, then accepts only the reviewed report.
      await request({action: 'health'});
      const deadline = Date.now() + 120000;
      do {
        data = await request(); loadFailed = false; render();
        if (!data.busy) break;
        if (Date.now() >= deadline) throw new Error('Health is still running. Wait for its result, then submit again.');
        await new Promise(resolve => setTimeout(resolve, 1000));
      } while (true);
      if (data.evidence?.verify?.sha256 !== reportHash) throw new Error('The signing report changed. Review the updated evidence before accepting.');
      if (data.last_error || data.closure !== 'awaiting_acceptance') throw new Error('Current checks do not permit acceptance. Resolve the next action and submit again.');
      await request({action: 'accept', report_sha256: reportHash, references});
      accepting = false; await refresh();
    } catch (error) { loadFailed = true; message(error.message, true); }
    finally { accepting = false; loading = false; render(); if (!timer) timer = setTimeout(refresh, 10000); }
  });
  for (const button of root.querySelectorAll('[data-bunker-export]')) button.addEventListener('click', exportEvidence);
  new MutationObserver(() => { if (!root.closest('[hidden]')) refresh(); else clearTimeout(timer); }).observe(root.closest('[data-dashboard-view]') || root, { attributes: true, attributeFilter: ['hidden'] });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && !root.closest('[hidden]')) refresh(); else clearTimeout(timer); });
  renderNext();
  refresh();
}
