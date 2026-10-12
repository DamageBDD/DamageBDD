// Integrated DamageBDD wallet workspace.
// Presentation lives here; wallet/auth modules remain responsible for credentials and signing.
let walletSnapshot = null;
let sessionsSnapshot = null;
let pendingTransfer = null;

const $ = id => document.getElementById(id);
const token = () => window.TokenManager?.getToken?.() || '';
const can = name => window.TokenManager?.can?.(name) === true;

function authHeaders() {
  const headers = new Headers({'Accept': 'application/json', 'Content-Type': 'application/json'});
  if (token()) headers.set('Authorization', `Bearer ${token()}`);
  return headers;
}

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, {
    credentials: 'include',
    cache: 'no-store',
    mode: 'same-origin',
    redirect: 'error',
    ...options,
    headers: options.headers || authHeaders()
  });
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : {}; } catch (_) { body = {message: text}; }
  if (!response.ok) {
    const error = new Error(body?.message || body?.reason || body?.error || `HTTP ${response.status}`);
    error.status = response.status;
    error.payload = body;
    throw error;
  }
  return body || {};
}

function displayAtomic(balance) {
  if (!balance || balance.available === false) return 'Unavailable';
  const raw = String(balance.amount ?? '0');
  const decimals = Number(balance.decimals || 0);
  if (!/^\d+$/.test(raw)) return raw;
  if (!decimals) return BigInt(raw).toLocaleString();
  const padded = raw.padStart(decimals + 1, '0');
  const whole = padded.slice(0, -decimals);
  const fraction = padded.slice(-decimals).replace(/0+$/, '').slice(0, 6);
  const wholeFormatted = BigInt(whole || '0').toLocaleString();
  return fraction ? `${wholeFormatted}.${fraction}` : wholeFormatted;
}

function setBalance(name, value) {
  document.querySelectorAll(`[data-wallet-balance="${name}"]`).forEach(el => {
    el.textContent = value;
    el.classList.remove('is-updating');
    // Re-trigger the small value reveal without changing number formatting.
    void el.offsetWidth;
    el.classList.add('is-updating');
  });
}

function prefersReducedMotion() {
  return window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches === true;
}

function formatSats(value, signed = false) {
  const number = Math.round(Number(value || 0));
  const prefix = signed && number > 0 ? '+' : '';
  return `${prefix}${number.toLocaleString()}`;
}

function animateInteger(el, target, {signed = false, duration = 620} = {}) {
  if (!el) return;
  const end = Math.round(Number(target || 0));
  if (!Number.isFinite(end) || prefersReducedMotion()) {
    el.textContent = formatSats(end, signed);
    return;
  }
  const startTime = performance.now();
  const start = Number(el.dataset.flowValue || 0);
  el.dataset.flowValue = String(end);
  const ease = t => 1 - Math.pow(1 - t, 3);
  const frame = now => {
    const progress = Math.min(1, (now - startTime) / duration);
    const current = start + (end - start) * ease(progress);
    el.textContent = formatSats(current, signed);
    if (progress < 1) requestAnimationFrame(frame);
    else el.textContent = formatSats(end, signed);
  };
  requestAnimationFrame(frame);
}

function flowEvents(sessions) {
  return sessions.flatMap(session => Array.isArray(session.events) ? session.events : [])
    .filter(event => {
      const kind = String(event.type || event.kind || '').toLowerCase();
      const eventKind = Number(event.event_kind);
      return kind === 'credit' || kind === 'debit' || eventKind === 0 || eventKind === 1;
    });
}

function renderFlowStats(sessions) {
  const events = flowEvents(sessions);
  let incomingMsat = 0;
  let outgoingMsat = 0;
  for (const event of events) {
    const amount = Math.abs(Number(event.amount_msat || 0));
    if (!Number.isFinite(amount) || amount <= 0) continue;
    const kind = String(event.type || event.kind || '').toLowerCase();
    const eventKind = Number(event.event_kind);
    if (kind === 'credit' || eventKind === 0) incomingMsat += amount;
    else if (kind === 'debit' || eventKind === 1) outgoingMsat += amount;
  }
  const incoming = incomingMsat / 1000;
  const outgoing = outgoingMsat / 1000;
  const net = incoming - outgoing;
  animateInteger(document.querySelector('[data-flow-stat="in"]'), incoming);
  animateInteger(document.querySelector('[data-flow-stat="out"]'), outgoing);
  animateInteger(document.querySelector('[data-flow-stat="net"]'), net, {signed:true});
  animateInteger(document.querySelector('[data-flow-stat="count"]'), events.length);

  const max = Math.max(incoming, outgoing, 1);
  const inBar = document.querySelector('[data-flow-bar="in"]');
  const outBar = document.querySelector('[data-flow-bar="out"]');
  if (inBar) inBar.style.width = `${Math.max(incoming > 0 ? 8 : 0, (incoming / max) * 100)}%`;
  if (outBar) outBar.style.width = `${Math.max(outgoing > 0 ? 8 : 0, (outgoing / max) * 100)}%`;
}

