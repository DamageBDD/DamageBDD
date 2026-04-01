// balances.js
// Single-endpoint balance loader using /accounts/balance
//
// Expected response shape from /accounts/balance:
// {
//   status: "ok",
//   aettos: "1230000000000000000",
//   hits: "45600000000",
//   msats: "7890"
// }
//
// Public helpers:
//   fetchAllBalances(pubkey[, opts])
//   updateAllBalances([opts])

(function (g) {
	'use strict';

	const DEFAULTS = {
		apiBase: '',
		timeoutMs: 10000,
		credentials: 'include'
	};

	const AE_DECIMALS = 18;
	const DAMAGE_DECIMALS = 8;
	const MSATS_DECIMALS = 3;

	// ---- utils ---------------------------------------------------------------

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

	function formatUnitsString(bnStr, decimals) {
		if (bnStr == null) return '0';

		const neg = String(bnStr)[0] === '-';
		let s = neg ? String(bnStr).slice(1) : String(bnStr);

		if (!/^\d+$/.test(s)) {
			s = String(s || '0').replace(/\D/g, '') || '0';
		}

		const d = Math.max(0, Number(decimals || 0));
		if (d === 0) return (neg ? '-' : '') + s;

		if (s.length <= d) {
			s = '0'.repeat(d - s.length + 1) + s;
		}

		const i = s.slice(0, s.length - d);
		let f = s.slice(s.length - d);
		f = f.replace(/0+$/, '');

		return (neg ? '-' : '') + (f ? `${i}.${f}` : i);
	}

	function toBigIntString(x) {
		if (typeof x === 'bigint') return x.toString(10);
		if (typeof x === 'number') return BigInt(Math.trunc(x)).toString(10);
		if (typeof x === 'string') return x;
		if (x == null) return '0';
		return String(x);
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

	// ---- balance fetch -------------------------------------------------------

	const _fetchAllBalances = async (pubkey, opts = {}) => {
		const {
			apiBase = DEFAULTS.apiBase,
			timeoutMs = DEFAULTS.timeoutMs,
			credentials = DEFAULTS.credentials,
			headers = {}
		} = opts;

		if (!pubkey) {
			throw new Error('pubkey required');
		}

		const url = `${String(apiBase).replace(/\/$/, '')}/accounts/balance?pubkey=${encodeURIComponent(pubkey)}`;

		const r = await fetchT(url, {
			method: 'GET',
			headers: {
				'Accept': 'application/json',
				...headers
			},
			credentials
		}, timeoutMs);

		const j = await r.json();

		if (j?.status && j.status !== 'ok') {
			throw new Error(j?.reason || j?.error || 'balance fetch failed');
		}

		// Accept a few possible field names just in case the backend varies.
		const aettos = toBigIntString(j.aettos ?? j.ae_balance ?? j.balance ?? '0');
		const hits = toBigIntString(j.hits ?? j.damage_hits ?? j.damage_balance ?? '0');
		const msats = toBigIntString(j.msats ?? j.sats_msats ?? j.btc_balance ?? '0');

		return {
			pubkey,
			aettos,
			ae: formatUnitsString(aettos, AE_DECIMALS),
			hits,
			damage: formatUnitsString(hits, DAMAGE_DECIMALS),
			msats,
			sats: formatUnitsString(msats, MSATS_DECIMALS),
			raw: j
		};
	};

	const fetchAllBalances = safe(_fetchAllBalances);

	// ---- single DOM update function -----------------------------------------

	async function updateAllBalances(pubkey) {
		const pubkeyEl = document.getElementById('balanceAddress');
		const aeEl = document.getElementById('aeBalanceAmount');
		const damageEl = document.getElementById('balanceAmount');
		const satsEl = document.getElementById('satsBalanceAmount');

		if (!pubkey || pubkey === 'ak_...') {
			return {
				ok: false,
				error: { type: 'input', message: 'pubkey missing' }
			};
		}

		if (aeEl) aeEl.textContent = '...';
		if (damageEl) damageEl.textContent = '...';
		if (satsEl) satsEl.textContent = '...';

		const result = await fetchAllBalances(pubkey, {});

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
			if (full && !opts.preserveAddressText && !pubkeyEl.dataset.keepFullAddress) {
				pubkeyEl.textContent =
					full.length > 14 ? `${full.slice(0, 8)}...${full.slice(-6)}` : full;
			}
			pubkeyEl.title = full;
			if (!pubkeyEl.dataset.pubkey) {
				pubkeyEl.dataset.pubkey = full;
			}
		}

		return {
			ok: true,
			value
		};
	}

	// ---- exports -------------------------------------------------------------

	g.fetchAllBalances = fetchAllBalances;
	g.updateAllBalances = updateAllBalances;

	// ---- auto-load -----------------------------------------------------------

	//document.addEventListener('DOMContentLoaded', () => {
	//	updateAllBalances().catch((err) => {
	//		console.error('DOMContentLoaded balance update failed:', err);
	//	});
	//});

})(typeof globalThis !== 'undefined' ? globalThis : window);
