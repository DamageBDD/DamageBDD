/*
  job_ui.js — Plain JS frontend API + minimal UI glue for submitting jobs
  Assumptions:
  - Your HTML already has:
      <textarea id="featureInput"></textarea>
      <input id="aeAddress" placeholder="ak_..." />
      <input id="concurrency" type="number" min="1" value="1" />
      <button id="quoteBtn">Dry‑run & Quote</button>
      <button id="executeBtn">Execute</button>
      <pre id="quoteOut"></pre>
      <pre id="runOut"></pre>
  - If you have a wallet helper (e.g., wallet.js), pass sign/getAddress in config.
  - Endpoints provided by your server (damage_http.erl):
      PUT /tx/ {feature, concurrency, address}  -> returns {cost, feature_hash, report_hash, tx}
      PUT /tx/ {feature, concurrency, address, signed_tx} -> posts tx, executes job
*/

export const DamageJobs = (() => {
  const state = {
    baseUrl: '',
    getAccessToken: null, // async () => string | null
    signTx: null,         // async (tx) => signedTx (binary string/base58/rlp as server expects)
    getAddress: null      // async () => "ak_..."
  };

  function cfg(userCfg = {}) {
    state.baseUrl = userCfg.baseUrl || '';
    state.getAccessToken = userCfg.getAccessToken || null;
    state.signTx = userCfg.signTx || null;
    state.getAddress = userCfg.getAddress || null;
  }

  function headers(extra = {}) {
    const h = { 'content-type': 'application/json' };
    if (state.getAccessToken) {
      // Allow sync or async token fetch
      try {
        const tok = state.getAccessToken();
        if (tok && typeof tok.then === 'function') {
          return tok.then(t => Object.assign(h, { 'Authorization': `Bearer ${t}` }, extra));
        }
        if (tok) h['Authorization'] = `Bearer ${tok}`;
      } catch (_) { /* ignore */ }
    }
    return Promise.resolve(Object.assign(h, extra));
  }

  async function putJson(path, body, extraHeaders = {}) {
    const hdrs = await headers(extraHeaders);
    const res = await fetch(joinUrl(state.baseUrl, path), {
      method: 'PUT',
      headers: hdrs,
      body: JSON.stringify(body)
    });
    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { data = { raw: text }; }
    if (!res.ok) throw Object.assign(new Error('HTTP ' + res.status), { status: res.status, data });
    return data;
  }

  function joinUrl(base, path) {
    if (!base) return path;
    if (base.endsWith('/') && path.startsWith('/')) return base.slice(0, -1) + path;
    if (!base.endsWith('/') && !path.startsWith('/')) return base + '/' + path;
    return base + path;
  }

  // ---- Public API ----

  /**
   * Dry‑run & quote: asks the server to simulate the feature and return cost + prepared spend tx.
   * @returns {Promise<{cost:number, feature_hash:string, report_hash:string, tx:any}>}
   */
  async function quote({ feature, address, concurrency = 1 }) {
    if (!feature || !feature.trim()) throw new Error('Empty feature');
    if (!address) throw new Error('Missing address (ak_...)');
    const payload = { feature, concurrency, address };
    return await putJson('/tx/', payload, { 'x-damage-concurrency': String(concurrency) });
  }

  /**
   * Execute: signs the returned tx and submits it; server posts tx and executes the job.
   * If you pass `signedTx`, `signTx` is skipped.
   */
  async function execute({ feature, address, concurrency = 1, preparedTx, signedTx }) {
    const ak = address || (state.getAddress ? await state.getAddress() : null);
    if (!ak) throw new Error('Missing address (ak_...). Provide address or configure getAddress().');

    let stx = signedTx;
    if (!stx) {
      if (!preparedTx) {
        const q = await quote({ feature, address: ak, concurrency });
        preparedTx = q.tx;
      }
      if (!state.signTx) throw new Error('No signTx configured: cannot sign prepared transaction');
      stx = await state.signTx(preparedTx);
    }

    const payload = { feature, concurrency, address: ak, signed_tx: stx };
    return await putJson('/tx/', payload, { 'x-damage-concurrency': String(concurrency) });
  }

  // ---- Minimal UI glue (binds to existing HTML ids) ----
  function bindUI({
    featureId = 'featureInput',
    addressId = 'aeAddress',
    concurrencyId = 'concurrency',
    quoteBtnId = 'quoteBtn',
    execBtnId = 'executeBtn',
    quoteOutId = 'quoteOut',
    runOutId = 'runOut'
  } = {}) {
    const $f = document.getElementById(featureId);
    const $a = document.getElementById(addressId);
    const $c = document.getElementById(concurrencyId);
    const $q = document.getElementById(quoteBtnId);
    const $x = document.getElementById(execBtnId);
    const $qo = document.getElementById(quoteOutId);
    const $ro = document.getElementById(runOutId);

    const read = () => ({ feature: $f.value || '', address: $a.value || '', concurrency: parseInt($c.value || '1', 10) || 1 });

    $q?.addEventListener('click', async () => {
      toggle($q, true);
      try {
        const { feature, address, concurrency } = read();
        const res = await quote({ feature, address, concurrency });
        $qo.textContent = pretty(res);
      } catch (e) {
        $qo.textContent = errText(e);
      } finally { toggle($q, false); }
    });

    $x?.addEventListener('click', async () => {
      toggle($x, true);
      try {
        const { feature, address, concurrency } = read();
        const q = await quote({ feature, address, concurrency });
        const res = await execute({ feature, address, concurrency, preparedTx: q.tx });
        $ro.textContent = pretty(res);
      } catch (e) {
        $ro.textContent = errText(e);
      } finally { toggle($x, false); }
    });
  }

  // ---- helpers ----
  function pretty(v) { try { return JSON.stringify(v, null, 2); } catch { return String(v); } }
  function toggle(btn, busy) { if (!btn) return; btn.disabled = !!busy; btn.textContent = busy ? (btn.dataset.busy || 'Working…') : (btn.dataset.label || btn.textContent); }
  function errText(e){
    if (!e) return 'Unknown error';
    if (e.data) return pretty(e.data);
    if (e.message) return e.message;
    return String(e);
  }

  return { cfg, quote, execute, bindUI };
})();

/* Example wiring (optional):
import { DamageJobs } from './job_ui.js';
import { wallet } from './wallet.js'; // assume it exposes getAddress() and signTx(tx)

DamageJobs.cfg({
  baseUrl: '',
  getAccessToken: () => localStorage.getItem('access_token'),
  getAddress: () => wallet.getAddress(),
  signTx: (tx) => wallet.signTx(tx)
});

DamageJobs.bindUI();
*/
