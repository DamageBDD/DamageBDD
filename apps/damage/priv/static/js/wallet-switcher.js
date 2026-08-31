import * as wallet from "/static/js/wallet.js";
const DAMAGE_CONTRACT_ID = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk';

// ---- Damage Auth Token Manager --------------------------------------------
const AUTH_KEYS = {
	activeMode: 'active_auth_mode',                 // 'custodial' | 'extension'
	activeToken: 'access_token',                    // <-- the key your app already uses
	custToken:  'access_token_custodial',
	extToken:   'access_token_extension',
	custAddress:  'custodial_address',
	extAddress:   'extension_address',
	email:      'damage_email'                     // optional convenience
};

const TokenManager = {
	getMode() { return localStorage.getItem(AUTH_KEYS.activeMode) || 'custodial'; },
	getEmail() { return localStorage.getItem(AUTH_KEYS.email) ; },
	setMode(mode) { localStorage.setItem(AUTH_KEYS.activeMode, mode); },
	setEmail(email) { localStorage.setItem(AUTH_KEYS.email, email); },
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
	on_custodial_login(address, email, access_token){
		var mode = "custodial";
		this.setAddress(address, mode);
		this.setToken(mode, access_token);
		this.setEmail(email);
		this.activate(mode);
	},


	logout(mode) {
		if (!mode || mode === 'custodial') {
			localStorage.removeItem(AUTH_KEYS.custToken);
			localStorage.removeItem(AUTH_KEYS.custAddress);
			localStorage.removeItem(AUTH_KEYS.email);
		}
		if (!mode || mode === 'extension') {
			localStorage.removeItem(AUTH_KEYS.extToken);
			localStorage.removeItem(AUTH_KEYS.extAddress);
		}

		if (!mode) localStorage.removeItem(AUTH_KEYS.activeToken);
	}
};
window.TokenManager = TokenManager;
// helpers (put near the top of the module)
function b64urlEncode(bytes) {
	const bin = typeof bytes === "string"
		  ? bytes
		  : String.fromCharCode(...(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)));
	return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function utf8ToBytes(s) {
	return new TextEncoder().encode(s);
}

function randomNonceHex(len = 16) {
	const b = new Uint8Array(len);
	crypto.getRandomValues(b);
	return [...b].map(x => x.toString(16).padStart(2, "0")).join("");
}

/**
 * Tries to sign a message using whatever your unified wallet connector exposes.
 * You may need to adapt ONE place here depending on what connectWalletUnified returns.
 */
async function signMessageUnified(message, addressHint) {
	// Preferred: unified global (if you already have it)
	if (typeof window.signMessageUnified === "function") {
		return await window.signMessageUnified({ message, address: addressHint });
	}


	if (typeof wallet.signMessageSmart === "function") {
		const r = await wallet.signMessageSmart(message);
		// normalize
		return { signature: r.result.signature};
	}

	throw new Error("No message signing method available (unified/smart wallet signer not found).");
}

async function createSignedAccessToken(address, ttlSeconds = 3600) {
	const now = Math.floor(Date.now() / 1000);

	const payload = {
		typ: "damage-access",
		v: 1,
		sub: address,
		iat: now,
		exp: now + ttlSeconds,
		nonce: randomNonceHex(16),
		aud: window.location.host,
	};

	const payloadJson = JSON.stringify(payload);
	const payloadB64 = b64urlEncode(utf8ToBytes(payloadJson));

	const messageToSign = `DamageBDD Access Token\n${payloadB64}`;

	const signed = await signMessageUnified(messageToSign, address);

	// normalize signature
	const signature =
		  (typeof signed === "string" ? signed :
		   signed?.signature ?? signed?.sig ?? signed?.signed ?? "");

	if (!signature || typeof signature !== "string") {
		throw new Error("Wallet did not return a signature string");
	}

	// If it's AE-style (sg_), keep as-is.
	// If your wallet returns some other format later, we can add branches.
	return `ae1.${payloadB64}.${signature}`;
}

