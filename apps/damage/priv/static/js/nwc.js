// /static/js/nwc.js
// NWC Connect dialog glue for DamageBDD.
// Requires: MicroModal, QRCode, TokenManager.
const NWC_CACHE_TTL_MS = 6 * 60 * 60 * 1000;

function authHeaders() {
	const token = window.TokenManager && window.TokenManager.getToken ? window.TokenManager.getToken() : null;
	const headers = new Headers();
	headers.set("content-type", "application/json");
	headers.set("accept", "application/json");
	if (token) headers.set("Authorization", "Bearer " + token);
	return headers;
}

function qs(id) {
	const el = document.getElementById(id);
	if (!el) throw new Error(`Missing element #${id}`);
	return el;
}

function maybe(id) {
	return document.getElementById(id);
}

function setStatus(msg, type = "info") {
	const el = maybe("nwc-status");
	if (!el) return;
	el.textContent = msg || "";
	el.classList.remove("is-success", "is-error");
	if (type === "success") el.classList.add("is-success");
	if (type === "error") el.classList.add("is-error");
}

function clearQr() {
	const qr = maybe("nwc-qr");
	if (qr) qr.innerHTML = "";
}

function setResultVisible(visible) {
	const empty = maybe("nwc-empty-state");
	const body = maybe("nwc-result-body");
	if (empty) empty.hidden = !!visible;
	if (body) body.hidden = !visible;
}

function renderQr(text) {
	clearQr();
	const mount = maybe("nwc-qr");
	if (!mount || !text) return;

	// QRCode is loaded globally from /static/js/qrcode.min.js
	// eslint-disable-next-line no-undef
	new QRCode(mount, {
		text,
		width: 190,
		height: 190,
		correctLevel: QRCode.CorrectLevel.M
	});
}

function canonicalRelay(url) {
	const trimmed = String(url || "").trim();
	if (!trimmed) return "";
	return trimmed.replace(/\/+$/, "").toLowerCase();
}

function uniqueRelays(relays) {
	const seen = new Set();
	const out = [];

	for (const relay of relays.map(canonicalRelay).filter(Boolean)) {
		if (!relay.startsWith("ws://") && !relay.startsWith("wss://")) continue;
		if (seen.has(relay)) continue;

		seen.add(relay);
		out.push(relay);
	}

	return out;
}

function customRelays() {
	const el = maybe("nwc-custom-relays");
	if (!el) return [];
	return el.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
}

function selectedPresetRelays() {
	return Array.from(document.querySelectorAll(".nwc-relay-preset:checked")).map((el) => el.value);
}

function selectedRelays() {
	const presets = selectedPresetRelays();
	const custom = customRelays();

	if (presets.length || custom.length) {
		return uniqueRelays([...presets, ...custom]);
	}

	const oldRelay = maybe("nwc-relay");
	return oldRelay ? uniqueRelays([oldRelay.value]) : [];
}

function updateRelayCount() {
	const countEl = maybe("nwc-relay-count");
	const relays = selectedRelays();

	if (!countEl) return relays;

	if (relays.length < 3) {
		countEl.textContent = `Using ${relays.length} relay${relays.length === 1 ? "" : "s"}. Pick at least 3.`;
		countEl.style.color = "#fcd34d";
	} else if (relays.length > 5) {
		countEl.textContent = `Using ${relays.length} relays. Keep it to 3–5 for reliable overlap.`;
		countEl.style.color = "#fcd34d";
	} else {
		countEl.textContent = `Using ${relays.length} relays.`;
		countEl.style.color = "";
	}

	return relays;
}

function clearLastConnection() {
	try {
		localStorage.removeItem("damage.nwc.last");
	} catch (_) {}
}

function storeLastConnection(data) {
	if (!data || data.status !== "ok" || data.usable !== true || !data.nwc_uri) return;

	try {
		localStorage.setItem("damage.nwc.last", JSON.stringify({
			ts: Date.now(),
			status: data.status,
			usable: data.usable,
			client_pubkey: data.client_pubkey,
			nwc_uri: data.nwc_uri,
			wallet_pubkey: data.wallet_pubkey,
			relays: data.relays || []
		}));
	} catch (_) {}
}