function renderWalletSnapshot(snapshot) {
  walletSnapshot = snapshot;
  const balances = snapshot?.balances || {};
  setBalance('damage', displayAtomic(balances.damage));
  setBalance('ae', displayAtomic(balances.ae));
  const sats = balances.lightning?.amount_sat ?? (balances.lightning?.available ? '0' : null);
  setBalance('sats', sats == null ? 'Unavailable' : Number(sats).toLocaleString());
  const summary = $('wallet-nwc-summary');
  if (summary) {
    const count = Number(balances.lightning?.session_count || 0);
    summary.textContent = balances.lightning?.available === false
      ? 'NWC ledger unavailable'
      : `${count} NWC connection${count === 1 ? '' : 's'}`;
  }
}

function renderQr() {
  const mount = $('qrcode-damage');
  const address = window.TokenManager?.getAddress?.();
  if (!mount || !address || typeof window.QRCode === 'undefined') return;
  mount.replaceChildren();
  // eslint-disable-next-line no-undef
  new QRCode(mount, {text: address, width: 160, height: 160, correctLevel: QRCode.CorrectLevel.M});
}

function short(value, start = 10, end = 8) {
  value = String(value || '');
  return value.length > start + end + 2 ? `${value.slice(0, start)}…${value.slice(-end)}` : value;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}

function sessionStatus(session) {
  if (session?.status) return String(session.status);
  return session?.revoked ? 'revoked' : 'active';
}

function renderSessions(payload) {
  sessionsSnapshot = payload;
  const target = $('wallet-connections');
  const activity = $('wallet-recent-activity');
  if (!target || !activity) return;
  const sessions = Array.isArray(payload?.sessions) ? payload.sessions : [];
  if (!sessions.length) {
    target.innerHTML = '<p class="wallet-empty-state">No managed NWC connections yet. Connect a wallet when you need Lightning payment permissions.</p>';
    activity.innerHTML = '<p class="wallet-empty-state">No Lightning ledger activity yet.</p>';
    renderFlowStats([]);
    return;
  }
  target.innerHTML = sessions.slice(0, 8).map(session => {
    const key = session.client_pubkey || session.client_pubkey_hash || '';
    const balance = Number(session.balance_msat || 0) / 1000;
    const status = sessionStatus(session);
    return `<div class="wallet-connection-row"><div><strong>${escapeHtml(short(key) || 'NWC connection')}</strong><small>${balance.toLocaleString(undefined,{maximumFractionDigits:3})} sats · last used ${escapeHtml(formatTime(session.last_used_at))}</small></div><span class="wallet-connection-badge">${escapeHtml(status)}</span></div>`;
  }).join('');

  renderFlowStats(sessions);

  const events = sessions.flatMap(session => Array.isArray(session.events) ? session.events : [])
    .sort((a,b) => Number(b.block_time || b.at || 0) - Number(a.block_time || a.at || 0))
    .slice(0, 8);
  activity.innerHTML = events.length ? events.map(event => {
    const kind = String(event.type || event.kind || 'event');
    const amountMsat = Number(event.amount_msat || 0);
    const amount = amountMsat ? `${Math.abs(amountMsat / 1000).toLocaleString(undefined,{maximumFractionDigits:3})} sats` : 'Policy update';
    const incoming = kind === 'credit' || Number(event.event_kind) === 0;
    return `<div class="wallet-activity-row"><div><strong>${incoming ? '↓' : '↑'} ${escapeHtml(kind.replaceAll('_',' '))}</strong><small>${escapeHtml(formatTime(event.block_time || event.at))} · ${escapeHtml(short(event.ref || event.tx_hash || '', 8, 6))}</small></div><span>${incoming ? '+' : (amountMsat ? '−' : '')}${escapeHtml(amount)}</span></div>`;
  }).join('') : '<p class="wallet-empty-state">No Lightning ledger activity yet.</p>';
}

function formatTime(unix) {
  const value = Number(unix || 0);
  if (!value) return 'not used yet';
  try { return new Date(value * 1000).toLocaleString(); } catch (_) { return 'unknown time'; }
}

