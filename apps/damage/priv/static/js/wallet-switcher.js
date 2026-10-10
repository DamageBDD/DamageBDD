import {normaliseSession, errorMessage} from './auth-model.js';

// Browser credentials stay in memory and the HttpOnly session cookie. Never in localStorage.
let session = null;
let expiryTimer;
let refreshing;
const obsoleteKeys = ['access_token', 'access_token_custodial', 'access_token_extension',
  'active_auth_mode', 'custodial_address', 'extension_address', 'damage_email',
  'custodial_token', 'extension_token', 'custodial_accounts', 'damage.nwc.last'];
try { for (const key of obsoleteKeys) localStorage.removeItem(key); } catch (_) {}
const active = () => session && session.expires_at > Date.now() / 1000 ? session : null;
export const TokenManager = {
  getMode: () => active()?.mode === 'wallet' ? 'extension' : 'custodial',
  getAddress: () => active()?.address || null,
  getEmail: () => active()?.email || null,
  getToken: () => active()?.access_token || '',
  isAuthenticated: () => !!active(),
  capabilities: () => active()?.capabilities || {},
  can: name => active()?.capabilities?.[name] === true,
  session: () => active(),
  acceptSession(data) {
    session = normaliseSession(data);
    clearTimeout(expiryTimer);
    expiryTimer = setTimeout(() => { this.logout(); window.DamageAuth?.open('login'); },
      Math.min(2147483647, Math.max(0, session.expires_at * 1000 - Date.now())));
    publish();
    return session;
  },
  logout() { session = null; clearTimeout(expiryTimer); publish(); },
  activate(mode) {
    if (mode !== this.getMode()) throw new Error('Sign in to switch accounts. Accounts are not linked automatically.');
    return this.getToken();
  },
  refreshSession() {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const response = await fetch('/accounts/session', {credentials: 'include', cache: 'no-store', mode: 'same-origin', redirect: 'error',
        headers: {'Accept': 'application/json', 'X-Damage-Auth': '1'}});
      if (response.status === 401) { this.logout(); return null; }
      const body = await response.json();
      if (!response.ok) throw new Error(errorMessage(body, response.status));
      return this.acceptSession(body);
    })().finally(() => { refreshing = null; });
    return refreshing;
  }
};
window.TokenManager = TokenManager;
function publish() {
  if (typeof document === 'undefined') return;
  applyCapabilities();
  document.dispatchEvent(new CustomEvent('auth:changed', {detail: {
    mode: TokenManager.getMode(), address: TokenManager.getAddress(), authenticated: !!active()
  }})); // Never broadcast bearer tokens.
}
function applyCapabilities() {
  const s = active();
  document.body.dataset.sessionMode = s?.mode || 'anonymous';
  for (const el of document.querySelectorAll('[data-session-kind]'))
    el.textContent = s?.mode === 'wallet' ? 'Wallet-authenticated · restricted' : s ? 'Managed · email sign-in' : 'Not signed in';
  for (const el of document.querySelectorAll('[data-session-address]')) el.textContent = s?.address || '—';
  for (const el of document.querySelectorAll('[data-wallet-only-note]')) {
    el.hidden = s?.mode !== 'wallet';
    el.textContent = s?.capabilities?.reason || '';
  }
  for (const el of document.querySelectorAll('[data-requires-capability]')) {
    const allowed = TokenManager.can(el.dataset.requiresCapability);
    if ('disabled' in el) el.disabled = !allowed;
    el.setAttribute('aria-disabled', String(!allowed));
    el.title = allowed ? '' : (s?.capabilities?.reason || 'Sign in to use this operation.');
  }
}
window.applyWalletCapabilities = applyCapabilities;

export async function logoutActiveSession() {
  // No silent fallback to a saved email/wallet identity.
  const response = await fetch('/accounts/session/logout', {method: 'POST', credentials: 'include', mode: 'same-origin', redirect: 'error',
    headers: {'X-Damage-Auth': '1', 'Content-Type': 'application/json', 'Accept': 'application/json'}, body: '{}'});
  if (!response.ok) throw new Error('Sign-out could not be confirmed. Retry before leaving a shared device.');
  TokenManager.logout();
  channel?.postMessage({type: 'changed'});
}
window.logoutActiveSession = logoutActiveSession;
let channel;
try {
  channel = new BroadcastChannel('damage-browser-session');
  channel.onmessage = () => { TokenManager.logout(); location.reload(); };
} catch (_) {}
window.notifyDamageSessionChange = () => channel?.postMessage({type: 'changed'});

export async function updateWalletSummary() {
  const account = TokenManager.getAddress();
  for (const id of ['balanceAddress', 'damage-address']) {
    const el = document.getElementById(id);
    if (el) { if ('value' in el) el.value = account || ''; else el.textContent = account || '—'; }
  }
  if (!account) return;
  const response = await fetch('/accounts/balance', {credentials: 'include', cache: 'no-store', mode: 'same-origin', redirect: 'error',
    headers: {Accept: 'application/json'}});
  if (!response.ok) return;
  const body = await response.json();
  if (account !== TokenManager.getAddress()) return; // Discard stale account responses.
  const put = (id, value) => { const el = document.getElementById(id); if (el) el.textContent = value ?? '—'; };
  put('balanceAmount', body.damage_display);
  put('aeBalance', body.ae_display);
  put('satsBalance', body.sats_available === false ? 'Unavailable' : body.sats);
}
window.updateWalletSummary = updateWalletSummary;
window.refreshAfterAuthChange = async () => { await updateWalletSummary(); document.dispatchEvent(new Event('balance:refresh')); };
function bind() {
  // Capture submit/click events as well as disabling visible buttons. Backend
  // authorization is still authoritative; this only avoids misleading UI work.
  const guard = event => {
    const el = event.target.closest?.('[data-requires-capability]');
    if (el && !TokenManager.can(el.dataset.requiresCapability)) {
      event.preventDefault(); event.stopImmediatePropagation();
    }
  };
  document.addEventListener('submit', guard, true);
  document.addEventListener('click', guard, true);
  const selector = document.getElementById('walletSelector');
  if (selector) selector.hidden = true;
  document.getElementById('balanceRefreshBtn')?.addEventListener('click', async event => {
    const button = event.currentTarget;
    if (button.getAttribute('aria-busy') === 'true') return;
    button.setAttribute('aria-busy', 'true');
    try { await updateWalletSummary(); } finally { button.removeAttribute('aria-busy'); }
  });
  applyCapabilities();
}
TokenManager.ready = TokenManager.refreshSession().catch(() => { TokenManager.logout(); return null; });
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind, {once: true}); else bind();
