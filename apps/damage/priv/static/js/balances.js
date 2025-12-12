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

	// ---- Common Normalized Errors ----------------------------------------------

	function normalizeError(err) {
		if (!err) return { type: 'unknown', message: 'Unknown error' };

		if (typeof err === 'string') {
			return { type: 'string-error', message: err };
		}

		if (err.name === 'AbortError') {
			return { type: 'timeout', message: 'Request timed out' };
		}

		return {
			type: err.type || 'exception',
			message: err.message || String(err),
			stack: err.stack
		};
	}

	// Wrap any async function in safe container
	const safe = (fn) => async (...args) => {
		try {
			return { ok: true, value: await fn(...args) };
		} catch (err) {
			return { ok: false, error: normalizeError(err) };
		}
	};
	const _fetchAeBalance = async (pubkey, opts = {}) => {
		const { nodeBase = DEFAULTS.nodeBase, timeoutMs = DEFAULTS.timeoutMs } = opts;
		const url = `${nodeBase.replace(/\/$/, '')}/v3/accounts/${encodeURIComponent(pubkey)}?int-as-string=true`;

		const r = await fetchT(url, {
			headers: { 'Accept': 'application/json' },
			credentials: 'omit'
		}, timeoutMs);

		if (!r.ok) {
			throw new Error(`HTTP ${r.status} ${r.statusText}`);
		}

		const j = await r.json();

		const aettos = toBigIntString(j.balance || '0');
		const ae = formatUnitsString(aettos, 18);

		return {
			ok: true,
			aettos,
			ae,
			nonce: j.nonce,
			raw: j
		};
	};

	const fetchAeBalance = safe(_fetchAeBalance);
	const _fetchAex9Balances = async (pubkey, opts = {}) => {
		const { mdwBase = DEFAULTS.mdwBase, timeoutMs = DEFAULTS.timeoutMs } = opts;
		const base = mdwBase.replace(/\/$/, '');
		const url = `${base}/v3/aex9/${DAMAGE_CONTRACT_ID}/balances/${encodeURIComponent(pubkey)}`;

		const r = await fetchT(url, {
			headers: { 'Accept': 'application/json' },
			credentials: 'omit'
		}, timeoutMs);

		if (!r.ok) {
			throw new Error(`HTTP ${r.status} ${r.statusText}`);
		}

		const j = await r.json();

		const hits = toBigIntString(j.amount || '0');
		const damage = formatUnitsString(hits, 8);

		return {
			ok: true,
			raw: j.amount,
			damage,
			hits
		};
	};

	const fetchAex9Balances = safe(_fetchAex9Balances);

	async function fetchAeAndAex9Balances(pubkey, opts = {}) {
		const [ae, dgt] = await Promise.all([
			fetchAeBalance(pubkey, opts),
			fetchAex9Balances(pubkey, opts)
		]);

		const out = {
			ok: ae.ok && dgt.ok,
			ae: ae.ok ? ae.value : null,
			damage: dgt.ok ? dgt.value : null,
			errors: []
		};

		if (!ae.ok) out.errors.push({ which: 'ae', ...ae.error });
		if (!dgt.ok) out.errors.push({ which: 'aex9', ...dgt.error });

		return out;
	}

	// expose for easy use + console testing
	g.fetchAeBalance = fetchAeBalance;
	g.fetchAex9Balances = fetchAex9Balances;
	g.fetchAeAndAex9Balances = fetchAeAndAex9Balances;

})(typeof globalThis !== 'undefined' ? globalThis : window);
