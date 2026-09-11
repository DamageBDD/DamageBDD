(function(window, document, undefined) {
	let lastDamageUSDT = null;
	let lastBtcUSDT = null;
	let lastFetchMs = 0;

	const numberFmt = (n, max=8) => {
		try {
			return new Intl.NumberFormat(undefined, { maximumFractionDigits: max }).format(n);
		} catch {
			return n.toLocaleString(undefined, { maximumFractionDigits: max });
		}
	};

	async function fetchJson(url) {
		const res = await fetch(url, { mode: 'cors' });
		if (!res.ok) throw new Error(`HTTP ${res.status}`);
		return res.json();
	}

	async function fetchCoinstoreDamageAndBtc() {
		const base = 'https://api.coinstore.com/api';
		const url = `${base}/v1/ticker/price?symbol=damageusdt,btcusdt`;
		const j = await fetchJson(url);
		if (!(j && (j.code === 0 || j.code === '0') && Array.isArray(j.data))) {
			throw new Error('Unexpected Coinstore response');
		}
		const map = new Map();
		j.data.forEach(row => {
			if (!row || !row.symbol) return;
			const sym = String(row.symbol).toLowerCase();
			const price = parseFloat(row.price);
			if (!Number.isNaN(price)) map.set(sym, price);
		});
		const dmg = map.get('damageusdt');
		const btc = map.get('btcusdt');
		if (!(dmg && btc)) throw new Error('Missing DAMAGE or BTC price from Coinstore');
		lastDamageUSDT = dmg;
		lastBtcUSDT = btc;
		lastFetchMs = Date.now();
		return [dmg, btc];
	}

	function satsFromUsd(usd, btc_usdt) {
		return (usd * 1e8) / btc_usdt;
	}

	function convert(value, from, to) {
		if (lastDamageUSDT == null || lastBtcUSDT == null) return null;
		const dmg = lastDamageUSDT;
		const btc = lastBtcUSDT;
		const toUSDT = (val, what) => {
			if (what === 'DAMAGE') return val * dmg;
			if (what === 'USDT') return val;
			if (what === 'SATS') return (val * btc) / 1e8;
			if (what === 'BTC') return val * btc;
			return NaN;
		};
		const fromUSDT = (usd, what) => {
			if (what === 'DAMAGE') return usd / dmg;
			if (what === 'USDT') return usd;
			if (what === 'SATS') return satsFromUsd(usd, btc);
			if (what === 'BTC') return usd / btc;
			return NaN;
		};
		const usd = toUSDT(value, from);
		return fromUSDT(usd, to);
	}

	function bindConverter() {
		const amount = document.getElementById('conv-amount');
		const fromSel = document.getElementById('conv-from');
		const toSel   = document.getElementById('conv-to');
		const out     = document.getElementById('conv-output');
		const satsOut = document.getElementById('conv-output-sats');

		if (!amount || !fromSel || !toSel || !out) return null;

		// Default buyer path: 1 DAMAGE -> sats.
		amount.value = amount.value || '1';
		fromSel.value = 'DAMAGE';
		toSel.value = 'SATS';

		function recalcOnce() {
			const v = parseFloat(amount.value);
			if (Number.isNaN(v)) {
				out.textContent = '—';
				if (satsOut) satsOut.textContent = '—';
				return;
			}

			const res = convert(v, fromSel.value, toSel.value);
			if (res == null) {
				out.textContent = '…';
				if (satsOut) satsOut.textContent = '…';
				return;
			}

			const precision = toSel.value === 'BTC' ? 8 : toSel.value === 'SATS' ? 2 : 6;
			out.textContent = numberFmt(res, precision) + ' ' + (toSel.value === 'SATS' ? 'sats' : toSel.value);

			// Also show sats for convenience.
			if (satsOut) {
				let usd;
				if (toSel.value === 'USDT') usd = res;
				else if (toSel.value === 'DAMAGE') usd = res * lastDamageUSDT;
				else if (toSel.value === 'SATS') usd = (res * lastBtcUSDT) / 1e8;
				else if (toSel.value === 'BTC') usd = res * lastBtcUSDT;
				else usd = NaN;

				const sats = satsFromUsd(usd, lastBtcUSDT);
				satsOut.textContent = Number.isFinite(sats) ? numberFmt(sats, 2) + ' sats' : '—';
			}
		}

		amount.addEventListener('input', recalcOnce);
		amount.addEventListener('change', recalcOnce);
		fromSel.addEventListener('change', recalcOnce);
		toSel.addEventListener('change', recalcOnce);

		return recalcOnce;
	}

	function updatePricingTable() {
		const status = document.querySelector('#pricing-status');
		const dmgCell = document.querySelector('#damage-usdt');
		const btcCell = document.querySelector('#btc-usdt');

		const dmgUSDT = lastDamageUSDT;
		const btcUSDT = lastBtcUSDT;
		if (dmgCell) dmgCell.textContent = numberFmt(dmgUSDT);
		if (btcCell) btcCell.textContent = numberFmt(btcUSDT);

		document.querySelectorAll('[data-damage]').forEach(row => {
			const qty = parseFloat(row.getAttribute('data-damage'));
			if (Number.isNaN(qty) || qty <= 0) return;
			const usd = dmgUSDT * qty;
			const sats = satsFromUsd(usd, btcUSDT);

			const dmgSpan = row.querySelector('[data-price="damage"]');
			const usdSpan = row.querySelector('[data-price="usd"]');
			const satsSpan = row.querySelector('[data-price="sats"]');

			if (dmgSpan) dmgSpan.textContent = numberFmt(qty) + ' DAMAGE';
			if (usdSpan) usdSpan.textContent = '$' + numberFmt(usd);
			if (satsSpan) satsSpan.textContent = numberFmt(sats) + ' sats';
		});

		const ts = new Date().toLocaleString();
		if (status) status.textContent = 'Prices live from Coinstore • Last update: ' + ts;
	}

	function hasPricingElements() {
		return Boolean(
			document.getElementById('live-pricing') ||
			document.getElementById('converter') ||
			document.getElementById('pricing-status') ||
			document.getElementById('conv-output') ||
			document.querySelector('[data-damage]')
		);
	}

	let pendingConverterRecalc = null;

	async function tick() {
		if (!hasPricingElements()) return;
		try {
			const [dmgUSDT, btcUSDT] = await fetchCoinstoreDamageAndBtc();
			lastDamageUSDT = dmgUSDT;
			lastBtcUSDT = btcUSDT;
			updatePricingTable();
			if (typeof pendingConverterRecalc === 'function') pendingConverterRecalc();
		} catch (e) {
			const status = document.querySelector('#pricing-status');
			if (status) status.textContent = 'Price fetch failed from Coinstore.';
			console.warn(e);
		}
	}

	// --- expose minimal API for other modules (e.g., main.js) ---
	async function getPricesCached(maxAgeMs = 60_000) {
		const now = Date.now();
		if (lastDamageUSDT != null && lastBtcUSDT != null && (now - lastFetchMs) < maxAgeMs) {
			return { damage_usdt: lastDamageUSDT, btc_usdt: lastBtcUSDT, cached: true };
		}
		const [dmgUSDT, btcUSDT] = await fetchCoinstoreDamageAndBtc();
		return { damage_usdt: dmgUSDT, btc_usdt: btcUSDT, cached: false };
	}

	// sats -> USD -> DAMAGE quote
	async function quoteFromSats(sats) {
		const s = Number(sats);
		if (!Number.isFinite(s) || s <= 0) return null;

		const { damage_usdt, btc_usdt } = await getPricesCached(60_000);
		const usd = (s * btc_usdt) / 1e8;
		const damage = usd / damage_usdt;

		return { sats: s, usd, damage, damage_usdt, btc_usdt };
	}

	window.CoinstorePricing = {
		getPricesCached,
		quoteFromSats,
	};

	document.addEventListener("DOMContentLoaded", async function() {
		if (!hasPricingElements()) return;

		pendingConverterRecalc = bindConverter();
		if (typeof pendingConverterRecalc === 'function') pendingConverterRecalc();

		await tick();
		setInterval(tick, 60000);
	});

})(window, document, undefined);
