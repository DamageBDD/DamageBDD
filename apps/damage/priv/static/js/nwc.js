// /static/js/nwc.js
// NWC Connect dialog glue for DamageBDD.
// Requires: MicroModal, QRCode, TokenManager.

const NWC_MAX_RELAYS = 5;
const NWC_CACHE_KEY = "damage.nwc.last";

function relayCheckboxes() {
  return Array.from(
    document.querySelectorAll(".nwc-relay-preset, .nwc-relay-checkbox")
  );
}

function relaySummaryEl() {
  return (
    document.getElementById("nwc-relay-count") ||
    document.getElementById("nwc-relay-summary")
  );
}

function canonicalRelayUrl(url) {
  if (!url) return "";

  let out = String(url).trim();

  while (out.endsWith("/")) {
    out = out.slice(0, -1);
  }

  return out.toLowerCase();
}

function selectedNwcRelays() {
  const checked = relayCheckboxes()
    .filter((el) => el.checked)
    .map((el) => canonicalRelayUrl(el.value));

  const customRaw = document.getElementById("nwc-custom-relays")?.value || "";
  const custom = customRaw
    .split(/\r?\n/)
    .map(canonicalRelayUrl)
    .filter(Boolean);

  const relays = [];
  const seen = new Set();

  for (const relay of [...checked, ...custom]) {
    if (!relay.startsWith("wss://") && !relay.startsWith("ws://")) continue;
    if (seen.has(relay)) continue;

    seen.add(relay);
    relays.push(relay);

    if (relays.length >= NWC_MAX_RELAYS) break;
  }

  return relays;
}

function updateRelaySummary() {
  const relays = selectedNwcRelays();
  const el = relaySummaryEl();
  const hiddenRelay = document.getElementById("nwc-relay");

  if (hiddenRelay) {
    hiddenRelay.value = relays[0] || "";
  }

  if (!el) return;

  if (relays.length === 0) {
    el.textContent = "Select at least one relay.";
    el.classList.add("is-error");
    return;
  }

  el.textContent = `Using ${relays.length} relay${relays.length === 1 ? "" : "s"}.`;
  el.title = relays.join(", ");
  el.classList.remove("is-error");
}

function setRelaySelections(relays) {
  const canonical = new Set((relays || []).map(canonicalRelayUrl));

  for (const checkbox of relayCheckboxes()) {
    checkbox.checked = canonical.has(canonicalRelayUrl(checkbox.value));
  }

  updateRelaySummary();
}

function setResultVisible(visible) {
  const empty = document.getElementById("nwc-empty-state");
  const body = document.getElementById("nwc-result-body");

  if (empty) empty.hidden = visible;
  if (body) body.hidden = !visible;
}

function authHeaders() {
  const token =
    window.TokenManager && window.TokenManager.getToken
      ? window.TokenManager.getToken()
      : null;

  const headers = new Headers();
  headers.set("content-type", "application/json");
  headers.set("accept", "application/json");

  if (token) {
    headers.set("Authorization", "Bearer " + token);
  }

  return headers;
}

function qs(id) {
  const el = document.getElementById(id);

  if (!el) {
    throw new Error(`Missing element #${id}`);
  }

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

  if (qr) {
    qr.innerHTML = "";
  }
}

function renderQr(text) {
  clearQr();

  const mount = document.getElementById("nwc-qr");

  if (!mount || !text) return;

  if (!window.QRCode) {
    mount.textContent = "QR library missing";
    return;
  }

  new QRCode(mount, {
    text,
    width: 180,
    height: 180,
    correctLevel: QRCode.CorrectLevel.M
  });
}

function clearConnectionView() {
  const uri = document.getElementById("nwc-uri");
  const pubkey = document.getElementById("nwc-client-pubkey");

  if (uri) uri.value = "";
  if (pubkey) pubkey.value = "";

  clearQr();
  setResultVisible(false);
}

function showConnectionView(data) {
  qs("nwc-uri").value = data.nwc_uri || "";
  qs("nwc-client-pubkey").value = data.client_pubkey || "";

  renderQr(data.nwc_uri || "");
  setResultVisible(true);
}

function clearLastConnection() {
  try {
    localStorage.removeItem(NWC_CACHE_KEY);
  } catch (_) {
    // ignore localStorage failures
  }
}

function storeLastConnection(data) {
  if (!data || data.status !== "ok" || data.usable !== true || !data.nwc_uri) {
    return;
  }

  try {
    localStorage.setItem(
      NWC_CACHE_KEY,
      JSON.stringify({
        ts: Date.now(),
        status: data.status,
        usable: data.usable,
        client_pubkey: data.client_pubkey,
        wallet_pubkey: data.wallet_pubkey,
        nwc_uri: data.nwc_uri,
        relays: data.relays || []
      })
    );
  } catch (_) {
    // ignore localStorage failures
  }
}

