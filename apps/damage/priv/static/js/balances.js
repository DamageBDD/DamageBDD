// balances.js (or paste into wallet.js / main.js)
// Global helpers: fetchAeAndAex9Balances(pubkey[, opts]), fetchAeBalance, fetchAex9Balances
const DAMAGE_CONTRACT_ID = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk';

(function (g) {
  'use strict';

  const DEFAULTS = {
    nodeBase: 'https://mainnet.aeternity.io',
    mdwBase:  'https://mainnet.aeternity.io/mdw',
    timeoutMs: 12000
  };

  // ---- utils ---------------------------------------------------------------

  // fetch with timeout
  async function fetchT(url, init = {}, timeoutMs = DEFAULTS.timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const r = await fetch(url, { ...init, signal: ctrl.signal });
      if (!r.ok) {
        const msg = `${r.status} ${r.statusText}`;
        throw new Error(`${url} → ${msg}`);
      }
      return r;
    } finally {
      clearTimeout(t);
    }
  }

  // Convert big-int string to decimal string with 'decimals'
  function formatUnitsString(bnStr, decimals) {
    if (bnStr == null) return '0';
    const neg = bnStr[0] === '-';
    let s = neg ? bnStr.slice(1) : bnStr;
    if (!/^\d+$/.test(s)) s = String(s || '0').replace(/\D/g, '') || '0';

    const d = Math.max(0, Number(decimals || 0));
    if (d === 0) return (neg ? '-' : '') + s;

    // pad left with zeros to at least d+1 length
    if (s.length <= d) s = '0'.repeat(d - s.length + 1) + s;

    const i = s.slice(0, s.length - d);
    let f = s.slice(s.length - d);
    f = f.replace(/0+$/, ''); // trim trailing zeros
    return (neg ? '-' : '') + (f ? i + '.' + f : i);
  }

  function toBigIntString(x) {
    // Accept number | string | bigint
    if (typeof x === 'bigint') return x.toString(10);
    if (typeof x === 'number')  return BigInt(Math.trunc(x)).toString(10);
    if (typeof x === 'string')  return x;
    return '0';
  }

  // ---- AE (node) -----------------------------------------------------------

  async function fetchAeBalance(pubkey, opts = {}) {
    const { nodeBase = DEFAULTS.nodeBase, timeoutMs = DEFAULTS.timeoutMs } = opts;
    const url = `${nodeBase.replace(/\/$/, '')}/v3/accounts/${encodeURIComponent(pubkey)}?int-as-string=true`;
    const r = await fetchT(url, { headers: { 'Accept': 'application/json' }, credentials: 'omit' }, timeoutMs);
    const j = await r.json();

    // j.balance is a string when int-as-string=true
    const aettos = toBigIntString(j.balance || '0');
    const ae = formatUnitsString(aettos, 18); // AE uses 18 decimals
    return {
      ok: true,
      aettos,
      ae,
      nonce: j.nonce,
      raw: j
    };
  }

  // ---- AEX9 (MDW) ----------------------------------------------------------

	async function fetchAex9Balances(pubkey, opts = {}) {
		const { mdwBase = DEFAULTS.mdwBase, timeoutMs = DEFAULTS.timeoutMs } = opts;
		const base = mdwBase.replace(/\/$/, '');
		const url  = `${base}/v3/aex9/${DAMAGE_CONTRACT_ID}/balances/${encodeURIComponent(pubkey)}`;
		//https://mainnet.aeternity.io/mdw/v3/aex9/ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk/balances/ak_ag9FGrk8okPzGJZzWL7UuK21NYckM6Tsbtaapmv3iFM4Hn8dW
		const r = await fetchT(url, { headers: { 'Accept': 'application/json' }, credentials: 'omit' }, timeoutMs);
		const j = await r.json();

		const hits = toBigIntString(j.amount || '0');
    const damage = formatUnitsString(hits, 8); // AE uses 18 decimals
		return {
			ok: true,
			raw:j.amount,
			damage,
			hits
		};
	}


  // ---- Combined ------------------------------------------------------------

  async function fetchAeAndAex9Balances(pubkey, opts = {}) {
    const [aeRes, aex9Res] = await Promise.allSettled([
      fetchAeBalance(pubkey, opts),
      fetchAex9Balances(pubkey, opts)
    ]);

    const out = { ok: true, ae: null, damage: null, errors: [] };

    if (aeRes.status === 'fulfilled') {
      out.ae = aeRes.value;
    } else {
      out.ok = false;
      out.errors.push('ae:' + (aeRes.reason?.message || String(aeRes.reason)));
    }

    if (aex9Res.status === 'fulfilled') {
		out.damage = aex9Res.value;
    } else {
      out.ok = false;
      out.errors.push('aex9:' + (aex9Res.reason?.message || String(aex9Res.reason)));
    }

    return out;

  }

  // expose for easy use + console testing
  g.fetchAeBalance = fetchAeBalance;
  g.fetchAex9Balances = fetchAex9Balances;
  g.fetchAeAndAex9Balances = fetchAeAndAex9Balances;

})(typeof globalThis !== 'undefined' ? globalThis : window);