// ----------------------------------------------------------------------------
document.addEventListener('DOMContentLoaded', () => {

	const selector = document.getElementById('walletSelector');
	const balanceAmount = document.getElementById('balanceAmount');

	// set initial selector value to previously-active mode
	selector.value = TokenManager.getMode();

	// ensure the canonical access_token matches the selected mode on page load
	TokenManager.activate(selector.value);

	selector.addEventListener('change', () => onWalletChange(selector.value)); //.catch(console.error));
	selector.style.display ='none';

	initWalletSelector().then(updateWalletSummary);

	const CONNECT_BTN_SELECTOR = [
		'#connect-button',
		'#connectWalletBtn',
		'[data-connect-wallet]',
		'#loginBtn.connect-wallet'
	].join(',');


	// ---- your function with token included ----
	async function connectViaUnified(btn) {
		const prev = btn.textContent;
		btn.disabled = true;
		btn.textContent = 'Connecting…';

		try {
			const res = await window.connectWalletUnified({ prompt: true, prefer: ['smart','browser','getter'] });
			if (res.ok) {
				const sel = document.getElementById('walletSelector');
				if (sel) { sel.value = 'extension'; sel.dispatchEvent(new Event('change', { bubbles: true })); }

				TokenManager.setModeAddress("extension", res.address);

				const accessToken = await createSignedAccessToken(res.address, 3600);
				TokenManager.setToken("extension", accessToken);
				TokenManager.activate("extension");

				window.__damage_access_token = accessToken;

				document.dispatchEvent(new CustomEvent("wallet:connected", {
					detail: { ...res, accessToken }
				}));

				try { MicroModal.close("connect-wallet-modal"); } catch (_e) {}
				try { MicroModal.close("login-modal"); } catch (_e) {}

				const content = document.getElementById("content");
				if (content) content.style.display = "block";

				await refreshAfterAuthChange();
			} else {
				console.error('Wallet connect failed:', res.error);
				btn.textContent = 'Retry Connect';
				return;
			}
		} catch (e) {
			console.error('Wallet connect threw:', e);
			btn.textContent = 'Retry Connect';
			return;
		} finally {
			btn.disabled = false;
			if (btn.textContent !== 'Retry Connect') btn.textContent = prev;
		}
	}


	function bindLoginConnectButton(root = document) {
		const nodes = Array.from(root.querySelectorAll(CONNECT_BTN_SELECTOR))
			  .filter(el => !el.dataset.wcBound);
		nodes.forEach(btn => {
			btn.addEventListener('click', (ev) => {
				ev.preventDefault();
				connectViaUnified(btn);
			});
			btn.dataset.wcBound = '1';
		});
	}

	async function ensureExtensionToken() {
		const r = await window.connectWalletUnified({ prompt: true, prefer: ['smart','browser','getter'] });
		if (!r.address) {
			MicroModal.show("connect-wallet-modal");
			return undefined;
		}

		let extTok = TokenManager.getToken("extension");
		if (!extTok) {
			extTok = await createSignedAccessToken(r.address, 3600);
			TokenManager.setToken("extension", extTok);
		}
		TokenManager.setModeAddress("extension", r.address);
		TokenManager.activate("extension");
		return r.address;
	}


	async function onWalletChange(mode) {
		let address = TokenManager.getAddress(mode);
		console.log("onwalletchange ", address);

		if (mode === "extension") {
			let extTok = TokenManager.getToken("extension");

			if (!address || !extTok) {
				address = await ensureExtensionToken();
			}
			if (!address) return;

			TokenManager.activate("extension");
			TokenManager.setAddress(address, "extension");
		} else {
			let custTok = TokenManager.getToken("custodial");
			address = TokenManager.getAddress("custodial");

			if (!custTok || !address) {
				if (window.MicroModal) MicroModal.show("email-login-modal");
				return;
			}

			TokenManager.activate("custodial");
			TokenManager.setAddress(address, "custodial");
		}

		await refreshAfterAuthChange();
	}


	async function updateWalletSummary() {
		var balanceAmountId = 'balanceAmount';
		var aeBalanceId = 'aeBalance';
		var addressId = 'damage-address';

		const balanceAmountEl = document.getElementById(balanceAmountId);
		if(!balanceAmountEl)return;
		const aeBalanceEl = document.getElementById(aeBalanceId);
		const addressInput = document.getElementById(addressId);
		var address = TokenManager.getAddress();
		var addressEl = document.getElementById("balanceAddress");
		if(!address && TokenManager.getMode()=="extension"){
			address = await ensureExtensionToken();
		}
		if(!address){
			balanceAmountEl.textContent = '…';
			aeBalanceEl.textContent = '…';
			return;
		}
		console.log("updateWalletSummary ", address);

		var damageAddr = document.getElementById("damage-address");
		damageAddr.value = address;

		if(!window.fetchAeAndAex9Balances)return;
		try {
			const res = await window.fetchAeAndAex9Balances(address);
			console.log("damage balances (raw)", res);

			// --- Validate structure ---
			const ok =
				  res &&
				  typeof res === "object" &&
				  res.damage &&
				  typeof res.damage.damage !== "undefined" &&
				  res.ae &&
				  typeof res.ae.ae !== "undefined";

			if (!ok) {
				console.warn("Invalid balance result", res);

				balanceAmountEl.textContent = "—";
				aeBalanceEl.textContent = "—";
				addressInput.textContent = address + " (no data)";
				addressInput.value = address + " (no data)";
				return;
			}

			// --- Set balances safely ---
			const dmg = String(res.damage.damage ?? "0");
			const ae  = String(res.ae.ae ?? "0");

			balanceAmountEl.textContent = dmg;
			aeBalanceEl.textContent     = ae;
			addressInput.value          = address;
			addressEl.textContent       = address;

			return;

		} catch (err) {
			console.error("Failed to load balances", err);

			balanceAmountEl.textContent = "ERR";
			aeBalanceEl.textContent     = "ERR";
			addressEl.textContent       = address + " (error)";
			addressInput.value       = address + " (error)";
			return;
		}

	}


	// --- wallet helpers (same as before, trimmed for brevity) ---
	async function initWalletSelector(){
		/* detect wallet, label options, etc. */
	}

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
			credentials: "include",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => response.json())
			.then(async data => {
				if (data.access_token) {
					TokenManager.on_custodial_login(data.address, data.email, data.access_token);
					TokenManager.activate("custodial");

					try { MicroModal.close("email-login-modal"); } catch (_e) {}
					try { MicroModal.close("login-modal"); } catch (_e) {}

					await refreshAfterAuthChange();
				} else {
					showConnectStatus("Login Failed!", "failed");
				}
			});
		
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

	bindLoginConnectButton();

	const div = document.getElementById('balanceDiv');

	let btn = document.getElementById('balanceRefreshBtn');
	if(btn){
		btn.addEventListener('click', refresh);
	async function refresh(ev) {
        ev.preventDefault();
		btn.setAttribute('aria-busy', 'true');
		try {
			await updateWalletSummary();
			// also emit a simple event some modules may listen for
			document.dispatchEvent(new Event('balance:refresh'));
		} catch (e) {
			console.error('[balance] refresh failed:', e);
		} finally {
			btn.removeAttribute('aria-busy');
		}
	}
	// If your balances.js fires this when done, spinner will also stop immediately.
	document.addEventListener('balance:updated', () => {
		btn && btn.removeAttribute('aria-busy');
	});
	}






	window.updateWalletSummary = updateWalletSummary;
	async function refreshAfterAuthChange() {
		try {
			await updateWalletSummary();
		} catch (e) {
			console.error("updateWalletSummary failed:", e);
		}

		try {
			document.dispatchEvent(new Event("balance:refresh"));
		} catch (e) {
			console.error("balance refresh event failed:", e);
		}

		try {
			document.dispatchEvent(new CustomEvent("auth:changed", {
				detail: {
					mode: TokenManager.getMode(),
					address: TokenManager.getAddress(),
					token: TokenManager.getToken()
				}
			}));
		} catch (e) {
			console.error("auth changed event failed:", e);
		}
	}
	window.refreshAfterAuthChange = refreshAfterAuthChange;

	async function logoutActiveSession() {
		const mode = TokenManager.getMode();
		const token = TokenManager.getToken(mode);

		const headers = new Headers();
		headers.set("Content-Type", "application/json");
		headers.set("Accept", "application/json");
		if (token) headers.set("Authorization", "Bearer " + token);

		try {
			await fetch("/accounts/logout", {
				method: "POST",
				credentials: "include",
				headers,
				body: JSON.stringify({})
			});
		} catch (e) {
			console.warn("Server logout failed:", e);
		}

		TokenManager.logout(mode);
		localStorage.removeItem(AUTH_KEYS.activeToken);

		try {
			document.dispatchEvent(new CustomEvent("auth:changed", {
				detail: { mode: null, address: null, token: null }
			}));
		} catch (_e) {}

		await refreshAfterAuthChange();
	}
	window.logoutActiveSession = logoutActiveSession;

});
