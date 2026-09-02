import { authenticate, executeFeature, getVersion } from './api.js';
import { describeError, joinUrl, normalizeBaseUrl } from './shared/http.js';
import { createStore } from './shared/storage.js';
import { byId, formatData, setBusy, setStatus, shortValue } from './shared/ui.js';

const preferences = createStore('damage.mobile.', 'local');
const session = createStore('damage.mobile.session.', 'session');

const SAMPLE_FEATURE = `Feature: Android smoke test
  Verify a public HTTP endpoint from DamageBDD.

  Scenario: example.com responds
    Given I am using server "https://example.com"
    When I make a GET request to "/"
    Then the response status must be "200"
`;

const elements = {
  serverUrl: byId('serverUrl'),
  checkNodeButton: byId('checkNodeButton'),
  nodePill: byId('nodePill'),
  nodeStatus: byId('nodeStatus'),
  loginForm: byId('loginForm'),
  username: byId('username'),
  password: byId('password'),
  loginButton: byId('loginButton'),
  sessionPanel: byId('sessionPanel'),
  accountAddress: byId('accountAddress'),
  logoutButton: byId('logoutButton'),
  authPill: byId('authPill'),
  authStatus: byId('authStatus'),
  featureText: byId('featureText'),
  concurrency: byId('concurrency'),
  resetFeatureButton: byId('resetFeatureButton'),
  executeButton: byId('executeButton'),
  runPill: byId('runPill'),
  runStatus: byId('runStatus'),
  resultCard: byId('resultCard'),
  resultSummary: byId('resultSummary'),
  resultMeta: byId('resultMeta'),
  resultOutput: byId('resultOutput'),
  reportLink: byId('reportLink')
};

let state = {
  token: session.get('token', ''),
  address: session.get('address', '')
};

function serverUrl() {
  const normalized = normalizeBaseUrl(elements.serverUrl.value);
  if (!normalized) throw new Error('Enter a DamageBDD server URL.');
  return normalized;
}

function saveServer() {
  const normalized = normalizeBaseUrl(elements.serverUrl.value);
  elements.serverUrl.value = normalized;
  preferences.set('serverUrl', normalized);
}

function updateAuthUi() {
  const signedIn = Boolean(state.token && state.address);
  elements.loginForm.hidden = signedIn;
  elements.sessionPanel.hidden = !signedIn;
  elements.executeButton.disabled = !signedIn;
  elements.accountAddress.textContent = state.address;
  elements.authPill.textContent = signedIn ? shortValue(state.address, 9, 6) : 'Signed out';
  elements.authPill.dataset.tone = signedIn ? 'success' : 'neutral';
}

function setPill(element, label, tone = 'neutral') {
  element.textContent = label;
  element.dataset.tone = tone;
}

function addMeta(label, value) {
  if (value === undefined || value === null || value === '') return;
  const wrapper = document.createElement('div');
  const term = document.createElement('dt');
  const description = document.createElement('dd');
  term.textContent = label;
  description.textContent = String(value);
  description.title = String(value);
  wrapper.append(term, description);
  elements.resultMeta.append(wrapper);
}

function renderResult(result) {
  elements.resultCard.hidden = false;
  elements.resultOutput.textContent = formatData(result);
  elements.resultMeta.replaceChildren();

  addMeta('Status', result?.status);
  addMeta('Run ID', result?.run_id);
  addMeta('Cost', result?.cost);
  addMeta('Feature hash', result?.feature_hash);
  addMeta('Report hash', result?.report_hash);
  addMeta('Transaction', result?.tx_hash);

  const ok = result?.status === 'ok';
  elements.resultSummary.textContent = ok
    ? 'The feature completed successfully.'
    : result?.message || result?.reason || 'The node returned a result.';

  if (result?.report_hash) {
    elements.reportLink.href = joinUrl(serverUrl(), `/reports/${result.report_hash}`);
    elements.reportLink.hidden = false;
  } else {
    elements.reportLink.hidden = true;
  }
}