function loadLastConnection() {
  try {
    const raw = localStorage.getItem(NWC_CACHE_KEY);

    if (!raw) return null;

    const data = JSON.parse(raw);

    if (!data || data.status !== "ok" || data.usable !== true || !data.nwc_uri) {
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
  } catch (_) {
    data = null;
  }

  if (!resp.ok) {
    const msg =
      data && (data.error || data.message || data.status)
        ? JSON.stringify(data)
        : text || resp.statusText;

    const err = new Error(`HTTP ${resp.status}: ${msg}`);
    err.status = resp.status;
    err.data = data;
    throw err;
  }

  return data;
}

export function openNwcModal() {
  const last = loadLastConnection();

  if (last?.relays?.length) {
    setRelaySelections(last.relays);
  } else {
    updateRelaySummary();
  }

  if (last?.nwc_uri) {
    showConnectionView(last);
    setStatus("Loaded cached usable NWC URI.");
  } else {
    clearConnectionView();
    setStatus("");
  }

  if (window.MicroModal) {
    window.MicroModal.show("nwc-modal");
  }
}

export function closeNwcModal() {
  if (window.MicroModal) {
    window.MicroModal.close("nwc-modal");
  }
}

export async function mintNwc() {
  const btn = document.getElementById("nwc-mint-btn");

  try {
    if (btn) btn.disabled = true;

    setStatus("Minting…");
    clearConnectionView();

    const maxSingleSat = Number(qs("nwc-max-single").value || "0");
    const maxTotalSat = Number(qs("nwc-max-total").value || "0");
    const expiresHeight = Number(qs("nwc-expires-height").value || "0");

    const relays = selectedNwcRelays();

    if (relays.length === 0) {
      setStatus("Select at least one relay.", true);
      return;
    }

    if (relays.length > NWC_MAX_RELAYS) {
      setStatus(`Use at most ${NWC_MAX_RELAYS} relays.`, true);
      return;
    }

    if (maxTotalSat > 0 && maxSingleSat > maxTotalSat) {
      setStatus("Max single cannot exceed max total.", true);
      return;
    }

    const data = await postJson("/api/nwc/mint", {
      relays,
      relay: relays[0],

      // Current backend spelling
      max_single_sat: maxSingleSat,
      max_total_sat: maxTotalSat,

      // Probe / compatibility spelling
      max_single_sats: maxSingleSat,
      max_total_sats: maxTotalSat,

      expires_height: expiresHeight
    });

    if (!data || data.status !== "ok" || data.usable !== true || !data.nwc_uri) {
      clearLastConnection();
      clearConnectionView();

      const reason = data?.error || data?.status || "mint_not_ready";
      setStatus(`NWC mint not usable yet: ${reason}`, true);
      console.warn("NWC mint returned non-usable response", data);
      return;
    }

    showConnectionView(data);
    storeLastConnection(data);

    setStatus("Minted. Scan QR or copy the URI.");
  } finally {
    if (btn) btn.disabled = false;
  }
}

export async function revokeNwc() {
  const clientPubkey = qs("nwc-client-pubkey").value.trim();

  if (!/^[0-9a-fA-F]{64}$/.test(clientPubkey)) {
    setStatus("Enter a valid 64-character client pubkey hex to revoke.", true);
    return;
  }

  setStatus("Revoking…");

  await postJson("/api/nwc/revoke", {
    client_pubkey: clientPubkey
  });

  clearLastConnection();
  clearConnectionView();

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

  window.location.href = uri;
}

export function clearForm() {
  clearConnectionView();
  clearLastConnection();
  setStatus("");

  const customRelays = document.getElementById("nwc-custom-relays");
  if (customRelays) {
    customRelays.value = "";
  }

  for (const checkbox of relayCheckboxes()) {
    const relay = canonicalRelayUrl(checkbox.value);
    checkbox.checked =
      relay === "wss://relay.damus.io" ||
      relay === "wss://relay.primal.net" ||
      relay === "wss://nos.lol";
  }

  const maxSingle = document.getElementById("nwc-max-single");
  if (maxSingle) maxSingle.value = "10";

  const maxTotal = document.getElementById("nwc-max-total");
  if (maxTotal) maxTotal.value = "50";

  const expiresHeight = document.getElementById("nwc-expires-height");
  if (expiresHeight) expiresHeight.value = "0";

  updateRelaySummary();
}

export function bindNwcUi() {
  const modal = document.getElementById("nwc-modal");

  if (!modal || modal.dataset.nwcBound === "true") {
    return;
  }

  qs("nwc-mint-btn").addEventListener("click", async (e) => {
    e.preventDefault();

    try {
      await mintNwc();
    } catch (err) {
      setStatus(err.message || String(err), true);
      console.error(err);
    }
  });

  qs("nwc-revoke-btn").addEventListener("click", async (e) => {
    e.preventDefault();

    if (!confirm("Revoke this NWC connection? Clients using the URI will stop working.")) {
      return;
    }

    try {
      await revokeNwc();
    } catch (err) {
      setStatus(err.message || String(err), true);
      console.error(err);
    }
  });

  qs("nwc-copy-btn").addEventListener("click", async (e) => {
    e.preventDefault();

    try {
      await copyUri();
    } catch (err) {
      setStatus(err.message || String(err), true);
      console.error(err);
    }
  });

  qs("nwc-open-btn").addEventListener("click", (e) => {
    e.preventDefault();

    try {
      openInApp();
    } catch (err) {
      setStatus(err.message || String(err), true);
      console.error(err);
    }
  });

  qs("nwc-clear-btn").addEventListener("click", (e) => {
    e.preventDefault();
    clearForm();
  });

  for (const checkbox of relayCheckboxes()) {
    checkbox.addEventListener("change", updateRelaySummary);
  }

  const customRelays = document.getElementById("nwc-custom-relays");
  if (customRelays) {
    customRelays.addEventListener("input", updateRelaySummary);
  }

  updateRelaySummary();

  const uri = (document.getElementById("nwc-uri")?.value || "").trim();
  setResultVisible(Boolean(uri));

  document.addEventListener("micromodal:show", (event) => {
    if (
      event.detail &&
      event.detail.content &&
      event.detail.content.id === "nwc-modal"
    ) {
      const currentUri = (document.getElementById("nwc-uri")?.value || "").trim();
      setResultVisible(Boolean(currentUri));
      if (currentUri) renderQr(currentUri);
    }
  });

  modal.dataset.nwcBound = "true";
}

document.addEventListener("DOMContentLoaded", () => {
  if (document.getElementById("nwc-modal")) {
    bindNwcUi();
  }
});
