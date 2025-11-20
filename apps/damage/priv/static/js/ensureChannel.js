import * as wallet from "/static/js/wallet.js";
// ensureChannel.js
// Minimal deps: your existing wallet bridge with connectWalletUnified(), wallet.getActiveAccount(), wallet.signTransactionSmart()

/**
 * Find an open channel between `accountId` and `peerId` by:
 *  1) MDW: /mdw/v3/accounts/<accountId>/activities?limit=...&type=transactions&owned_only=true
 *  2) For each tx hash, load /mdw/v3/transactions/<hash> and keep channel_create_tx
 *  3) Extract channel_id (prefer the one MDW returns; otherwise skip)
 *  4) Node: /v3/channels/<channel_id>  → must be state=open AND participants match
 *
 * @param {string} nodeUrl   e.g. "https://mainnet.aeternity.io"
 * @param {string} mdwUrl    e.g. "https://mainnet.aeternity.io" (same host usually)
 * @param {string} accountId ak_...  (the wallet you control — initiator or responder)
 * @param {string} peerId    ak_...  (the counterparty)
 * @param {number} limit     how many recent txs to scan from MDW
 * @returns {Promise<object|null>} channel object or null
 */
async function findExistingChannel(nodeUrl, mdwUrl, accountId, peerId, limit = 25) {
	const fetchJSON = async (url) => {
		const r = await fetch(url, { method: "GET" });
		if (!r.ok) throw new Error(`${url} -> ${r.status}`);
		return r.json();
	};

	// 1) Pull recent tx activities owned by this account
	const actUrl =
		  `${mdwUrl}/mdw/v3/accounts/${accountId}/activities` +
		  `?limit=${encodeURIComponent(limit)}&type=transactions&owned_only=true`;

	const acts = await fetchJSON(actUrl);
	const data = Array.isArray(acts?.data) ? acts.data : [];

	// 2) For each activity, fetch full tx from MDW and pick channel_create_tx (+ channel_id)
	const channelIds = [];
	for (const a of data) {
		const type = a.payload.tx.type;
		if (type != 'ChannelCreateTx') continue;


		const chId =
			  a.payload.tx.channel_id ;

		// If MDW/node didn’t give channel_id, we skip (deriving it client-side is non-trivial).
		if (chId && chId.startsWith("ch_")) channelIds.push(chId);
	}

	// 3) Check each channel_id on the node and return the first OPEN match with the peer
	for (const chId of channelIds) {
		try {
			const ch = await fetchJSON(`${nodeUrl}/v3/channels/${chId}`);

			const init  = ch?.initiator_id;
			const resp  = ch?.responder_id;
			const isMatch =
				  (init === accountId && resp === peerId) ||
				  (init === peerId && resp === accountId);

			if (isMatch) return ch; // ✅ found open channel
		} catch {
			// ignore and continue
		}
	}

	return null; // nothing open we can reuse
}

/**
 * Post signed tx directly to node, fallback to server if CORS blocks it.
 */
async function postTx(nodeUrl, signedTx) {
	//try {
	//	const r = await fetch(`${nodeUrl}/v3/transactions`, {
	//		method: "POST",
	//		headers: { "Content-Type": "application/json" },
	//		body: JSON.stringify({ tx: signedTx })
	//	});
	//	const j = await r.json();
	//	if (!r.ok) throw j;
	//	return { status: "ok", tx_hash: j.tx_hash, via: "direct" };
	//} catch (e) {
		// Fallback: server relays to node
		const r2 = await fetch("/tx/", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ action: "submit_signed_tx", signed_tx: signedTx })
		});
		const j2 = await r2.json();
		if (j2.status !== "ok") throw j2;
		return { status: "ok", tx_hash: j2.tx_hash, via: "backend" };
	//}
}

/**
 * Ensure a channel exists; if not, create it.
 * @param {Object} opts
 * @param {string} opts.nodeUrl          e.g. "https://mainnet.aeternity.io"
 * @param {string} opts.responderId      ak_… (your node account)
 * @param {string|number} [opts.initiatorAmount="1000000000000000000"]
 * @param {string|number} [opts.responderAmount="1000000000000000000"]
 * @param {string|number} [opts.channelReserve="10000000000000000"]
 * @param {number}        [opts.lockPeriod=144]
 * @param {number}        [opts.ttl=0]
 * @param {string|number} [opts.fee="20000000000000"]
 * @param {boolean}       [opts.testnet=false]  // switches network id for signing
 *
 * @returns {Promise<{reuse:true,channel:any}|{reuse:false,tx_hash:string,via:'direct'|'backend'}>}
 */
export async function ensureChannel(opts) {
	const {
		nodeUrl,
		mdwUrl,
		responderId,
		initiatorAmount = "1000000000000000000",
		responderAmount = "1000000000000000000",
		channelReserve  = "10000000000000000",
		lockPeriod      = 144,
		ttl             = 0,
		fee             = "20000000000000",
		testnet         = false
	} = opts;

	if (!nodeUrl) throw new Error("nodeUrl required");
	if (!responderId) throw new Error("responderId (ak_…) required");

	// 1) connect wallet and get initiator
	await window.connectWalletUnified();
	const initiatorId = TokenManager.getAddress();  

	// 2) check if a channel already exists and is open
	const existing = await findExistingChannel(nodeUrl, mdwUrl, initiatorId, responderId);
	if (existing) {
		return { reuse: true, channel: existing };
	}

	// 3) prepare final *unsigned* tx on the server (server sets node as responder too if you want)
	const prepBody = {
		action: "prepare_create_channel",
		initiator_id:   initiatorId,
		initiator_amount: String(initiatorAmount),
		responder_amount: String(responderAmount),
		channel_reserve:  String(channelReserve),
		lock_period:      lockPeriod,
		ttl,
		fee: String(fee)
	};
	const prep = await fetch("/tx/", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(prepBody)
	}).then(r => r.json());

	if (prep.status !== "ok") {
		throw new Error(`prepare_create_channel failed: ${JSON.stringify(prep.error)}`);
	}

	// 4) sign the *final* unsigned tx with the wallet
	const networkId = testnet ? "ae_uat" : "ae_mainnet";
	const sig = await wallet.signTransactionSmart(
		prep.tx, networkId, window.location.origin, window.location.origin
	);
	if (!sig.ok) {
		throw new Error(sig.error?.message || "signing failed");
	}
	const signedTx = sig.result.signedTransaction; // "tx_..."

	// 5) post directly to node, fallback to backend relay
	const posted = await postTx(nodeUrl, signedTx);
	return { reuse: false, ...posted };
}
