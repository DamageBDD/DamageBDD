(function(window, document, undefined) {

	// code that should be taken care of right away
	window.dataLayer = window.dataLayer || [];


	document.addEventListener("DOMContentLoaded", async function() {
		const $ = sel => document.querySelector(sel);
		const results = $('#results');
		const statusEl = $('#status');
		const who = $('#who');
		const input = $('#q');
		const btnGo = $('#go');

		let walletAddr = null;
		let inflight = 0, tmr;
		const btnConnect = $('#connect');
		const doSearch = debounced(searchNow, 250);
		const btnClear = $('#clear');     // NEW
		const countEl = $('#count');      // NEW

		// --- Wallet detection / connect ---
		async function detectWallet() {
			try {
				// support either global injected objects from your wallet.js/sidekick.js
				const has =
					  (window.wallet && (walletAvailable(window.wallet))) ||
					  (window.sidekick && (walletAvailable(window.sidekick))) ||
					  false;
				return !!has;
			} catch { return false; }
		}

		function walletAvailable(w) {
			// heuristic: has connect method or accounts property
			return !!(w && (typeof w.connect === 'function' || typeof w.request === 'function' || w.accounts));
		}

		async function connectWallet() {
			const supportedPage = 'https://damagebdd.com/supported_wallets';
			const res = window.connectWalletUnified();
			if (!has) {
				window.location.href = supportedPage;
				return;
			}
			try {
				// try wallet.js style
				if (window.wallet && typeof window.wallet.connect === 'function') {
					const res = await window.wallet.connect();
					walletAddr = (res && (res.address || res.account || res)) || null;
				}
				// try sidekick style
				else if (window.sidekick && typeof window.sidekick.connect === 'function') {
					const res = await window.sidekick.connect();
					walletAddr = (res && (res.address || res.account || res)) || null;
				}
				// fallback: try EIP-1193-ish
				else if (window.ethereum && typeof window.ethereum.request === 'function') {
					const accs = await window.ethereum.request({ method: 'eth_requestAccounts' });
					walletAddr = accs && accs[0] || null;
				}

				if (walletAddr) {
					who.innerHTML = `Connected: <span class="ok">${short(walletAddr)}</span>`;
					btnConnect.textContent = 'Connected';
					btnConnect.disabled = true;
				} else {
					who.innerHTML = `<span class="err">Could not read wallet address.</span>`;
				}
			} catch (e) {
				console.error(e);
				who.innerHTML = `<span class="err">Wallet connect failed.</span>`;
			}
		}


		// --- Search ---
		function setBusy(b) {
			if (b) statusEl.textContent = 'Searching…';
			else if (!results.children.length) statusEl.textContent = 'No results.';
			else statusEl.textContent = `${results.children.length} result(s).`;
		}

		function debounced(fn, ms=250) {
			return (...args) => { clearTimeout(tmr); tmr = setTimeout(() => fn(...args), ms); };
		}

		async function searchNow() {
			const q = input.value.trim();
			if (!q) { results.innerHTML=''; statusEl.textContent='Enter a query.'; return; }

			inflight++; setBusy(true);
			try {
				const payload = { q, limit: 10 };
				if (walletAddr) payload.wallet = walletAddr; // tag for personalization on server

				const res = await fetch('/ecai/search', {
					method:'POST',
					headers:{ 'content-type':'application/json' },
					body: JSON.stringify(payload)
				});
				if (!res.ok) throw new Error(`HTTP ${res.status}`);
				const data = await res.json();
				render(data);
			} catch (e) {
				console.error(e);
				statusEl.innerHTML = `<span class="err">Search failed.</span>`;
			} finally {
				inflight--; if (inflight === 0) setBusy(false);
			}
		}

		function render(data) {
			results.innerHTML = '';
			if (!data || !data.ok) { statusEl.innerHTML = `<span class="err">Bad response.</span>`; return; }
			const items = data.results || [];
			for (const r of items) {
				const card = document.createElement('div');
				card.className = 'card';
				const title = document.createElement('div');
				title.className = 'doc';
				title.textContent = r.preview || (r.record?.name || r.doc_id || '(no id)');
				const score = document.createElement('div');
				score.className = 'score';
				const meta = [];
				if (r.record?.city) meta.push(r.record.city);
				if (r.record?.category) meta.push(r.record.category);
				score.textContent = `${meta.join(' • ')} — score: ${(r.score ?? 0).toFixed(3)}`;
				card.appendChild(title);
				card.appendChild(score);
				results.appendChild(card);
			}
		}


		// small helpers
		function short(addr) {
			if (!addr || typeof addr !== 'string') return '';
			return addr.length > 12 ? addr.slice(0,6) + '…' + addr.slice(-4) : addr;
		}

		// Optional: try to detect a wallet on load (don’t auto-connect)
		detectWallet().then(has => { if (has) who.textContent = 'Wallet available — connect for personalized search.'; });





		btnConnect.addEventListener('click', connectWallet);
		input.addEventListener('input', doSearch);
		input.addEventListener('keydown', e => { if (e.key === 'Enter') searchNow(); });
		btnGo.addEventListener('click', searchNow);
		// --- docs count (poll /yelp/status) ---
		async function refreshCount() {
			try {
				const r = await fetch('/yelp/status');
				const j = await r.json();
				const n = (j && j.index_size && j.index_size.docs) || 0;
				countEl.textContent = `Indexed: ${Number(n).toLocaleString()} docs`;
			} catch {
				countEl.textContent = ''; // silent if endpoint not available
			}
		}
		function showClear() { btnClear.style.display = input.value ? 'inline-block' : 'none'; }
		btnClear.addEventListener('click', () => {
			input.value = '';
			showClear();
			results.innerHTML = '';
			statusEl.textContent = 'Enter a query.';
			input.focus();
		});
		input.addEventListener('input', () => { showClear(); doSearch(); });
		input.addEventListener('keydown', e => { if (e.key === 'Enter') searchNow(); });
		btnGo.addEventListener('click', searchNow);
		refreshCount();
		setInterval(refreshCount, 10000); // update every 10s
	}); // end DOMContentLoaded 
})(window, document, undefined);
