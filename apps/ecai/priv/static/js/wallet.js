import * as sk from "./sidekick.js";
var logged_in = false;
var address ;
// Superhero Wallet Integration Utilities
function connect(logger) {
    return sk.connect(

        'ske-connect-1',
        {name: 'staging.damagebdd.com',
         version: 1},
        sk.TIMEOUT_DEF_CONNECT_MS,
        "failed to connect to wallet",
        logger
    );
}

function encodeParams(params) {
    return Object.entries(params)
        .map(([key, val]) => `${encodeURIComponent(key)}=${encodeURIComponent(val)}`)
        .join("&");
}

export function connectWallet(successURL, cancelURL) {
    const params = {
        "x-success": successURL + "?address={address}&networkId={networkId}",
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/address?${encodeParams(params)}`;
}

export function signMessage(message, successURL, cancelURL, encoding = "hex") {
    const params = {
        message,
        encoding,
        "x-success": `${successURL}?signature={signature}&address={address}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-message?${encodeParams(params)}`;
}

export function signTransaction(transaction, networkId, successURL, cancelURL, broadcast = true) {
    const params = {
        transaction,
        networkId,
        broadcast: broadcast.toString(),
        "x-success": `${successURL}?transaction-hash={transaction-hash}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-transaction?${encodeParams(params)}`;
}

export function signJWT(payload, successURL, cancelURL) {
    const params = {
        payload,
        "x-success": `${successURL}?signed-payload={signed-payload}&address={address}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-jwt?${encodeParams(params)}`;
}



// Usage:
// connectWallet('https://yourapp.com/success', 'https://yourapp.com/cancel')
// signMessage('hello', 'https://yourapp.com/msg-ok', 'https://yourapp.com/msg-fail')
function isMobileDevice() {
    return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
}
export async function connectWalletSmart(successURL, cancelURL) {
    if (isMobileDevice()) {
        // Use Superhero mobile wallet deep link
        connectWallet(successURL, cancelURL);
    } else {
        // Use Sidekick browser wallet connection
        return await connectButton();
    }
}
export function signMessageSmart(message, successURL, cancelURL) {
    if (isMobileDevice()) {
        signMessage(message, successURL, cancelURL);
    } else {
    //const sigData = await sk.msg_sign(msg); // Sidekick signs message
    let logger = sk.cl();
    return sk.msg_sign('sk-msg-sign-1', address, message, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
   // if(!sigData.ok){
   //     await connectWalletSmart1();
   //     sigData = await sk.msg_sign('sk-msg-sign-1', address, msg, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
   // }
        //sk.signMessage(message).then(({ signature, address }) => {
        //    window.location.href = `${successURL}?signature=${signature}&address=${address}`;
        //}).catch(() => {
        //    window.location.href = cancelURL;
        //});
    }
}
export function signTransactionSmart(message, successURL, cancelURL) {
	if (isMobileDevice()) {
		signTransaction(message, successURL, cancelURL);
	} else {
		//const sigData = await sk.msg_sign(msg); // Sidekick signs message
		let sign_params = {
			tx: message,
			// returnsigned: false tells it to propagate the transaction
			// returnsigned: true just signs it and returns the signed tx back
			returnSigned: true ,
			networkId: "ae_mainnet"
		};
		let logger = sk.cl();
		return sk.tx_sign_noprop('sk-tx-sign-noprop-1', sign_params, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
	}
}
export function checkWalletSignature(required = true) {
    const params = new URLSearchParams(window.location.search);
    const signature = params.get("signature");
    if (signature) {
        console.log("✅ Wallet signature found:", signature);
        return signature;
    }
    return null;
}
export function checkWalletAddress(required = true) {
    const params = new URLSearchParams(window.location.search);
    const user_address = params.get("address");
    const signature = params.get("signature");

    if (user_address) {
        console.log("✅ Wallet address found:", user_address);
        return user_address;
    }
    return null;
}
export function getAddress(){
    if(address)
        return address;
    else checkWalletAddress();
}

// Keep this near the top of the file (or right above fetchWalletBalance)
const DAMAGE_CONTRACT_ID = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk';

export async function fetchWalletBalance(publicKey) {
	const balanceDiv = document.getElementById('wallet-balance');
	if (!balanceDiv) return;

	balanceDiv.innerHTML = '<em>Loading…</em>';

	try {
		// Prefer the shared helper from balances.js if present
		if (typeof fetchAeAndAex9Balances === 'function') {
			const r = await fetchAeAndAex9Balances(publicKey);
			const dmg = (r.aex9 || []).find(t =>
				(t.token_hash || t.contract_id || t.contract) === DAMAGE_CONTRACT_ID
			);

			const aeText   = r?.ae?.ae ?? '—';
			const dmgText  = dmg ? (dmg.amount ?? '0') : '0';

			const ul = document.createElement('ul');
			ul.innerHTML = `
        <li>Account: <code><strong>${publicKey}</strong></code></li>
        <li>DAMAGE: <code>${dmgText}</code></li>
        <li>AE: <code>${aeText}</code></li>
      `;
			balanceDiv.innerHTML = '';
			balanceDiv.appendChild(ul);
			balanceDiv.style.display = 'block';
			return;
		}

		// Fallback: keep the older contract-specific MDW query
		const url = "https://mainnet.aeternity.io/mdw/v3/aex9/"
			  + DAMAGE_CONTRACT_ID + "/balances/" + publicKey;
		const response = await fetch(url);
		const data = await response.json();

		balanceDiv.innerHTML = '';
		const amount = Number(data.amount || 0);
		if (!amount) {
			balanceDiv.innerHTML = `<blockquote>⚡ Your DAMAGE balance is too low to execute tests.
      Balance: 0. Please generate/transfer tokens to your wallet from an exchange.</blockquote>`;
			const amountSelector = document.getElementById("amount-selector");
			if (amountSelector) amountSelector.style.display = 'block';
			return;
		}

		const ul = document.createElement('ul');
		ul.innerHTML = `
      <li>Account: <code><strong>${data.account || publicKey}</strong></code></li>
      <li>DAMAGE: <code>${amount.toFixed(8)}</code></li>
    `;
		balanceDiv.appendChild(ul);
		balanceDiv.style.display = 'block';

	} catch (e) {
		console.error('fetchWalletBalance error', e);
		balanceDiv.textContent = 'Failed to load balance';
	}
}


async function connectButton() {
    let logger = sk.cl();

    await connect(logger);
    let wallet_info = await sk.address(
        'ske-address-1',
        {type: 'subscribe',
         value: 'connected'},
        10000,
        "failed to address to wallet",
        logger
    );
    if (!wallet_info.ok){
        console.log("wallet info:", wallet_info);
        if(wallet_info.error.code == 420){
            document.getElementById("connect-status").innerHTML = "Please install <a href='https://chrome.google.com/webstore/detail/superhero/mnhmmkepfddpifjkamaligfeemcbhdne'>superhero wallet</a> to connect" ;
        }else{
            document.getElementById("connect-status").innerHTML = "Error connecting wallet " + wallet_info.error.message;
        }
        return;
    }

    let maybe_address = Object.keys(wallet_info.result.address.current)[0];
    if (maybe_address === undefined) return;

    address = maybe_address;
    logged_in = true;
	document.getElementById("connect-button").disabled = true;
	document.getElementById("connect-button").style.display = 'none';
	return maybe_address;
    //fetchWalletBalance(address);
}
/* wallet.js — unified connector with console-friendly debugging */
(function (g) {
	'use strict';
	const W = g.wallet || (g.wallet = {});
	const isFn = (x) => typeof x === 'function';

	// Keep the last errors so you can inspect from DevTools
	W._lastErrors = [];

	// Extract an address from many possible shapes
	function extractAddress(res) {
		if (!res) return null;
		if (typeof res === 'string') return res;
		if (typeof res.address === 'string') return res.address;
		if (typeof res.addr === 'string') return res.addr;
		if (res.account && typeof res.account.address === 'string') return res.account.address;
		if (Array.isArray(res.accounts)) {
			const a0 = res.accounts[0];
			if (typeof a0 === 'string') return a0;
			if (a0 && typeof a0.address === 'string') return a0.address;
		}
		if (res.payload && typeof res.payload.address === 'string') return res.payload.address;
		return null;
	}

	async function tryStep(name, fn, opts) {
		// Call style adapts to the connector's arity:
		//  - 2+ params: (prompt, opts)
		//  - 1 param:   (opts)
		//  - 0 param:   ()
		const arity = typeof fn === 'function' ? fn.length : 0;
		let raw;
		if (arity >= 2)      raw = await fn(opts.prompt, opts);
		else if (arity === 1) raw = await fn(opts);
		else                  raw = await fn();

		const address = extractAddress(raw);
		if (!address) {
			throw new Error(`${name} returned no address`);
		}
		return { ok: true, address, provider: name, raw };
	}


	/**
	 * wallet.connectUnified(opts)
	 *  - prompt: boolean (default true)   allow wallet UI prompts
	 *  - prefer: array|string             order to try: 'smart' | 'browser' | 'getter'
	 *  - debug:  boolean (default true)   log to console for easy testing
	 * Returns: { ok, address?, provider?, error?, raw? }
	 */
	W.connectUnified = async function connectUnified(opts = {}) {
		const { prompt = true, prefer = ['smart','browser','getter'], debug = true } = opts;
		const order = Array.isArray(prefer) ? prefer : [prefer];

		const steps = [];
		if (order.includes('smart') && isFn(connectWalletSmart)) {
			steps.push(() => tryStep('connectWalletSmart', connectWalletSmart, opts));
		}
		if (order.includes('browser')) {
			if (isFn(g.connectBrowserWallet)) {
				steps.push(() => tryStep('connectBrowserWallet', g.connectBrowserWallet, opts));
			}
			if (W && isFn(W.connect)) { // if you already expose wallet.connect somewhere
				steps.push(() => tryStep('wallet.connect', W.connect.bind(W), opts));
			}
			if (isFn(g.requestWalletConnection)) {
				steps.push(() => tryStep('requestWalletConnection', g.requestWalletConnection, opts));
			}
			if (isFn(g.aeConnect)) {
				steps.push(() => tryStep('aeConnect', g.aeConnect, opts));
			}
		}
		if (order.includes('getter') && isFn(g.getBrowserWalletAddress)) {
			steps.push(async () => {
				const addr = await g.getBrowserWalletAddress(!!prompt);
				if (!addr) throw new Error('getBrowserWalletAddress returned no address');
				return { ok: true, address: addr, provider: 'getBrowserWalletAddress', raw: addr };
			});
		}

		if (debug) console.log('[wallet] connectUnified start', { prompt, prefer: order });

		const errors = [];
		for (const step of steps) {
			try {
				const r = await step();
				if (debug) console.log('[wallet] connected via', r.provider, '→', r.address);
				return r;
			} catch (e) {
				const msg = e?.message || String(e);
				errors.push({ provider: (await step).name || 'step', error: msg }); // name best-effort
				if (debug) console.warn('[wallet] step failed:', msg);
			}
		}

		const reason = errors.map(e => (e.provider ? e.provider + ': ' : '') + e.error).join('; ');
		W._lastErrors = errors;
		if (debug) console.error('[wallet] connectUnified failed:', reason || 'No connector available');

		return { ok: false, error: reason || 'No wallet connector available' };
	};

	// Handy console helpers (so you can test quickly)
	W.debug = {
		connect: (o={}) => W.connectUnified({ debug: true, ...o }),
		getAddr: (prompt=true) =>
		isFn(g.getBrowserWalletAddress) ? g.getBrowserWalletAddress(prompt) : 'no getBrowserWalletAddress()',
		lastErrors: () => (W._lastErrors || []).slice(),
		extractAddress // expose for quick manual parsing in console
	};

	// Optional global alias to keep older callers working
	g.connectWalletUnified = (...a) => W.connectUnified(...a);

})(typeof globalThis !== 'undefined' ? globalThis
   : typeof window !== 'undefined' ? window
   : typeof self !== 'undefined' ? self
   : this);