async function refreshWallet() {
  if (!window.TokenManager?.isAuthenticated?.()) return;
  const refresh = $('wallet-page-refresh');
  refresh?.setAttribute('aria-busy', 'true');
  refresh && (refresh.disabled = true);
  try {
    const snapshot = await jsonRequest('/accounts/wallet', {method: 'GET', headers: new Headers({'Accept':'application/json'})});
    renderWalletSnapshot(snapshot);
    await window.updateWalletSummary?.();
    renderQr();
    if (can('nwc')) {
      try { renderSessions(await jsonRequest('/api/nwc/sessions', {method:'POST', body: JSON.stringify({limit: 200})})); }
      catch (error) { renderSessions({sessions: []}); const summary=$('wallet-nwc-summary'); if(summary) summary.textContent='NWC activity unavailable'; }
    } else {
      renderSessions({sessions: []});
      const summary = $('wallet-nwc-summary');
      if (summary) summary.textContent = 'Managed account required for NWC';
    }
  } finally {
    refresh?.removeAttribute('aria-busy');
    if (refresh) refresh.disabled = false;
  }
}

function decimalToAtomic(value, decimals) {
  const text = String(value || '').trim();
  if (!/^\d+(?:\.\d+)?$/.test(text)) throw new Error('Enter a valid positive DAMAGE amount.');
  const [whole, fraction = ''] = text.split('.');
  if (fraction.length > decimals) throw new Error(`DAMAGE supports at most ${decimals} decimal places.`);
  const atomic = BigInt(whole) * (10n ** BigInt(decimals)) + BigInt((fraction + '0'.repeat(decimals)).slice(0, decimals) || '0');
  if (atomic <= 0n) throw new Error('Amount must be greater than zero.');
  return atomic.toString();
}

function reviewTransfer(event) {
  event.preventDefault();
  const status = $('wallet-transfer-status');
  try {
    if (!can('transfer')) throw new Error(window.TokenManager?.capabilities?.().reason || 'This session cannot transfer DAMAGE.');
    const recipient = $('damage-transfer-out-address')?.value.trim() || '';
    const amountDisplay = $('damage-transfer-out-amount')?.value.trim() || '';
    if (!/^ak_[1-9A-HJ-NP-Za-km-z]+$/.test(recipient)) throw new Error('Enter a valid Aeternity account address beginning with ak_.');
    const decimals = Number(walletSnapshot?.balances?.damage?.decimals ?? 0);
    const amountAtomic = decimalToAtomic(amountDisplay, decimals);
    pendingTransfer = {recipient, amountDisplay, amountAtomic};
    $('wallet-review-recipient').textContent = recipient;
    $('wallet-review-amount').textContent = `${amountDisplay} DAMAGE`;
    const reviewStatus = $('wallet-review-status'); if (reviewStatus) { reviewStatus.textContent = ''; reviewStatus.className = 'modal__status'; }
    if (status) status.textContent = '';
    window.MicroModal?.show('wallet-transfer-review-modal');
  } catch (error) {
    if (status) status.textContent = error.message;
  }
}

async function confirmTransfer() {
  if (!pendingTransfer) return;
  const button = $('wallet-confirm-transfer');
  const status = $('wallet-review-status');
  button.disabled = true;
  button.textContent = 'Sending…';
  if (status) { status.textContent = 'Submitting transfer…'; status.className = 'modal__status'; }
  try {
    const result = await jsonRequest('/accounts/transfer', {method:'POST', body: JSON.stringify({to: pendingTransfer.recipient, amount: pendingTransfer.amountAtomic})});
    if (status) { status.textContent = result.tx_hash ? `Transfer submitted: ${short(result.tx_hash, 12, 8)}` : 'Transfer submitted.'; status.className = 'modal__status is-success'; }
    $('transfer-out-form')?.reset();
    pendingTransfer = null;
    await refreshWallet();
    setTimeout(() => window.MicroModal?.close('wallet-transfer-review-modal'), 700);
  } catch (error) {
    if (status) { status.textContent = error.message; status.className = 'modal__status is-error'; }
  } finally {
    button.disabled = false;
    button.textContent = 'Send DAMAGE';
  }
}

function copyAddress() {
  const address = window.TokenManager?.getAddress?.();
  if (!address) return;
  navigator.clipboard?.writeText(address).catch(() => {});
}

function bind() {
  $('wallet-page-refresh')?.addEventListener('click', () => refreshWallet().catch(console.warn));
  $('transfer-out-form')?.addEventListener('submit', reviewTransfer);
  $('wallet-confirm-transfer')?.addEventListener('click', () => confirmTransfer().catch(console.warn));
  $('wallet-manage-nwc')?.addEventListener('click', () => $('open-nwc-modal-btn')?.click());
  document.querySelectorAll('[data-copy-wallet-address]').forEach(button => button.addEventListener('click', copyAddress));
  document.addEventListener('damage:panelchange', event => {
    if (event.detail?.id === 'wallet-tab') refreshWallet().catch(error => console.warn('wallet refresh failed', error));
  });
  document.addEventListener('auth:changed', () => {
    renderQr();
    if (window.dashboardNavigation?.activePanel === 'wallet-tab') refreshWallet().catch(() => {});
  });
  if (window.location.hash === '#wallet-tab') refreshWallet().catch(() => {});
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind, {once:true});
else bind();
