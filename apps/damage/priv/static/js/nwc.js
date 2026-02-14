// /static/js/nwc.js
// NWC Connect dialog glue for DamageBDD.
// Requires: MicroModal, QRCode, TokenManager (already in your app).

function authHeaders() {
  const token = window.TokenManager && window.TokenManager.getToken ? window.TokenManager.getToken() : null;
  const headers = new Headers();
  headers.set("content-type", "application/json");
  if (token) headers.set("Authorization", "Bearer " + token);
  return headers;
}

function qs(id) {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing element #${id}`);
  return el;
}

function setStatus(msg, isError = false) {
  const el = document.getElementById("nwc-status");
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = isError ? "#ffb4b4" : "";
}

function clearQr() {
  const qr = document.getElementById("nwc-qr");
  if (qr) qr.innerHTML = "";
}

function renderQr(text) {
  clearQr();
  const mount = document.getElementById("nwc-qr");
  if (!mount || !text) return;
  // QRCode is loaded globally from /static/js/qrcode.min.js
  // eslint-disable-next-line no-undef
  new QRCode(mount, {
    text,
    width: 180,
    height: 180,
    correctLevel: QRCode.CorrectLevel.M
  });
}

function storeLastConnection(data) {
  try {
    localStorage.setItem("damage.nwc.last", JSON.stringify({
      ts: Date.now(),
      client_pubkey: data.client_pubkey,
      nwc_uri: data.nwc_uri,
      relay: data.relay,
      wallet_pubkey: data.wallet_pubkey
    }));
  } catch (_) {}
}

function loadLastConnection() {
  try {
    const raw = localStorage.getItem("damage.nwc.last");
    return raw ? JSON.parse(raw) : null;
  } catch (_) {
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
  try { data = text ? JSON.parse(text) : null; } catch (_) {}

  if (!resp.ok) {
    const msg = (data && (data.error || data.message)) ? JSON.stringify(data) : text || resp.statusText;
    throw new Error(`HTTP ${resp.status}: ${msg}`);
  }
  return data;
}

export function openNwcModal() {
  // Load last minted connection (nice UX)
  const last = loadLastConnection();
  if (last) {
    try {
      qs("nwc-uri").value = last.nwc_uri || "";
      qs("nwc-client-pubkey").value = last.client_pubkey || "";
      renderQr(last.nwc_uri || "");
    } catch (_) {}
  }
  setStatus("");
  if (window.MicroModal) window.MicroModal.show("nwc-modal");
}

export function closeNwcModal() {
  if (window.MicroModal) window.MicroModal.close("nwc-modal");
}

export async function mintNwc() {
  setStatus("Minting…");
  const relay = qs("nwc-relay").value.trim();
  const maxSingleSat = Number(qs("nwc-max-single").value || "0");
  const maxTotalSat = Number(qs("nwc-max-total").value || "0");
  const expiresHeight = Number(qs("nwc-expires-height").value || "0");

  if (!relay.startsWith("ws")) {
    setStatus("Relay must start with ws:// or wss://", true);
    return;
  }

  const data = await postJson("/api/nwc/mint", {
    relays: [relay],
    max_single_sat: maxSingleSat,
    max_total_sat: maxTotalSat,
    expires_height: expiresHeight
  });

  qs("nwc-uri").value = data.nwc_uri || "";
  qs("nwc-client-pubkey").value = data.client_pubkey || "";
  renderQr(data.nwc_uri || "");
  storeLastConnection(data);

  setStatus("Minted. Scan the QR / copy the URI into Damus/Amethyst/etc.");
}

export async function revokeNwc() {
  const clientPubkey = qs("nwc-client-pubkey").value.trim();
  if (!clientPubkey || clientPubkey.length < 64) {
    setStatus("Enter client pubkey (64-hex) to revoke.", true);
    return;
  }
  setStatus("Revoking…");
  await postJson("/api/nwc/revoke", { client_pubkey: clientPubkey });
  setStatus("Revoked.");
}

export async function copyUri() {
  const uri = qs("nwc-uri").value.trim();
  if (!uri) {
    setStatus("Nothing to copy.", true);
    return;
  }
  await navigator.clipboard.writeText(uri);
  setStatus("Copied URI to clipboard.");
}

export function openInApp() {
  const uri = qs("nwc-uri").value.trim();
  if (!uri) {
    setStatus("No URI to open.", true);
    return;
  }
  // On mobile this often hands off to the wallet/client that registered the scheme.
  window.location.href = uri;
}

export function clearForm() {
  qs("nwc-uri").value = "";
  qs("nwc-client-pubkey").value = "";
  setStatus("");
  clearQr();
}

export function bindNwcUi() {
  // Safe binding (only if modal exists on this page)
  const modal = document.getElementById("nwc-modal");
  if (!modal) return;

  qs("nwc-mint-btn").addEventListener("click", async (e) => {
    e.preventDefault();
    try { await mintNwc(); } catch (err) { setStatus(err.message || String(err), true); }
  });

  qs("nwc-revoke-btn").addEventListener("click", async (e) => {
    e.preventDefault();
    if (!confirm("Revoke this NWC connection? Clients using the URI will stop working.")) return;
    try { await revokeNwc(); } catch (err) { setStatus(err.message || String(err), true); }
  });

  qs("nwc-copy-btn").addEventListener("click", async (e) => {
    e.preventDefault();
    try { await copyUri(); } catch (err) { setStatus(err.message || String(err), true); }
  });

  qs("nwc-open-btn").addEventListener("click", (e) => {
    e.preventDefault();
    try { openInApp(); } catch (err) { setStatus(err.message || String(err), true); }
  });

  qs("nwc-clear-btn").addEventListener("click", (e) => {
    e.preventDefault();
    clearForm();
  });

  // When modal opens, repaint QR (useful after page navigation)
  document.addEventListener("micromodal:show", (event) => {
    if (event.detail && event.detail.content && event.detail.content.id === "nwc-modal") {
      const uri = (document.getElementById("nwc-uri")?.value || "").trim();
      if (uri) renderQr(uri);
    }
  });
}
