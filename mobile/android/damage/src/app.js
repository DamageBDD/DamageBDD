import {
  authenticate,
  authenticateWallet,
  executeFeature,
  getNwcSessions,
  getVersion,
  getWalletSnapshot,
  mintNwcConnection
} from './api.js';
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

const VIEW_NAMES = new Set(['home', 'run', 'wallet', 'settings']);

const elements = {
  appMain: byId('appMain'),
  accountButton: byId('accountButton'),
  accountDot: byId('accountDot'),
  authPill: byId('authPill'),
  homeSubtitle: byId('homeSubtitle'),
  primaryConnectButton: byId('primaryConnectButton'),
  refreshBalancesButton: byId('refreshBalancesButton'),
  balancePill: byId('balancePill'),
  lightningBalance: byId('lightningBalance'),
  lightningDetail: byId('lightningDetail'),
  aeBalance: byId('aeBalance'),
  aeDetail: byId('aeDetail'),
  damageBalance: byId('damageBalance'),
  damageDetail: byId('damageDetail'),
  balanceUpdated: byId('balanceUpdated'),
  balanceStatus: byId('balanceStatus'),

  serverUrl: byId('serverUrl'),
  checkNodeButton: byId('checkNodeButton'),
  nodePill: byId('nodePill'),
  nodeStatus: byId('nodeStatus'),

  connectCard: byId('connectCard'),
  emailTab: byId('emailTab'),
  walletTab: byId('walletTab'),
  emailConnectPanel: byId('emailConnectPanel'),
  walletConnectPanel: byId('walletConnectPanel'),
  loginForm: byId('loginForm'),
  username: byId('username'),
  password: byId('password'),
  loginButton: byId('loginButton'),
  walletConnectForm: byId('walletConnectForm'),
  walletAddress: byId('walletAddress'),
  walletChallenge: byId('walletChallenge'),
  walletSignature: byId('walletSignature'),
  walletConnectButton: byId('walletConnectButton'),
  regenerateChallengeButton: byId('regenerateChallengeButton'),
  copyChallengeButton: byId('copyChallengeButton'),
  pasteSignatureButton: byId('pasteSignatureButton'),
  authStatus: byId('authStatus'),

  sessionCard: byId('sessionCard'),
  sessionMethod: byId('sessionMethod'),
  walletSessionPill: byId('walletSessionPill'),
  accountAddress: byId('accountAddress'),
  copyAddressButton: byId('copyAddressButton'),
  walletRefreshButton: byId('walletRefreshButton'),
  logoutButton: byId('logoutButton'),

  nwcCard: byId('nwcCard'),
  toggleNwcFormButton: byId('toggleNwcFormButton'),
  nwcForm: byId('nwcForm'),
  maxSingleSat: byId('maxSingleSat'),
  maxTotalSat: byId('maxTotalSat'),
  expiresHeight: byId('expiresHeight'),
  createNwcButton: byId('createNwcButton'),
  cancelNwcButton: byId('cancelNwcButton'),
  nwcResult: byId('nwcResult'),
  nwcUri: byId('nwcUri'),
  copyNwcButton: byId('copyNwcButton'),
  openNwcButton: byId('openNwcButton'),
  nwcSummary: byId('nwcSummary'),
  refreshNwcButton: byId('refreshNwcButton'),
  nwcSessions: byId('nwcSessions'),
  nwcStatus: byId('nwcStatus'),

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
  address: session.get('address', ''),
  authMethod: session.get('authMethod', ''),
  walletSnapshot: null,
  nwcSessions: [],
  activeView: 'home'
};

function isSignedIn() {
  return Boolean(state.token && state.address);
}

function serverUrl() {
  const normalized = normalizeBaseUrl(elements.serverUrl.value);
  if (!normalized) throw new Error('Enter a DamageBDD server URL.');
  return normalized;
}

