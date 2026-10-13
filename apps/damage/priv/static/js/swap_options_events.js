// swap_options_events.js
//
// LISTING: fetched from Æternity Middleware contract logs:
//   GET {mdwBase}/v3/contracts/logs?contract_id=ct_...&direction=backward&limit=50
//
// CREATION: submitted to your backend (it signs admin/seller call):
//   POST {apiBase}/swap_options  -> returns { id, bolt11, payment_hash }
//
// Notes:
// - MDW returns `event_hash`, `args` (big ints), optional decoded `data`, and `call_tx_hash`. :contentReference[oaicite:4]{index=4}
// - To filter only a specific event type, pass `event=<event_hash>` in query. :contentReference[oaicite:5]{index=5}
//
// You should hardcode event_hash values once computed from your contract constructor names.
// MDW docs show how event_hash is derived (blake2b_256 hash of constructor name, base32hex). :contentReference[oaicite:6]{index=6}

export function initSwapOptionsEventsUI({
  mdwBase = "https://mainnet.aeternity.io/mdw",
  apiBase = "/api",
  contractId, // ct_...
  // precomputed hashes (recommended):
  optionCreatedEventHash = null,
  optionExercisedEventHash = null,
  listContainerId = "swap-options-list",
  tableTplId = "swap-options-table-tpl",
  alertId = "swap-options-alert",
} = {}) {
  if (!contractId) throw new Error("contractId (ct_...) is required");

  const els = {
    list: document.getElementById(listContainerId),
    tpl: document.getElementById(tableTplId),
    alert: document.getElementById(alertId),
    refreshBtn: document.getElementById("swap-refresh-btn"),
    // modal
    issueUrl: document.getElementById("swap-issue-url"),
    buyerAk: document.getElementById("swap-buyer-ak"),
    sellerAk: document.getElementById("swap-seller-ak"),
    sats: document.getElementById("swap-sats"),
    damage: document.getElementById("swap-damage"),
    ttl: document.getElementById("swap-ttl"),
    submit: document.getElementById("swap-create-submit"),
    result: document.getElementById("swap-create-result"),
    bolt11: document.getElementById("swap-bolt11"),
    ph: document.getElementById("swap-payment-hash"),
    error: document.getElementById("swap-create-error"),
  };

  const showAlert = (msg) => {
    if (!els.alert) return;
    els.alert.style.display = "block";
    els.alert.innerHTML = `<strong>Swap Options</strong><div>${escapeHtml(msg)}</div>`;
  };
  const clearAlert = () => {
    if (!els.alert) return;
    els.alert.style.display = "none";
    els.alert.innerHTML = "";
  };

  const showCreateError = (msg) => {
    if (!els.error) return;
    els.error.style.display = "block";
    els.error.innerHTML = `<strong>Create failed</strong><div>${escapeHtml(msg)}</div>`;
  };
  const clearCreateError = () => {
    if (!els.error) return;
    els.error.style.display = "none";
    els.error.innerHTML = "";
  };

  const setCreateResult = ({ bolt11, payment_hash, id }) => {
    if (!els.result) return;
    els.result.style.display = "block";
    els.bolt11.value = bolt11 || "";
    els.ph.textContent = payment_hash || "";
    // optional: also show id if you want
  };

  async function fetchLogs({ limit = 50 } = {}) {
    // If you only want "OptionCreated" logs, pass event=... (recommended).
    // MDW supports filtering by contract_id and event hash. :contentReference[oaicite:7]{index=7}
    const params = new URLSearchParams({
      contract_id: contractId,
      direction: "backward",
      limit: String(limit),
    });

    if (optionCreatedEventHash) params.set("event", optionCreatedEventHash);

    const url = `${mdwBase}/v3/contracts/logs?${params.toString()}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`MDW HTTP ${res.status}`);
    const json = await res.json();
    return json.data || [];
  }

  function decodeOptionsFromLogs(logs) {
    // Minimal decode strategy:
    // - Use args[0..] for indexed fields (id, buyer, seller) if you emit them that way.
    // - Use data for issue_url if you emit it as data/payload.
    //
    // NOTE: args come back as decimal-strings of 256-bit integers. :contentReference[oaicite:8]{index=8}
    // Converting those to ak_/ct_ requires aeser encoding (best done server-side).
    // So here we display them as-is unless you provide a decoder.
    return logs.map((l) => {
      const args = l.args || [];
      const id = safeInt(args[0]);
      const buyer = args[1] ? `int:${args[1]}` : "";
      const seller = args[2] ? `int:${args[2]}` : "";

      const issue_url = (l.data || "").trim();
      const issue_ref = deriveIssueRef(issue_url);

      return {
        id: isNaN(id) ? "?" : id,
        buyer,
        seller,
        state: "Open", // you can refine by also fetching exercised/cancelled logs or reading contract state
        call_tx_hash: l.call_tx_hash || "",
        issue_url,
        issue_ref,
      };
    });
  }

  function render(options) {
    if (!els.list || !els.tpl) return;
    els.list.innerHTML = Mustache.render(els.tpl.innerHTML, { options });
  }

  async function refresh() {
    clearAlert();
    try {
      const logs = await fetchLogs({ limit: 100 });
      const options = decodeOptionsFromLogs(logs);
      render(options);
    } catch (e) {
      showAlert(`Could not load contract logs: ${String(e.message || e)}`);
    }
  }

  async function createOption() {
    clearCreateError();
    if (els.result) els.result.style.display = "none";

    const issue_url = (els.issueUrl?.value || "").trim();
    const buyer_ak = (els.buyerAk?.value || "").trim();
    const seller_ak = (els.sellerAk?.value || "").trim();
    const sats_amount = parseInt(els.sats?.value || "0", 10);
    const damage_amount = parseInt(els.damage?.value || "0", 10);
    const expiry_seconds = parseInt(els.ttl?.value || "0", 10);

    if (!issue_url || !buyer_ak || !seller_ak || !sats_amount || !damage_amount || !expiry_seconds) {
      showCreateError("Missing required fields.");
      return;
    }

    // Backend signs & submits contract call, plus creates CLN hold invoice, etc.
    const payload = {
      contract_id: contractId,
      issue_url,
      buyer_ak,
      seller_ak,
      sats_amount,
      damage_amount,
      expiry_seconds,
    };

    try {
      const res = await fetch(`${apiBase}/swap_options`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify(payload),
      });
      if (!res.ok) throw new Error(`API HTTP ${res.status}: ${await res.text().catch(() => "")}`);

      const out = await res.json();
      setCreateResult(out);

      // After tx is mined, logs will appear; refresh a couple times if you want
      await refresh();
    } catch (e) {
      showCreateError(String(e.message || e));
    }
  }

  if (els.refreshBtn) els.refreshBtn.addEventListener("click", refresh);
  if (els.submit) els.submit.addEventListener("click", createOption);

  refresh();
  return { refresh, createOption };
}

function safeInt(x) {
  try { return parseInt(String(x), 10); } catch { return NaN; }
}

function deriveIssueRef(issueUrl) {
  try {
    const u = new URL(issueUrl);
    if (!u.hostname.includes("github.com")) return issueUrl;
    const parts = u.pathname.split("/").filter(Boolean);
    if (parts.length >= 4 && parts[2] === "issues") return `${parts[0]}/${parts[1]}#${parts[3]}`;
    return issueUrl;
  } catch {
    return issueUrl || "";
  }
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
