// balances.js
(function (g) {
  'use strict';

  const DEFAULTS = {
    apiBase: '',
    timeoutMs: 10000,
    credentials: 'include',
    preserveAddressText: false,
    autoFetch: true
  };

  const AE_DECIMALS = 18;
  const DAMAGE_DECIMALS = 8;
  const MSATS_DECIMALS = 3;

  async function fetchT(url, init = {}, timeoutMs = DEFAULTS.timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);

    try {
      const r = await fetch(url, { ...init, signal: ctrl.signal });
      if (!r.ok) {
        throw new Error(`${url} → ${r.status} ${r.statusText}`);
      }
      return r;
    } finally {
      clearTimeout(t);
    }
  }

  function formatUnitsString(value, decimals) {
    if (value == null) return '0';

    const neg = String(value)[0] === '-';
    let s = neg ? String(value).slice(1) : String(value);

    if (!/^\d+$/.test(s)) {
      s = String(s || '0').replace(/\D/g, '') || '0';
    }

    const d = Math.max(0, Number(decimals || 0));
    if (d === 0) return (neg ? '-' : '') + s;

    if (s.length <= d) {
      s = '0'.repeat(d - s.length + 1) + s;
    }

    const i = s.slice(0, s.length - d);
    let f = s.slice(s.length - d).replace(/0+$/, '');

    return (neg ? '-' : '') + (f ? `${i}.${f}` : i);
  }

  function toIntegerString(x) {
    if (typeof x === 'bigint') return x.toString(10);
    if (typeof x === 'number') return BigInt(Math.trunc(x)).toString(10);
    if (typeof x === 'string') return x;
    if (x == null) return '0';
    return String(x);
  }

  function displayValue(rawValue, displayValue, decimals) {
    if (displayValue !== undefined && displayValue !== null && displayValue !== '') {
      return String(displayValue);
    }
    return formatUnitsString(toIntegerString(rawValue), decimals);
  }

  function normalizeError(err) {
    if (!err) return { type: 'unknown', message: 'Unknown error' };
    if (typeof err === 'string') return { type: 'string-error', message: err };
    if (err.name === 'AbortError') return { type: 'timeout', message: 'Request timed out' };

    return {
      type: err.type || 'exception',
      message: err.message || String(err),
      stack: err.stack
    };
  }

  const safe = (fn) => async (...args) => {
    try {
      return { ok: true, value: await fn(...args) };
    } catch (err) {
      return { ok: false, error: normalizeError(err) };
    }
  };

  function compactAddress(addr) {
    if (!addr) return 'ak_...';
    return addr.length > 18 ? `${addr.slice(0, 8)}...${addr.slice(-6)}` : addr;
  }

  function getDashboardPubkey() {
    const el = document.getElementById('balanceAddress');
    const fromDataset = el?.dataset?.pubkey;
    const fromTitle = el?.title;
    const fromGlobal =
					g.damagePublicKey ||
					g.aePublicKey ||
					g.walletPublicKey ||
					g.currentPublicKey;

    const fromStorage =
					localStorage.getItem('damage_public_key') ||
					localStorage.getItem('damage_pubkey') ||
					localStorage.getItem('ae_public_key');

    const candidates = [
      fromDataset,
      fromTitle,
      fromGlobal,
      fromStorage
    ].filter(Boolean);

    return candidates.find((v) => /^ak_/.test(String(v))) || null;
  }

  const _fetchAllBalances = async (pubkey, opts = {}) => {
    const {
      apiBase = DEFAULTS.apiBase,
      timeoutMs = DEFAULTS.timeoutMs,
      credentials = DEFAULTS.credentials,
      headers = {}
    } = opts;

    if (!pubkey || pubkey === 'ak_...') {
      throw new Error('pubkey required');
    }

    const base = String(apiBase).replace(/\/$/, '');
    const url = `${base}/accounts/balance?pubkey=${encodeURIComponent(pubkey)}`;

    const r = await fetchT(url, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        ...headers
      },
      credentials
    }, timeoutMs);

    const j = await r.json();

    if (j?.status && j.status !== 'ok') {
      throw new Error(j?.reason || j?.error || 'balance fetch failed');
    }

    const account = j.address || j.id || pubkey;

    // Current /accounts/balance shape.
    const damageRaw = toIntegerString(j.damage ?? j.amount ?? j.hits ?? '0');
    const aeRaw = toIntegerString(j.ae ?? j.aettos ?? j.ae_amount ?? '0');
    const msatsRaw = toIntegerString(j.balance_msat ?? j.msats ?? j?.ledger?.balance_msat ?? '0');

    return {
      pubkey: account,

      damageRaw,
      damage: displayValue(damageRaw, j.damage_display, DAMAGE_DECIMALS),

      aeRaw,
      ae: displayValue(aeRaw, j.ae_display, AE_DECIMALS),

      msats: msatsRaw,
      sats: displayValue(msatsRaw, j.sats_display ?? j.sats, MSATS_DECIMALS),

      stale: Boolean(j.stale),
      source: j.source || 'unknown',
      cachedAtMs: j.cached_at_ms,
      updatedAtMs: j.updated_at_ms,
      ageMs: j.age_ms,

      raw: j
    };
  };

  const fetchAllBalances = safe(_fetchAllBalances);

  const _fetchNodeBalances = async (opts = {}) => {
    const {
      apiBase = DEFAULTS.apiBase,
      timeoutMs = DEFAULTS.timeoutMs,
      credentials = DEFAULTS.credentials,
      headers = {}
    } = opts;

    const base = String(apiBase).replace(/\/$/, '');
    const url = `${base}/api/node/balances`;

    const r = await fetchT(url, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        ...headers
      },
      credentials
    }, timeoutMs);

    return r.json();
  };

  const fetchNodeBalances = safe(_fetchNodeBalances);

  async function updateAllBalances(pubkey, opts = {}) {
    const {
      preserveAddressText = DEFAULTS.preserveAddressText
    } = opts;

    const pubkeyEl = document.getElementById('balanceAddress');
    const aeEl = document.getElementById('aeBalance');
    const damageEl = document.getElementById('balanceAmount');
    const satsEl = document.getElementById('satsBalance');

    const resolvedPubkey = pubkey || getDashboardPubkey();

    if (!resolvedPubkey || resolvedPubkey === 'ak_...') {
      return {
        ok: false,
        error: { type: 'input', message: 'pubkey missing' }
      };
    }

    if (aeEl) aeEl.textContent = '...';
    if (damageEl) damageEl.textContent = '...';
    if (satsEl) satsEl.textContent = '...';

    const result = await fetchAllBalances(resolvedPubkey, opts);

    if (!result.ok) {
      if (aeEl) aeEl.textContent = '0';
      if (damageEl) damageEl.textContent = '0';
      if (satsEl) satsEl.textContent = '0';
      console.warn('updateAllBalances failed:', result.error);
      return result;
    }

    const { value } = result;

    if (aeEl) aeEl.textContent = value.ae;
    if (damageEl) damageEl.textContent = value.damage;
    if (satsEl) satsEl.textContent = value.sats;

    if (pubkeyEl) {
      const full = value.pubkey;

      if (full && !preserveAddressText && !pubkeyEl.dataset.keepFullAddress) {
        pubkeyEl.textContent = compactAddress(full);
      }

      pubkeyEl.title = full;
      pubkeyEl.dataset.pubkey = full;
    }

    document.dispatchEvent(new CustomEvent('damage:balances-updated', {
      detail: value
    }));

    return { ok: true, value };
  }

  async function updateDashboardBalances(opts = {}) {
    return updateAllBalances(getDashboardPubkey(), opts);
  }

  function bootDashboardBalanceFetch() {
    if (bootDashboardBalanceFetch.started) return;
    bootDashboardBalanceFetch.started = true;

    const run = () => {
      const pubkey = getDashboardPubkey();
      if (pubkey) {
        updateAllBalances(pubkey).catch((err) => {
          console.warn('dashboard balance boot fetch failed:', err);
        });
      }
    };

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', run, { once: true });
    } else {
      run();
    }

    // Browser back/forward cache and SPA/tab reloads.
    window.addEventListener('pageshow', run);
    document.addEventListener('damage:dashboard-loaded', run);
    document.addEventListener('damage:wallet-connected', function (ev) {
      const pubkey = ev?.detail?.pubkey || ev?.detail?.address || getDashboardPubkey();
      if (pubkey) updateAllBalances(pubkey);
    });
  }

  g.fetchAllBalances = fetchAllBalances;
  g.fetchNodeBalances = fetchNodeBalances;
  g.updateAllBalances = updateAllBalances;
  g.updateDashboardBalances = updateDashboardBalances;
  g.bootDashboardBalanceFetch = bootDashboardBalanceFetch;

  if (DEFAULTS.autoFetch) {
    bootDashboardBalanceFetch();
  }
})(typeof globalThis !== 'undefined' ? globalThis : window);
