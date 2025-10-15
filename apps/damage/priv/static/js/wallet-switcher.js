import * as wallet from "/static/js/wallet.js";
const DAMAGE_CONTRACT_ID = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk';

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
	setModeAddress(mode, address) {
		localStorage.setItem(AUTH_KEYS.activeMode, mode);
		localStorage.setItem(mode+"_address", address);
	},
	setAddress(address, mode=this.getMode()) {
		localStorage.setItem(mode+"_address", address); },
	getAddress(mode = this.getMode()) {
		return localStorage.getItem(mode + "_address");
	},

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


	logout(mode) {
		if (!mode || mode === 'custodial') localStorage.removeItem(AUTH_KEYS.custToken);
		if (!mode || mode === 'extension') localStorage.removeItem(AUTH_KEYS.extToken);
		if (!mode) localStorage.removeItem(AUTH_KEYS.activeToken);
	}
};
// ----------------------------------------------------------------------------
document.addEventListener('DOMContentLoaded', () => {

	const selector = document.getElementById('walletSelector');
	const balanceAmount = document.getElementById('balanceAmount');

	// set initial selector value to previously-active mode
	selector.value = TokenManager.getMode();

	// ensure the canonical access_token matches the selected mode on page load
	TokenManager.activate(selector.value);

	selector.addEventListener('change', () => onWalletChange(selector.value)); //.catch(console.error));

	initWalletSelector().then(updateWalletSummary);


	async function ensureExtensionToken() {
		// Non-custodial (browser wallet)
		const r = await window.connectWalletUnified({ prompt: true, prefer: ['smart','browser','getter'] });
		if (!r.address) {
			MicroModal.show('connect-wallet-modal');
			return undefined;
		}
		return r.address;
	}


	async function onWalletChange(mode) {
		var address = TokenManager.getAddress(mode);
		console.log("onwalletchange ", address);
		if (mode === 'extension') {
			// 1) make sure wallet is connected

			// 2) ensure an extension token exists (if not, do challenge/verify handshake)
			let extTok = TokenManager.getToken('extension');
			if (!extTok) { /* user cancelled */ return; }

			if(!address){
				address = await ensureExtensionToken(); // may open wallet to sign
			}
			if (!address) { /* user cancelled */ return; }

			// 3) swap active access_token
			TokenManager.activate(mode);
			TokenManager.setAddress(address);
		} else {
			// custodial: require login flow to set its token
			let custTok = TokenManager.getToken('custodial');
			address = TokenManager.getAddress('custodial');
			if (!custTok || !address) {
				if (window.MicroModal) MicroModal.show('email-login-modal');
				// your login handler should call `TokenManager.setToken('custodial', token); TokenManager.activate('custodial');`
				return;
			}
			TokenManager.activate('custodial');
			TokenManager.setAddress(address);
		}
		await updateWalletSummary();
	}

	// Call these from your existing login/connect flows:
	window.__damage_onCustodialLoginSuccess = function(token) {
		TokenManager.setToken('custodial', token);
		TokenManager.activate('custodial');
	};

	window.__damage_onExtensionAuthSuccess = function(token) {
		TokenManager.setToken('extension', token);
		TokenManager.activate('extension');
	};

	// Use this from wallet-switcher.js
	// Example: await updateWalletSummary();

	async function updateWalletSummary() {
		var address = TokenManager.getAddress();
		if(!address && TokenManager.getMode()=="extension"){
			address = await ensureExtensionToken();
		}
		if(!address){
			debugger;
			return;
		}
		console.log("updateWalletSummary ", address);
		var balanceAmountId = 'balanceAmount';
		var aeBalanceId = 'aeBalance';
		var addressId = 'balanceAddress';

		const balanceAmountEl = document.getElementById(balanceAmountId);
		const aeBalanceEl = document.getElementById(aeBalanceId);
		const addressEl = document.getElementById(addressId);

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


		const setAE = (valText) => {
			if (aeBalanceEl) aeBalanceEl.textContent = 'AE: ' + valText;
		};

		balanceAmountEl.textContent = '…';
		setAE('—');
		const damageBalance = await window.fetchAeAndAex9Balances(address);
		console.log("damage balances", damageBalance);
		balanceAmountEl.textContent = damageBalance.ae.ae; 
		setAE(damageBalance.ae.ae);
		debugger;
		addressEl.textContent = address;
		return;
	}


	// --- wallet helpers (same as before, trimmed for brevity) ---
	async function initWalletSelector(){ /* detect wallet, label options, etc. */ }

	function shortAddr(a){ return a ? (a.length>12 ? a.slice(0,6)+'…'+a.slice(-4) : a) : '—'; }
	function formatAmount(x){ if (x==null) return '—'; if (typeof x==='number') return x.toLocaleString(); if (/^\d+$/.test(String(x))) return Number(String(x)).toLocaleString(); return String(x); }

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
					TokenManager.setModeAddress("custodial", data.address);
					MicroModal.close("email-login-modal");

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
				TokenManager.setModeAddress("extension", r.address);
				sel.dispatchEvent(new Event('change', { bubbles: true }));
			}
			if (typeof updateWalletSummary === 'function') await updateWalletSummary();
			if (window.MicroModal) try { MicroModal.close('connect-wallet-modal'); } catch {}
			document.dispatchEvent(new CustomEvent('wallet:connected', { detail: r }));
			//window.__damage_onExtensionAuthSuccess(sel.value);
		} else {
			console.error('Wallet connect failed:', r.error);
			btn.textContent = 'Retry Connect';
		}
		btn.disabled = false;
		if (btn.textContent !== 'Retry Connect') btn.textContent = prev;
	});



});