function loadLastConnection() {
	try {

		const raw = localStorage.getItem("damage.nwc.last");
		if (!raw) return null;

		const data = JSON.parse(raw);
		if (!data) {
			clearLastConnection();
			return null;
		}

		const stale = !data.ts || Date.now() - data.ts > NWC_CACHE_TTL_MS;

		if (
			stale ||
				!data ||
				data.status !== "ok" ||
				data.usable !== true ||
				!data.nwc_uri
		) {
			clearLastConnection();
			return null;
		}	

		return data;
	} catch (_) {
		clearLastConnection();
		return null;
	}
}

async function postJson(url, bodyObj) {
	const resp = await fetch(url, {
		method: "POST",
		headers: authHeaders(),
		body: JSON.stringify(bodyObj || {})
	});

	const text = await resp.text();
	let data = null;

	try {
		data = text ? JSON.parse(text) : null;
	} catch (_) {}

	if (!resp.ok) {
		const msg = data ? JSON.stringify(data) : text || resp.statusText;
		const err = new Error(`HTTP ${resp.status}: ${msg}`);
		err.status = resp.status;
		err.data = data;
		throw err;
	}

	return data;
}

function setMintBusy(busy) {
	const btn = maybe("nwc-mint-btn");
	if (!btn) return;

	btn.disabled = !!busy;
	btn.textContent = busy ? "Minting…" : "Mint NWC";
}

function hydrateConnection(data) {
	qs("nwc-uri").value = data.nwc_uri || "";
	qs("nwc-client-pubkey").value = data.client_pubkey || "";
	renderQr(data.nwc_uri || "");
	setResultVisible(true);
}

function lockNwcScroll() {
	document.documentElement.classList.add("nwc-modal-open");
	document.body.classList.add("nwc-modal-open");
}

function unlockNwcScroll() {
	document.documentElement.classList.remove("nwc-modal-open");
	document.body.classList.remove("nwc-modal-open");
}

export function openNwcModal() {
	updateRelayCount();

	const last = loadLastConnection();
	if (last) {
		try {
			hydrateConnection(last);
			setStatus("Loaded last usable NWC connection.");
		} catch (_) {}
	} else {
		setResultVisible(false);
		setStatus("");
	}

	lockNwcScroll();

	if (window.MicroModal) {
		window.MicroModal.show("nwc-modal", {
			disableScroll: true,
			awaitOpenAnimation: false,
			awaitCloseAnimation: false,
			onClose: unlockNwcScroll
		});
	}
}

export function closeNwcModal() {
	unlockNwcScroll();

	if (window.MicroModal) {
		window.MicroModal.close("nwc-modal");
	}
}

export async function mintNwc() {
	const relays = updateRelayCount();

	if (relays.length < 3 || relays.length > 5) {
		setStatus("Pick 3–5 relays so clients and listener have reliable overlap.", "error");
		return;
	}

	setMintBusy(true);
	setStatus("Minting fresh NWC connection…");
	qs("nwc-uri").value = "";
	qs("nwc-client-pubkey").value = "";
	clearQr();
	setResultVisible(false);

	const maxSingleSat = Number(qs("nwc-max-single").value || "0");
	const maxTotalSat = Number(qs("nwc-max-total").value || "0");
	const expiresHeight = Number(qs("nwc-expires-height").value || "0");

	try {
		const data = await postJson("/api/nwc/mint", {
			relays,
			relay: relays[0],

			max_single_sat: maxSingleSat,
			max_single_sats: maxSingleSat,

			max_total_sat: maxTotalSat,
			max_total_sats: maxTotalSat,

			expires_height: expiresHeight
		});

		if (!data || data.status !== "ok" || data.usable !== true || !data.nwc_uri) {
			clearLastConnection();
			qs("nwc-client-pubkey").value = data?.client_pubkey || "";

			const reason = data?.error || data?.status || "mint_not_ready";
			setStatus(`NWC mint not usable yet: ${reason}`, "error");
			console.warn("NWC mint returned non-usable response", data);
			return;
		}

		hydrateConnection(data);
		storeLastConnection(data);
		setStatus("Minted. Scan the QR or copy the URI into your wallet client.", "success");
	} finally {
		setMintBusy(false);
	}
}
function clearConnectionView() {
	const uri = maybe("nwc-uri");
	const pubkey = maybe("nwc-client-pubkey");

	if (uri) uri.value = "";
	if (pubkey) pubkey.value = "";

	clearQr();
	setResultVisible(false);
}
export async function revokeNwc() {
	const clientPubkey = qs("nwc-client-pubkey").value.trim();

	if (!clientPubkey || clientPubkey.length < 64) {
		setStatus("Mint or paste a client pubkey before revoking.", "error");
		return;
	}

	setStatus("Revoking connection…");
	await postJson("/api/nwc/revoke", { client_pubkey: clientPubkey });
	clearLastConnection();
	clearConnectionView();
	setStatus("Revoked.", "success");
}