function saveServer({ disconnectOnChange = false } = {}) {
  const previous = preferences.get('serverUrl', '');
  const normalized = normalizeBaseUrl(elements.serverUrl.value);
  if (!normalized) throw new Error('Enter a DamageBDD server URL.');

  elements.serverUrl.value = normalized;
  preferences.set('serverUrl', normalized);

  if (disconnectOnChange && previous && previous !== normalized && isSignedIn()) {
    disconnectSession('Server changed. Reconnect to the selected DamageBDD node.');
  }

  return normalized;
}

function setPill(element, label, tone = 'neutral') {
  element.textContent = label;
  element.dataset.tone = tone;
}

function viewFromHash() {
  const candidate = window.location.hash.replace(/^#/, '');
  return VIEW_NAMES.has(candidate) ? candidate : 'home';
}

function navigate(view, { replace = false } = {}) {
  const target = VIEW_NAMES.has(view) ? view : 'home';
  const hash = `#${target}`;

  if (window.location.hash !== hash) {
    if (replace) window.history.replaceState(null, '', hash);
    else window.location.hash = target;
  }

  activateView(target);
}

function activateView(view) {
  const target = VIEW_NAMES.has(view) ? view : 'home';
  state.activeView = target;

  document.querySelectorAll('.app-view').forEach((section) => {
    const active = section.dataset.view === target;
    section.hidden = !active;
    section.classList.toggle('is-active', active);
  });

  document.querySelectorAll('.nav-item').forEach((button) => {
    const active = button.dataset.navTarget === target;
    button.classList.toggle('is-active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });

  if (target === 'wallet' && isSignedIn()) {
    void loadNwcSessions({ quiet: true });
  }

  window.scrollTo({ top: 0, behavior: 'auto' });
}

function selectConnectMethod(method) {
  const wallet = method === 'wallet';
  elements.emailTab.classList.toggle('is-active', !wallet);
  elements.walletTab.classList.toggle('is-active', wallet);
  elements.emailTab.setAttribute('aria-selected', String(!wallet));
  elements.walletTab.setAttribute('aria-selected', String(wallet));
  elements.emailConnectPanel.hidden = wallet;
  elements.walletConnectPanel.hidden = !wallet;

  if (wallet && !elements.walletChallenge.value) generateWalletChallenge();
}

function updateAuthUi() {
  const signedIn = isSignedIn();

  elements.connectCard.hidden = signedIn;
  elements.sessionCard.hidden = !signedIn;
  elements.nwcCard.hidden = !signedIn;
  elements.executeButton.disabled = !signedIn;
  elements.refreshBalancesButton.disabled = !signedIn;
  elements.walletRefreshButton.disabled = !signedIn;
  elements.refreshNwcButton.disabled = !signedIn;

  elements.accountAddress.textContent = state.address;
  elements.authPill.textContent = signedIn ? shortValue(state.address, 8, 5) : 'Connect';
  elements.accountDot.dataset.connected = String(signedIn);
  elements.primaryConnectButton.textContent = signedIn ? 'Manage wallet' : 'Connect wallet';
  elements.homeSubtitle.textContent = signedIn
    ? `Balances for ${shortValue(state.address, 12, 8)} on the selected DamageBDD node.`
    : 'Connect an account or an AE wallet to see Lightning, AE, and DAMAGE balances.';

  const methodLabel = state.authMethod === 'wallet'
    ? 'Connected with an AE signed message.'
    : 'Connected with a DamageBDD account.';
  elements.sessionMethod.textContent = signedIn ? methodLabel : '';
  setPill(elements.walletSessionPill, signedIn ? 'Connected' : 'Disconnected', signedIn ? 'success' : 'neutral');

  if (!signedIn) renderDisconnectedBalances();
}

function renderDisconnectedBalances() {
  state.walletSnapshot = null;
  elements.lightningBalance.textContent = '—';
  elements.aeBalance.textContent = '—';
  elements.damageBalance.textContent = '—';
  elements.lightningDetail.textContent = 'Connect to view';
  elements.aeDetail.textContent = 'Connect to view';
  elements.damageDetail.textContent = 'Connect to view';
  elements.balanceUpdated.textContent = 'Balances have not been loaded.';
  setPill(elements.balancePill, 'Not connected');
  setStatus(elements.balanceStatus, '', 'neutral');
}

function groupedInteger(value) {
  const text = String(value || '0');
  const sign = text.startsWith('-') ? '-' : '';
  const digits = sign ? text.slice(1) : text;
  return `${sign}${digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
}

function formatAtomic(amount, decimals = 0, maxFraction = decimals) {
  let raw;
  try {
    raw = BigInt(String(amount ?? '0').split('.')[0]);
  } catch {
    return '—';
  }

  const precision = Math.max(0, Number.parseInt(decimals, 10) || 0);
  const fractionLimit = Math.max(0, Math.min(precision, maxFraction));
  const negative = raw < 0n;
  const absolute = negative ? -raw : raw;
  const digits = absolute.toString().padStart(precision + 1, '0');
  const whole = precision ? digits.slice(0, -precision) : digits;
  const fraction = precision ? digits.slice(-precision) : '';
  const visibleFraction = fraction.slice(0, fractionLimit).replace(/0+$/, '');
  const sign = negative ? '-' : '';

  return `${sign}${groupedInteger(whole)}${visibleFraction ? `.${visibleFraction}` : ''}`;
}

function balanceReason(balance, fallback) {
  const reason = balance?.reason;
  if (!reason) return fallback;
  return String(reason).replaceAll('_', ' ');
}

function renderBalanceEntry(asset, balance) {
  const available = balance?.available === true;
  const targetValue = elements[`${asset}Balance`];
  const targetDetail = elements[`${asset}Detail`];

  if (!available) {
    targetValue.textContent = '—';
    targetDetail.textContent = balanceReason(balance, 'Unavailable');
    return;
  }

  if (asset === 'lightning') {
    const msat = balance.amount_msat ?? balance.amount ?? '0';
    const displayed = balance.display || formatAtomic(msat, 3, 3);
    targetValue.textContent = `${displayed} sats`;
    const sessions = Number.parseInt(balance.session_count, 10);
    targetDetail.textContent = Number.isFinite(sessions)
      ? `${sessions} NWC session${sessions === 1 ? '' : 's'}`
      : 'DamageBDD NWC ledger';
    return;
  }

  if (asset === 'ae') {
    const displayed = balance.display || formatAtomic(balance.amount, balance.decimals, 6);
    targetValue.textContent = `${displayed} AE`;
    targetDetail.textContent = 'Aeternity account balance';
    return;
  }

  if (balance.symbol === 'hits') {
    targetValue.textContent = `${groupedInteger(balance.amount)} hits`;
    targetDetail.textContent = balanceReason(balance, 'Legacy raw token units');
    return;
  }

  const displayed = balance.display || formatAtomic(balance.amount, balance.decimals, 4);
  targetValue.textContent = `${displayed} DAMAGE`;
  targetDetail.textContent = 'Available for feature execution';
}

function renderWalletSnapshot(snapshot) {
  state.walletSnapshot = snapshot;
  const balances = snapshot?.balances || {};

  renderBalanceEntry('lightning', balances.lightning);
  renderBalanceEntry('ae', balances.ae);
  renderBalanceEntry('damage', balances.damage);

  const availableCount = ['lightning', 'ae', 'damage']
    .filter((asset) => balances[asset]?.available === true).length;
  const partial = snapshot?.status === 'partial' || availableCount < 3;
  setPill(elements.balancePill, partial ? 'Partial' : 'Current', partial ? 'info' : 'success');

  const updatedAt = Number(snapshot?.updated_at || 0);
  elements.balanceUpdated.textContent = updatedAt > 0
    ? `Updated ${new Date(updatedAt * 1000).toLocaleString()}`
    : 'Balances loaded from DamageBDD.';

  setStatus(
    elements.balanceStatus,
    snapshot?.warning || '',
    snapshot?.warning ? 'info' : 'neutral'
  );
}

async function refreshBalances({ quiet = false } = {}) {
  if (!isSignedIn()) {
    if (!quiet) navigate('wallet');
    return;
  }

  const buttons = [elements.refreshBalancesButton, elements.walletRefreshButton];
  buttons.forEach((button) => setBusy(button, true, 'Refreshing…'));
  setPill(elements.balancePill, 'Refreshing', 'info');
  if (!quiet) setStatus(elements.balanceStatus, 'Loading balances from DamageBDD…', 'info');

  try {
    const snapshot = await getWalletSnapshot(serverUrl(), state.token, state.address);
    renderWalletSnapshot(snapshot);
  } catch (error) {
    setPill(elements.balancePill, 'Unavailable', 'danger');
    setStatus(elements.balanceStatus, describeError(error), 'danger');
  } finally {
    buttons.forEach((button) => setBusy(button, false));
    updateAuthUi();
  }
}

function setAuthenticated(result, method) {
  state.token = result.access_token;
  state.address = result.address;
  state.authMethod = method;
  session.set('token', state.token);
  session.set('address', state.address);
  session.set('authMethod', state.authMethod);
  updateAuthUi();
}

async function login(event) {
  event.preventDefault();
  saveServer();
  setBusy(elements.loginButton, true, 'Connecting…');
  setStatus(elements.authStatus, 'Authenticating with DamageBDD…', 'info');

  try {
    const result = await authenticate(
      serverUrl(),
      elements.username.value.trim(),
      elements.password.value
    );

    setAuthenticated(result, 'account');
    elements.password.value = '';
    setStatus(elements.authStatus, `Connected as ${shortValue(state.address)}.`, 'success');
    navigate('home');
    await refreshBalances({ quiet: true });
  } catch (error) {
    setStatus(elements.authStatus, describeError(error), 'danger');
  } finally {
    elements.password.value = '';
    setBusy(elements.loginButton, false);
  }
}

function randomHex(byteCount = 16) {
  const bytes = new Uint8Array(byteCount);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < byteCount; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256);
    }
  }
  return [...bytes].map((value) => value.toString(16).padStart(2, '0')).join('');
}

function generateWalletChallenge() {
  const issuedAt = Math.floor(Date.now() / 1000);
  const address = elements.walletAddress.value.trim();
  const selectedServer = normalizeBaseUrl(elements.serverUrl.value) || '';
  const challenge = JSON.stringify({
    purpose: 'damagebdd-mobile-auth',
    version: 1,
    server: selectedServer,
    address,
    nonce: randomHex(),
    issued_at: issuedAt,
    expires_at: issuedAt + 300
  });

  elements.walletChallenge.value = challenge;
  session.set('walletChallenge', challenge);
  return challenge;
}

function challengeMatches(address, challenge) {
  try {
    const parsed = JSON.parse(challenge);
    return parsed?.purpose === 'damagebdd-mobile-auth'
      && parsed?.address === address
      && parsed?.server === serverUrl()
      && Number(parsed?.expires_at || 0) >= Math.floor(Date.now() / 1000);
  } catch {
    return false;
  }
}

async function connectSignedWallet(event) {
  event.preventDefault();
  saveServer();

  const address = elements.walletAddress.value.trim();
  const signature = elements.walletSignature.value.trim();
  let challenge = elements.walletChallenge.value;

  if (!address.startsWith('ak_')) {
    setStatus(elements.authStatus, 'Enter a valid AE account beginning with ak_.', 'danger');
    return;
  }
  if (!signature) {
    setStatus(elements.authStatus, 'Paste the signature returned by your wallet.', 'danger');
    return;
  }
  if (!challengeMatches(address, challenge)) {
    challenge = generateWalletChallenge();
    setStatus(elements.authStatus, 'The sign-in message was refreshed. Sign the new message and try again.', 'info');
    return;
  }

  setBusy(elements.walletConnectButton, true, 'Verifying…');
  setStatus(elements.authStatus, 'Verifying the signed message with DamageBDD…', 'info');

  try {
    const result = await authenticateWallet(
      serverUrl(),
      address,
      signature,
      challenge
    );

    setAuthenticated(result, 'wallet');
    elements.walletSignature.value = '';
    generateWalletChallenge();
    setStatus(elements.authStatus, `Wallet ${shortValue(state.address)} connected.`, 'success');
    navigate('home');
    await refreshBalances({ quiet: true });
  } catch (error) {
    setStatus(elements.authStatus, describeError(error), 'danger');
  } finally {
    setBusy(elements.walletConnectButton, false);
  }
}

function disconnectSession(message = 'Disconnected. Session credential removed.') {
  session.remove('token');
  session.remove('address');
  session.remove('authMethod');
  state = {
    ...state,
    token: '',
    address: '',
    authMethod: '',
    walletSnapshot: null,
    nwcSessions: []
  };
  elements.nwcUri.value = '';
  elements.nwcResult.hidden = true;
  elements.nwcSessions.replaceChildren();
  elements.nwcSummary.textContent = 'No session data loaded.';
  updateAuthUi();
  setStatus(elements.authStatus, message, 'info');
}

function logout() {
  disconnectSession();
  navigate('wallet');
}

async function copyText(value, sourceElement = null) {
  const text = String(value || '');
  if (!text) throw new Error('Nothing to copy.');

  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    if (!sourceElement) throw new Error('Clipboard access is unavailable.');
    sourceElement.focus();
    sourceElement.select?.();
    const copied = document.execCommand?.('copy');
    sourceElement.setSelectionRange?.(0, 0);
    if (!copied) throw new Error('Clipboard access is unavailable.');
  }
}

async function copyChallenge() {
  try {
    await copyText(elements.walletChallenge.value, elements.walletChallenge);
    setStatus(elements.authStatus, 'Message copied. Sign it in your AE wallet.', 'success');
  } catch (error) {
    setStatus(elements.authStatus, describeError(error), 'danger');
  }
}

async function pasteSignature() {
  try {
    elements.walletSignature.value = await navigator.clipboard.readText();
    setStatus(elements.authStatus, 'Signature pasted.', 'success');
  } catch {
    setStatus(elements.authStatus, 'Clipboard read is unavailable. Paste the signature manually.', 'info');
    elements.walletSignature.focus();
  }
}

async function copyAddress() {
  try {
    await copyText(state.address);
    setStatus(elements.authStatus, 'Account address copied.', 'success');
  } catch (error) {
    setStatus(elements.authStatus, describeError(error), 'danger');
  }
}

function createTextElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  element.textContent = text;
  return element;
}

function sessionBalanceText(item) {
  if (item.balance_sat !== undefined) return `${groupedInteger(item.balance_sat)} sats`;
  if (item.balance_msat !== undefined) return `${formatAtomic(item.balance_msat, 3, 3)} sats`;
  return 'Balance unavailable';
}

function renderNwcSessions(data) {
  const sessions = Array.isArray(data?.sessions) ? data.sessions : [];
  state.nwcSessions = sessions;
  elements.nwcSessions.replaceChildren();

  const totalMsat = data?.account_balance_msat;
  const totalText = totalMsat !== undefined
    ? `${formatAtomic(totalMsat, 3, 3)} sats total`
    : `${sessions.length} session${sessions.length === 1 ? '' : 's'}`;
  elements.nwcSummary.textContent = `${totalText} · ${sessions.length} connection${sessions.length === 1 ? '' : 's'}`;

  if (!sessions.length) {
    const empty = createTextElement('div', 'empty-state', 'No NWC connections were found. Create one to connect a compatible Lightning client.');
    elements.nwcSessions.append(empty);
    return;
  }

  sessions.forEach((item) => {
    const client = item.client_pubkey || item.client_pubkey_hash || '';
    const status = item.status || (item.revoked ? 'revoked' : 'active');
    const card = document.createElement('article');
    card.className = 'nwc-session';

    const header = document.createElement('div');
    header.className = 'nwc-session-head';
    const identity = document.createElement('div');
    identity.append(
      createTextElement('strong', '', client ? shortValue(client, 12, 8) : 'NWC session'),
      createTextElement('small', 'mono', client || 'Client key unavailable')
    );
    const statusPill = createTextElement('span', 'pill', String(status));
    statusPill.dataset.tone = status === 'revoked' ? 'danger' : 'success';
    header.append(identity, statusPill);

    const values = document.createElement('div');
    values.className = 'nwc-session-values';
    values.append(
      createTextElement('span', '', sessionBalanceText(item)),
      createTextElement(
        'span',
        '',
        item.remaining_sat !== undefined
          ? `${groupedInteger(item.remaining_sat)} sats remaining`
          : 'Allowance follows ledger policy'
      )
    );

    card.append(header, values);


    elements.nwcSessions.append(card);
  });
}

async function loadNwcSessions({ quiet = false } = {}) {
  if (!isSignedIn()) return;

  setBusy(elements.refreshNwcButton, true, 'Loading…');
  if (!quiet) setStatus(elements.nwcStatus, 'Loading NWC sessions…', 'info');

  try {
    const data = await getNwcSessions(serverUrl(), state.token);
    renderNwcSessions(data);
    if (!quiet) setStatus(elements.nwcStatus, 'NWC sessions refreshed.', 'success');
  } catch (error) {
    elements.nwcSummary.textContent = 'NWC session data is unavailable.';
    setStatus(elements.nwcStatus, describeError(error), 'danger');
  } finally {
    setBusy(elements.refreshNwcButton, false);
    updateAuthUi();
  }
}

function toggleNwcForm(show = elements.nwcForm.hidden) {
  elements.nwcForm.hidden = !show;
  elements.toggleNwcFormButton.textContent = show ? 'Close' : 'New connection';
  if (show) elements.maxSingleSat.focus();
}

function positiveInteger(input, label, { allowZero = false } = {}) {
  const value = Number.parseInt(input.value, 10);
  const valid = Number.isSafeInteger(value) && (allowZero ? value >= 0 : value > 0);
  if (!valid) throw new Error(`${label} must be ${allowZero ? 'zero or a positive' : 'a positive'} integer.`);
  return value;
}

async function createNwcConnection(event) {
  event.preventDefault();
  if (!isSignedIn()) return;

  let values;
  try {
    values = {
      maxSingleSat: positiveInteger(elements.maxSingleSat, 'Maximum payment'),
      maxTotalSat: positiveInteger(elements.maxTotalSat, 'Total allowance'),
      expiresHeight: positiveInteger(elements.expiresHeight, 'Expiry height', { allowZero: true })
    };
  } catch (error) {
    setStatus(elements.nwcStatus, describeError(error), 'danger');
    return;
  }

  setBusy(elements.createNwcButton, true, 'Creating…');
  setStatus(elements.nwcStatus, 'Creating a DamageBDD NWC connection…', 'info');

  try {
    const result = await mintNwcConnection(serverUrl(), state.token, values);
    if (!result?.usable || !result?.nwc_uri) {
      throw new Error(result?.error || 'The node did not return a usable NWC URI.');
    }

    elements.nwcUri.value = result.nwc_uri;
    elements.openNwcButton.href = result.nwc_uri;
    elements.nwcResult.hidden = false;
    toggleNwcForm(false);
    setStatus(elements.nwcStatus, 'NWC connection created. Store the URI securely.', 'success');
    await Promise.all([
      loadNwcSessions({ quiet: true }),
      refreshBalances({ quiet: true })
    ]);
  } catch (error) {
    const intents = error?.data?.intents;
    const suffix = Array.isArray(intents) && intents.length
      ? ' This node requires wallet-signed ledger setup before the connection becomes usable.'
      : '';
    setStatus(elements.nwcStatus, `${describeError(error)}${suffix}`, 'danger');
  } finally {
    setBusy(elements.createNwcButton, false);
  }
}

async function copyNwcUri() {
  try {
    await copyText(elements.nwcUri.value, elements.nwcUri);
    setStatus(elements.nwcStatus, 'NWC URI copied. Treat it like a password.', 'success');
  } catch (error) {
    setStatus(elements.nwcStatus, describeError(error), 'danger');
  }
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
  saveServer({ disconnectOnChange: true });
  setBusy(elements.checkNodeButton, true, 'Checking…');
  setPill(elements.nodePill, 'Checking', 'info');
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

async function runFeature() {
  if (!isSignedIn()) {
    setStatus(elements.runStatus, 'Connect before executing a feature.', 'danger');
    navigate('wallet');
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
    await refreshBalances({ quiet: true });
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

function bindNavigation() {
  document.querySelectorAll('[data-nav-target]').forEach((button) => {
    button.addEventListener('click', () => navigate(button.dataset.navTarget));
  });
  window.addEventListener('hashchange', () => activateView(viewFromHash()));
}

function bindEvents() {
  bindNavigation();

  elements.serverUrl.addEventListener('change', () => {
    try {
      saveServer({ disconnectOnChange: true });
      generateWalletChallenge();
    } catch (error) {
      setStatus(elements.nodeStatus, describeError(error), 'danger');
    }
  });
  elements.checkNodeButton.addEventListener('click', checkNode);
  elements.refreshBalancesButton.addEventListener('click', () => refreshBalances());
  elements.walletRefreshButton.addEventListener('click', () => refreshBalances());

  elements.emailTab.addEventListener('click', () => selectConnectMethod('email'));
  elements.walletTab.addEventListener('click', () => selectConnectMethod('wallet'));
  elements.loginForm.addEventListener('submit', login);
  elements.walletConnectForm.addEventListener('submit', connectSignedWallet);
  elements.regenerateChallengeButton.addEventListener('click', generateWalletChallenge);
  elements.copyChallengeButton.addEventListener('click', copyChallenge);
  elements.pasteSignatureButton.addEventListener('click', pasteSignature);
  elements.walletAddress.addEventListener('change', generateWalletChallenge);
  elements.copyAddressButton.addEventListener('click', copyAddress);
  elements.logoutButton.addEventListener('click', logout);

  elements.toggleNwcFormButton.addEventListener('click', () => toggleNwcForm());
  elements.cancelNwcButton.addEventListener('click', () => toggleNwcForm(false));
  elements.nwcForm.addEventListener('submit', createNwcConnection);
  elements.copyNwcButton.addEventListener('click', copyNwcUri);
  elements.refreshNwcButton.addEventListener('click', () => loadNwcSessions());
  elements.executeButton.addEventListener('click', runFeature);
  elements.resetFeatureButton.addEventListener('click', resetFeature);
  elements.featureText.addEventListener('input', () => {
    preferences.set('featureDraft', elements.featureText.value);
  });
}

function initialise() {
  elements.serverUrl.value = preferences.get(
    'serverUrl',
    'https://run.dev.damagebdd.com'
  );
  elements.featureText.value = preferences.get('featureDraft', SAMPLE_FEATURE);
  elements.walletChallenge.value = session.get('walletChallenge', '');

  bindEvents();
  updateAuthUi();
  generateWalletChallenge();
  navigate(viewFromHash(), { replace: !window.location.hash });

  if (isSignedIn()) void refreshBalances({ quiet: true });
}

initialise();
