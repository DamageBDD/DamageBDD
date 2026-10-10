import {TokenManager} from './wallet-switcher.js';
import {authWallet} from './auth-wallet-loader.js';
import {errorMessage, nonce, signatureHex, walletDeepLink, parseCallback} from './auth-model.js';

const PENDING = 'damage_wallet_signin_pending_v1';
let callback, callbackError;
// Consume and scrub the fragment before boot. Never accept an arbitrary callback address as a session.
if (location.hash.startsWith('#wallet-callback?')) {
  try {
    const saved = JSON.parse(sessionStorage.getItem(PENDING) || 'null');
    callback = parseCallback(location.hash, saved);
  } catch (error) { callbackError = error.message; }
  try { sessionStorage.removeItem(PENDING); } catch (_) {}
  history.replaceState(null, '', location.pathname);
}

export function initAuthUI({request = fetch, browserConnect = authWallet.connect,
  browserSign = authWallet.sign, navigate = url => location.assign(url),
  reload = () => location.reload()} = {}) {
  const root = document.getElementById('login-modal');
  if (!root || root.dataset.authBound) return;
  root.dataset.authBound = 'true';
  const $ = id => document.getElementById(id);
  let busy = false, epoch = 0, challenge = null, provider = 'browser', options;
  let aborter;
  const status = (message, kind = 'info') => {
    $('connect-status').textContent = message;
    $('connect-status').dataset.kind = kind;
  };
  function pending(value, message) {
    busy = value;
    root.setAttribute('aria-busy', String(value));
    for (const el of root.querySelectorAll('[data-auth-action], [data-auth-mode], [data-auth-jump]')) el.disabled = value;
    $('auth-cancel').hidden = !value;
    if (message) status(message);
  }
  function resetChallenge() {
    challenge = null;
    $('wallet-proof').hidden = true;
    $('wallet-proof-message').textContent = '';
    $('wallet-sign-in').disabled = true;
  }
  function open(mode = 'login') {
    if (busy) return;
    epoch++;
    resetChallenge();
    for (const el of root.querySelectorAll('[data-auth-panel]')) el.hidden = el.dataset.authPanel !== mode;
    for (const el of root.querySelectorAll('[data-auth-mode]')) {
      const selected = el.dataset.authMode === mode || (mode === 'recovery' && el.dataset.authMode === 'login');
      el.setAttribute('aria-selected', String(selected));
      el.tabIndex = selected ? 0 : -1;
    }
    $('auth-modal-title').textContent = {login: 'Welcome back', signup: 'Create your workspace',
      wallet: 'Sign in with your wallet', recovery: 'Reset your password'}[mode];
    status('');
    $('auth-keep-session').hidden = !TokenManager.isAuthenticated();
    window.MicroModal?.show('login-modal', {disableFocus: true});
    root.querySelector(`[data-auth-panel="${mode}"] input, [data-auth-panel="${mode}"] button`)?.focus();
  }
  async function api(path, body, signal) {
    const response = await request(path, {method: body === undefined ? 'GET' : 'POST', credentials: 'include',
      cache: 'no-store', mode: 'same-origin', redirect: 'error', referrerPolicy: 'no-referrer', signal, headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'X-Damage-Auth': '1'},
      ...(body === undefined ? {} : {body: JSON.stringify(body)})});
    let data;
    try { data = await response.json(); } catch (_) { throw new Error('The server returned an unreadable response. Please retry.'); }
    if (!response.ok) throw new Error(errorMessage(data, response.status));
    return data;
  }
  async function config(signal) {
    options ||= await api('/accounts/auth/options', undefined, signal);
    if (options.origin !== location.origin) throw new Error('Open the configured DamageBDD origin before signing in.');
    return options;
  }
  async function run(message, fn, {cancellable = false} = {}) {
    if (busy) return;
    const ticket = ++epoch;
    const controller = new AbortController();
    aborter = controller;
    pending(true, message);
    $('auth-cancel').hidden = !cancellable;
    const timeout = setTimeout(() => controller.abort(), 90000);
    try { await fn(controller.signal, () => ticket === epoch && !controller.signal.aborted); }
    catch (error) {
      if (ticket === epoch) status(error.name === 'AbortError'
        ? 'The request timed out. Its outcome may be unknown; check your session before trying again.'
        : error.message || 'Unable to complete sign-in.', 'error');
    } finally {
      clearTimeout(timeout);
      if (ticket === epoch) { pending(false); aborter = null; if (!challenge) $('wallet-sign-in').disabled = true; }
    }
  }
  function complete(data, current) {
    if (!current()) return;
    TokenManager.acceptSession(data);
    // Sign-up never links a wallet. A new login explicitly replaces the session.
    $('password').value = '';
    window.notifyDamageSessionChange?.();
    status('Signed in. Opening your workspace…', 'success');
    reload(); // SSR rebuilds account/role-specific panels; do not reveal stale markup.
  }
  async function createChallenge(account, signal, current) {
    const conf = await config(signal);
    if (account.networkId && account.networkId !== conf.network_id)
      throw new Error(`Select ${conf.network_id} in your wallet, then connect again.`);
    const proof = await api('/accounts/wallet/challenge', {address: account.address}, signal);
    if (!current()) return;
    if (proof.address !== account.address || typeof proof.message !== 'string' ||
        typeof proof.challenge_id !== 'string' || proof.network_id !== conf.network_id ||
        !Number.isSafeInteger(proof.expires_at) || proof.expires_at <= Date.now() / 1000)
      throw new Error('The sign-in challenge is invalid or expired. Connect again.');
    challenge = proof;
    $('wallet-proof-address').textContent = proof.address;
    $('wallet-proof-network').textContent = proof.network_id;
    $('wallet-proof-message').textContent = proof.message;
    $('wallet-proof').hidden = false;
    $('wallet-sign-in').disabled = false;
    status('Connected, not signed in. Review the message before signing.', 'info');
  }
  function saveRedirect(phase) {
    const state = nonce();
    sessionStorage.setItem(PENDING, JSON.stringify({state, phase, createdAt: Date.now(), challenge}));
    navigate(walletDeepLink(phase, location.origin, state, challenge?.message));
  }

  $('loginSignupForm').addEventListener('submit', event => {
    event.preventDefault();
    if (!event.currentTarget.reportValidity()) return;
    run('Signing in…', async (signal, current) => {
      const data = await api('/accounts/login', {username: $('login-username').value.trim(), password: $('password').value}, signal);
      complete(data, current);
    });
  });
  $('signupForm').addEventListener('submit', event => {
    event.preventDefault();
    if (!event.currentTarget.reportValidity()) return;
    run('Sending your confirmation link…', async (signal, current) => {
      const data = await api('/accounts/signup', {email: $('signup-username').value.trim()}, signal);
      if (current()) {
        $('signup-confirmation').hidden = false;
        $('signup-confirmation-email').textContent = $('signup-username').value.trim();
        status(data.message || 'Check your inbox, including spam, for the confirmation link.', 'success');
      }
    });
  });
  $('recoveryForm').addEventListener('submit', event => {
    event.preventDefault();
    if (!event.currentTarget.reportValidity()) return;
    run('Requesting a reset link…', async (signal, current) => {
      const data = await api('/accounts/recovery', {email: $('recovery-email').value.trim()}, signal);
      if (current()) status(data.message || 'Check your inbox for the next step.', 'success');
    });
  });
  $('connect-button').addEventListener('click', () => run('Waiting for your browser wallet…', async (signal, current) => {
    provider = 'browser'; resetChallenge();
    const account = await browserConnect({signal});
    if (current()) await createChallenge(account, signal, current);
  }, {cancellable: true}));
  $('connect-mobile-wallet').addEventListener('click', () => run('Opening Superhero Wallet…', async (signal, current) => {
    provider = 'mobile'; resetChallenge(); await config(signal);
    if (current()) saveRedirect('connect');
  }, {cancellable: true}));
  $('wallet-sign-in').addEventListener('click', () => run('Waiting for your sign-in signature…', async (signal, current) => {
    if (!challenge || challenge.expires_at <= Date.now() / 1000) { resetChallenge(); throw new Error('This request expired. Connect again.'); }
    if (provider === 'mobile') { saveRedirect('sign'); return; }
    const proof = challenge;
    const signed = await browserSign(proof.message, proof.address, {signal});
    if (!current()) return;
    // Once verification is sent it is not safe to promise cancellation of server-side login.
    $('auth-cancel').hidden = true;
    status('Verifying wallet ownership…');
    resetChallenge();
    const data = await api('/accounts/wallet/verify', {challenge_id: proof.challenge_id, signature: signatureHex(signed)}, signal);
    resetChallenge(); complete(data, current);
  }, {cancellable: true}));
  $('auth-keep-session').addEventListener('click', () => {
    if (busy) return;
    epoch++; resetChallenge(); window.MicroModal?.close('login-modal');
  });
  $('auth-cancel').addEventListener('click', () => {
    epoch++; aborter?.abort(); aborter = null; resetChallenge(); pending(false);
    status('Wallet sign-in cancelled. No transaction was requested.');
  });
  $('wallet-change-account').addEventListener('click', () => { resetChallenge(); status('Connect the account you want to use.'); });
  root.querySelectorAll('[data-auth-mode], [data-auth-jump]').forEach(button => button.addEventListener('click', () => {
    const mode = button.dataset.authMode || button.dataset.authJump;
    if (mode === 'recovery') $('recovery-email').value = $('login-username').value;
    open(mode);
  }));
  root.querySelector('[role="tablist"]').addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key) || busy) return;
    const tabs = [...root.querySelectorAll('[data-auth-mode]')];
    const at = tabs.indexOf(document.activeElement);
    if (at < 0) return;
    event.preventDefault();
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 :
      (at + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
    open(tabs[next].dataset.authMode); tabs[next].focus();
  });
  $('auth-show-password').addEventListener('click', event => {
    const show = $('password').type === 'password';
    $('password').type = show ? 'text' : 'password';
    event.currentTarget.textContent = show ? 'Hide' : 'Show';
    event.currentTarget.setAttribute('aria-pressed', String(show));
    event.currentTarget.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
  });
  document.querySelectorAll('[data-switch-account]').forEach(button => button.addEventListener('click', () => open('wallet')));
  document.querySelectorAll('[data-disconnect-wallet]').forEach(button => button.addEventListener('click', () => run('Signing out…', async () => {
    const feedback = document.querySelector('[data-session-feedback]');
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
    if (feedback) feedback.textContent = 'Confirming sign-out…';
    try {
      await window.logoutActiveSession();
      if (feedback) feedback.textContent = 'Signed out.';
      reload();
    } catch (error) {
      // The auth dialog is normally closed here; show the failure in the wallet
      // panel as well rather than silently retaining a session on a shared device.
      if (feedback) feedback.textContent = error.message;
      throw error;
    } finally {
      button.disabled = false;
      button.removeAttribute('aria-busy');
    }
  })));
  window.DamageAuth = {open, api, status};
  TokenManager.ready.then(async () => {
    if (callbackError) { open('wallet'); status(callbackError, 'error'); }
    else if (callback?.cancelled) { open('wallet'); status('You cancelled in the wallet. No transaction was requested.'); }
    else if (callback?.signature) {
      provider = 'mobile'; open('wallet');
      run('Verifying your wallet signature…', async (signal, current) => {
        const data = await api('/accounts/wallet/verify', {challenge_id: callback.challenge.challenge_id,
          signature: callback.signature}, signal);
        complete(data, current);
      });
    } else if (callback?.address) {
      provider = 'mobile'; open('wallet');
      run('Preparing a sign-in message…', (signal, current) => createChallenge(callback, signal, current));
    } else if (!TokenManager.isAuthenticated()) open('login');
    else window.applyWalletCapabilities?.();
  });
  return window.DamageAuth;
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => initAuthUI(), {once: true});
else initAuthUI();
