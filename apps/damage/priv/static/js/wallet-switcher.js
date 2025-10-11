import * as wallet from "/static/js/wallet.js";
// ---- Damage Auth Token Manager --------------------------------------------
const AUTH_KEYS = {
	activeMode: 'active_auth_mode',                 // 'custodial' | 'extension'
	activeToken: 'access_token',                    // <-- the key your app already uses
	custToken:  'access_token_custodial',
	extToken:   'access_token_extension',
	email:      'damage_email',                     // optional convenience
	extAddr:    'damage_ext_addr'                   // optional convenience
};

const TokenManager = {
	getMode() { return localStorage.getItem(AUTH_KEYS.activeMode) || 'custodial'; },
	setMode(mode) { localStorage.setItem(AUTH_KEYS.activeMode, mode); },

	getToken(mode = this.getMode()) {
		return mode === 'extension'
			? localStorage.getItem(AUTH_KEYS.extToken)
			: localStorage.getItem(AUTH_KEYS.custToken);
	},

	setToken(mode, token) {
		if (mode === 'extension') localStorage.setItem(AUTH_KEYS.extToken, token || '');
		else                      localStorage.setItem(AUTH_KEYS.custToken, token || '');
	},

	// Keep your app’s canonical key up-to-date:
	activate(mode) {
		this.setMode(mode);
		const t = this.getToken(mode) || '';
		localStorage.setItem(AUTH_KEYS.activeToken, t);     // <-- swap the active access_token
		return t;
	},

	// One-time migration: if you already had a single access_token, store it as custodial.
	migrateOnce() {
		const migrated = localStorage.getItem('__damage_token_migrated__');
		if (migrated) return;
		const lone = localStorage.getItem(AUTH_KEYS.activeToken);
		if (lone && !localStorage.getItem(AUTH_KEYS.custToken) && !localStorage.getItem(AUTH_KEYS.extToken)) {
			localStorage.setItem(AUTH_KEYS.custToken, lone);
			localStorage.setItem(AUTH_KEYS.activeMode, 'custodial');
		}
		localStorage.setItem('__damage_token_migrated__', '1');
	},

	logout(mode) {
		if (!mode || mode === 'custodial') localStorage.removeItem(AUTH_KEYS.custToken);
		if (!mode || mode === 'extension') localStorage.removeItem(AUTH_KEYS.extToken);
		if (!mode) localStorage.removeItem(AUTH_KEYS.activeToken);
	}
};
// ----------------------------------------------------------------------------
document.addEventListener('DOMContentLoaded', () => {
	TokenManager.migrateOnce();

	const selector = document.getElementById('walletSelector');
	const balanceAmount = document.getElementById('balanceAmount');

	// set initial selector value to previously-active mode
	selector.value = TokenManager.getMode();

	// ensure the canonical access_token matches the selected mode on page load
	TokenManager.activate(selector.value);

	selector.addEventListener('change', () => onWalletChange(selector.value)); //.catch(console.error));

	initWalletSelector().then(updateWalletSummary);

	async function onWalletChange(mode) {
		if (mode === 'extension') {
			// 1) make sure wallet is connected
			const connected = await ensureBrowserWalletConnected();
			if (!connected) { if (window.MicroModal) MicroModal.show('connect-wallet-modal'); return; }

			// 2) ensure an extension token exists (if not, do challenge/verify handshake)
			let extTok = TokenManager.getToken('extension');
			if (!extTok) extTok = await ensureExtensionToken(); // may open wallet to sign
			if (!extTok) { /* user cancelled */ return; }

			// 3) swap active access_token
			TokenManager.activate('extension');
		var address = wallet.getAddress();
		localStorage.setItem("address", address);
		var address = localStorage.getItem("address");
		if(address){
			document.getElementById("damage-address").value = address;
		}
		} else {
			// custodial: require login flow to set its token
			let custTok = TokenManager.getToken('custodial');
			if (!custTok) {
				if (window.MicroModal) MicroModal.show('email-login-modal');
				// your login handler should call `TokenManager.setToken('custodial', token); TokenManager.activate('custodial');`
				return;
			}
			TokenManager.activate('custodial');
		}
		await updateWalletSummary();
	}

	// Call these from your existing login/connect flows:
	window.__damage_onCustodialLoginSuccess = function(token) {
		TokenManager.setToken('custodial', token);
		TokenManager.activate('custodial');
		updateWalletSummary();
	};

	window.__damage_onExtensionAuthSuccess = function(token) {
		TokenManager.setToken('extension', token);
		TokenManager.activate('extension');
		updateWalletSummary();
	};

	// Use this from wallet-switcher.js
	// Example: await updateWalletSummary();

	async function updateWalletSummary(opts = {}) {
		const {
			balanceAmountId = 'balanceAmount',
			aeBalanceId = 'aeBalance'
		} = opts;

		const balanceAmountEl = document.getElementById(balanceAmountId);
		const aeBalanceEl = document.getElementById(aeBalanceId);

		if (!balanceAmountEl) return;

		// helpers (local fallbacks if your globals aren’t loaded yet)
		const _shortAddr = (typeof shortAddr === 'function')
			  ? shortAddr
			  : (a => a ? a.slice(0, 6) + '…' + a.slice(-4) : '');

		const formatDamage = (raw = 0) =>
			  (Number(raw) / 1e8).toLocaleString(undefined, {
				  minimumFractionDigits: 2,
				  maximumFractionDigits: 2
			  });

		const formatAE = (v) => {
			if (v == null || isNaN(v)) return '—';
			return v.toLocaleString(undefined, {
				minimumFractionDigits: 6,
				maximumFractionDigits: 6
			});
		};

		const setAE = (valText) => {
			if (aeBalanceEl) aeBalanceEl.textContent = 'AE: ' + valText;
		};

		balanceAmountEl.textContent = '…';
		setAE('—');

		try {
			const mode = TokenManager.getMode();

			if (mode === 'custodial') {
				const t = TokenManager.getToken('custodial');
				if (!t) {
					//balanceAmountEl.textContent = 'Login';
					if (window.MicroModal) MicroModal.show('email-login-modal');
					setAE('—');
					return;
				}

				const r = await fetch('/accounts/balance', {
					headers: { 'Content-Type': 'application/json',
					   'Authorization': 'Bearer ' + t
					 },
					credentials: 'include'
				});

				if (r.status === 401) {
					try { localStorage.removeItem('access_token'); } catch {}
					if (window.MicroModal) MicroModal.show('email-login-modal');
					//try { localStorage.removeItem('address'); } catch {}
					//balanceAmountEl.textContent = 'Login';
					setAE('—');
					return;
				}

				if (!r.ok) {
					balanceAmountEl.textContent = 'N/A';
					setAE('—');
					return;
				}

				const j = await r.json();

				// DAMAGE (server returns integer with 8 decimals)
				const rawDamage = Number(j.amount ?? j ?? 0);
				balanceAmountEl.textContent = formatDamage(rawDamage);

				// AE (optional fields if backend provides them)
				let rawAe = (j.ae_amount != null) ? Number(j.ae_amount)
					: (typeof j.ae === 'number') ? Number(j.ae)
					: null;

				// Keep your original assumption: aetto → AE via 1e8 (adjust if backend changes)
				const ae = (rawAe == null) ? null : (rawAe / 1e8);
				setAE(formatAE(ae));
				return;
			}

			// Non-custodial (browser wallet)
			const addr = await getBrowserWalletAddress(false);
			if (!addr) {
				MicroModal.show('connect-wallet-modal');
				balanceAmountEl.textContent = 'Connect';
				setAE('—');
				return;
			}

			// Show address when not using server auth/balance
			balanceAmountEl.textContent = _shortAddr(addr);
			setAE('—'); // you can later enrich this by querying a public AE endpoint if desired

		} catch (e) {
			console.error('updateWalletSummary', e);
			balanceAmountEl.textContent = 'Err';
			setAE('—');
		}
	}


	// --- wallet helpers (same as before, trimmed for brevity) ---
	async function initWalletSelector(){ /* detect wallet, label options, etc. */ }
	async function ensureBrowserWalletConnected(){
		const addr = await getBrowserWalletAddress(true).catch(() => null);
		if (addr) localStorage.setItem(AUTH_KEYS.extAddr, addr);
		return !!addr;
	}
	async function getBrowserWalletAddress(request){
		var address = await wallet.getAddress();
		return address;
	}
	function shortAddr(a){ return a ? (a.length>12 ? a.slice(0,6)+'…'+a.slice(-4) : a) : '—'; }
	function formatAmount(x){ if (x==null) return '—'; if (typeof x==='number') return x.toLocaleString(); if (/^\d+$/.test(String(x))) return Number(String(x)).toLocaleString(); return String(x); }

	// --- extension token minting (challenge -> sign -> verify) ---
	async function ensureExtensionToken() {
		try {
			// 1) ask server for a challenge bound to the address (adjust endpoint names as needed)
			const addr = localStorage.getItem(AUTH_KEYS.extAddr) || await getBrowserWalletAddress(true);
			if (!addr) return null;

			const startRes = await fetch('/auth/extension/start', {
				method: 'POST', headers: { 'Content-Type':'application/json' },
				body: JSON.stringify({ address: addr })
			});
			if (!startRes.ok) return null;
			const { challenge } = await startRes.json();

			// 2) sign the challenge with the wallet
			let signature = null;
			if (window.superhero && window.superhero.signMessage) {
				signature = await window.superhero.signMessage(challenge);
			} else if (window.ethereum) {
				// personal_sign uses (data, address) in many wallets
				signature = await window.ethereum.request({ method:'personal_sign', params:[ challenge, addr ] });
			} else { return null; }

			// 3) verify signature -> receive access_token
			const verifyRes = await fetch('/auth/extension/verify', {
				method: 'POST', headers: { 'Content-Type':'application/json' },
				body: JSON.stringify({ address: addr, challenge, signature })
			});
			if (!verifyRes.ok) return null;
			const { access_token } = await verifyRes.json();

			if (access_token) {
				TokenManager.setToken('extension', access_token);
				// if currently on extension, also activate it now
				if (TokenManager.getMode() === 'extension') TokenManager.activate('extension');
				return access_token;
			}
		} catch (e) {
			console.warn('ensureExtensionToken failed', e);
		}
		return null;
	}
	function validateEmail(email) {
		const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
		return regex.test(email);
	}
	// Example: connect button inside wallet-switcher.js
	document.getElementById('email-login-submit-btn')?.addEventListener('click', async (ev) => {
        ev.preventDefault();
		const btn = ev.currentTarget;
		const prev = btn.textContent;
		const usernameEl = document.getElementById("email-login-username");
		const passwordEl = document.getElementById("email-password");
		const username = usernameEl.value;
		const password = passwordEl.value;
		usernameEl.value = "";
		passwordEl.value = "";

		if (!validateEmail(username)) {
			showNotification({
				title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
			return;
		}

		const signupData = {
			grant_type: "password",
			scope: "basic",
			username: username,
			password: password
		};

		const headers = new Headers();
		headers.append("Content-Type", "application/json");

		fetch("/accounts/auth/", {
			method: "POST",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => {
				return response.json();
			})
			.then(data => {
				if (data.access_token) {
					localStorage.setItem("access_token", data.access_token);
					localStorage.setItem("address", data.address);
					localStorage.setItem("email_auth", username);
					window.__damage_onCustodialLoginSuccess(data.access_token);

				} else {
					showConnectStatus("Login Failed!", "failed");
				}
			})
			.catch(error => {
				console.error("Error:", error);
			});
		event.preventDefault();
		return;
	});
	document.getElementById('connect-wallet-now')?.addEventListener('click', async (ev) => {
        ev.preventDefault();
		const btn = ev.currentTarget;
		const prev = btn.textContent;
		btn.disabled = true; btn.textContent = 'Connecting…';

		const r = await window.connectWalletUnified({ prompt: true, prefer: ['smart','browser','getter'] });
		if (r.ok) {
			const sel = document.getElementById('walletSelector');
			if (sel) {
				sel.value = 'extension';
				TokenManager.setMode(sel.value);
				sel.dispatchEvent(new Event('change', { bubbles: true }));
			}
			if (typeof updateWalletSummary === 'function') await updateWalletSummary();
			if (window.MicroModal) try { MicroModal.close('connect-wallet-modal'); } catch {}
			document.dispatchEvent(new CustomEvent('wallet:connected', { detail: r }));
			window.__damage_onExtensionAuthSuccess(sel.value);
		} else {
			console.error('Wallet connect failed:', r.error);
			btn.textContent = 'Retry Connect';
		}
		btn.disabled = false;
		if (btn.textContent !== 'Retry Connect') btn.textContent = prev;
	});



});