async function checkNode() {
  saveServer();
  setBusy(elements.checkNodeButton, true, 'Checking…');
  setPill(elements.nodePill, 'Checking');
  setStatus(elements.nodeStatus, 'Contacting /version/…', 'info');

  try {
    const version = await getVersion(serverUrl());
    const versionText = version?.version || 'unknown version';
    const sha = version?.commit_hash || version?.git_sha || '';
    setPill(elements.nodePill, 'Online', 'success');
    setStatus(
      elements.nodeStatus,
      `Node online · ${versionText}${sha ? ` · ${shortValue(sha, 10, 0)}` : ''}`,
      'success'
    );
  } catch (error) {
    setPill(elements.nodePill, 'Offline', 'danger');
    setStatus(elements.nodeStatus, describeError(error), 'danger');
  } finally {
    setBusy(elements.checkNodeButton, false);
  }
}

async function login(event) {
  event.preventDefault();
  saveServer();
  setBusy(elements.loginButton, true, 'Signing in…');
  setStatus(elements.authStatus, 'Authenticating…', 'info');

  try {
    const result = await authenticate(
      serverUrl(),
      elements.username.value.trim(),
      elements.password.value
    );

    state = { token: result.access_token, address: result.address };
    session.set('token', state.token);
    session.set('address', state.address);
    elements.password.value = '';
    updateAuthUi();
    setStatus(elements.authStatus, `Signed in as ${shortValue(state.address)}.`, 'success');
  } catch (error) {
    setStatus(elements.authStatus, describeError(error), 'danger');
  } finally {
    elements.password.value = '';
    setBusy(elements.loginButton, false);
  }
}

function logout() {
  session.remove('token');
  session.remove('address');
  state = { token: '', address: '' };
  updateAuthUi();
  setStatus(elements.authStatus, 'Signed out. Session credential removed.', 'info');
}

async function runFeature() {
  if (!state.token) {
    setStatus(elements.runStatus, 'Sign in before executing a feature.', 'danger');
    return;
  }

  const feature = elements.featureText.value.trim();
  if (!feature) {
    setStatus(elements.runStatus, 'Enter a feature first.', 'danger');
    return;
  }

  saveServer();
  preferences.set('featureDraft', feature);
  const concurrency = Math.max(1, Number.parseInt(elements.concurrency.value, 10) || 1);
  elements.concurrency.value = String(concurrency);

  setBusy(elements.executeButton, true, 'Executing…');
  setPill(elements.runPill, 'Running', 'info');
  setStatus(elements.runStatus, 'Submitting feature to the DamageBDD node…', 'info');

  try {
    const result = await executeFeature(serverUrl(), state.token, feature, concurrency);
    renderResult(result);
    const ok = result?.status === 'ok';
    setPill(elements.runPill, ok ? 'Passed' : 'Completed', ok ? 'success' : 'neutral');
    setStatus(
      elements.runStatus,
      ok ? 'Feature completed.' : result?.message || result?.reason || 'Execution completed.',
      ok ? 'success' : 'info'
    );
  } catch (error) {
    setPill(elements.runPill, 'Failed', 'danger');
    setStatus(elements.runStatus, describeError(error), 'danger');
    renderResult(error?.data || { status: 'notok', message: describeError(error) });
  } finally {
    setBusy(elements.executeButton, false);
    updateAuthUi();
  }
}

function resetFeature() {
  elements.featureText.value = SAMPLE_FEATURE;
  preferences.set('featureDraft', SAMPLE_FEATURE);
  setStatus(elements.runStatus, 'Sample feature restored.', 'info');
}

function initialise() {
  elements.serverUrl.value = preferences.get(
    'serverUrl',
    'https://run.dev.damagebdd.com'
  );
  elements.featureText.value = preferences.get('featureDraft', SAMPLE_FEATURE);
  updateAuthUi();

  elements.serverUrl.addEventListener('change', saveServer);
  elements.checkNodeButton.addEventListener('click', checkNode);
  elements.loginForm.addEventListener('submit', login);
  elements.logoutButton.addEventListener('click', logout);
  elements.executeButton.addEventListener('click', runFeature);
  elements.resetFeatureButton.addEventListener('click', resetFeature);
  elements.featureText.addEventListener('input', () => {
    preferences.set('featureDraft', elements.featureText.value);
  });
}

initialise();