export async function copyUri() {
	const uri = qs("nwc-uri").value.trim();

	if (!uri) {
		setStatus("Nothing to copy.", "error");
		return;
	}

	await navigator.clipboard.writeText(uri);
	setStatus("Copied URI to clipboard.", "success");
}

export function openInApp() {
	const uri = qs("nwc-uri").value.trim();

	if (!uri) {
		setStatus("No URI to open.", "error");
		return;
	}

	window.location.href = uri;
}

export function clearForm() {
	for (const checkbox of document.querySelectorAll(".nwc-relay-preset")) {
		const relay = canonicalRelay(checkbox.value);
		checkbox.checked =
			relay === "wss://relay.damus.io" ||
			relay === "wss://relay.primal.net" ||
			relay === "wss://nos.lol";
	}

	qs("nwc-max-single").value = "10";
	qs("nwc-max-total").value = "50";
	qs("nwc-expires-height").value = "0";
	qs("nwc-uri").value = "";
	qs("nwc-client-pubkey").value = "";

	const custom = maybe("nwc-custom-relays");
	if (custom) custom.value = "";

	setStatus("");
	clearQr();
	clearLastConnection();
	setResultVisible(false);
	updateRelayCount();
}

export function bindNwcUi() {
	const modal = maybe("nwc-modal");
	if (!modal || modal.dataset.nwcBound === "true") return;

	updateRelayCount();
	setResultVisible(!!qs("nwc-uri").value.trim());

	document.querySelectorAll(".nwc-relay-preset").forEach((el) => {
		el.addEventListener("change", updateRelayCount);
	});

	const custom = maybe("nwc-custom-relays");
	if (custom) custom.addEventListener("input", updateRelayCount);

	qs("nwc-mint-btn").addEventListener("click", async (e) => {
		e.preventDefault();
		try {
			await mintNwc();
		} catch (err) {
			setStatus(err.message || String(err), "error");
			setMintBusy(false);
		}
	});

	qs("nwc-revoke-btn").addEventListener("click", async (e) => {
		e.preventDefault();
		if (!confirm("Revoke this NWC connection? Clients using the URI will stop working.")) return;

		try {
			await revokeNwc();
		} catch (err) {
			setStatus(err.message || String(err), "error");
		}
	});

	qs("nwc-copy-btn").addEventListener("click", async (e) => {
		e.preventDefault();

		try {
			await copyUri();
		} catch (err) {
			setStatus(err.message || String(err), "error");
		}
	});

	qs("nwc-open-btn").addEventListener("click", (e) => {
		e.preventDefault();

		try {
			openInApp();
		} catch (err) {
			setStatus(err.message || String(err), "error");
		}
	});

	qs("nwc-clear-btn").addEventListener("click", (e) => {
		e.preventDefault();
		clearForm();
	});

	document.addEventListener("micromodal:show", (event) => {
		if (event.detail && event.detail.content && event.detail.content.id === "nwc-modal") {
			updateRelayCount();

			const uri = (maybe("nwc-uri")?.value || "").trim();
			setResultVisible(!!uri);

			if (uri) renderQr(uri);
		}
	});
	modal.dataset.nwcBound = "true";
	modal.addEventListener("click", (event) => {
		if (event.target && event.target.hasAttribute("data-micromodal-close")) {
			unlockNwcScroll();
		}
	});

	document.addEventListener("keydown", (event) => {
		if (event.key === "Escape" && modal.classList.contains("is-open")) {
			unlockNwcScroll();
		}
	});

}
window.NWC = {
	bindNwcUi,
	openNwcModal,
	closeNwcModal,
	mintNwc,
	revokeNwc,
	copyUri,
	openInApp,
	clearForm
};

window.openNwcModal = openNwcModal;

if (document.readyState === "loading") {
	document.addEventListener("DOMContentLoaded", bindNwcUi);
} else {
	bindNwcUi();
}
