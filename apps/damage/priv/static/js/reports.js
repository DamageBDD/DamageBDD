/* /static/js/reports.js
 * Activity tab: render spend activity + AccountFilter (single select)
 *
 * Requires: filter.js loaded first (window.AccountFilter)
 */

(function () {
  "use strict";

  const MDW_BASE = "https://mainnet.aeternity.io/mdw";

  const qs = (s, r = document) => r.querySelector(s);
  const el = (tag, attrs = {}, text = "") => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    if (text) n.textContent = text;
    return n;
  };

  // --- state ---
  const state = {
    accountId: null,
    limit: 10,
    pagePath: null,
    nextPath: null,
    prevPath: null,
    bypassCache: false
  };

  // --- fetch helpers ---
  async function fetchJSON(url, { retries = 1, backoff = 250 } = {}) {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(url, {
          method: "GET",
          cache: "no-store",
          headers: {
            Accept: "application/json",
            "Cache-Control": "no-cache, no-store, max-age=0, must-revalidate",
            Pragma: "no-cache",
            Expires: "0"
          }
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
      } catch (e) {
        if (i >= retries) throw e;
        await new Promise((r) => setTimeout(r, backoff * (i + 1)));
      }
    }
  }

  // --- MDW queries ---
  async function getAccountActivities({ accountId, limit = 10, pagePath = null } = {}) {
    const url = pagePath
      ? `${MDW_BASE}${pagePath}`
      : `${MDW_BASE}/v3/accounts/${encodeURIComponent(accountId)}/activities?direction=backward&limit=${encodeURIComponent(limit)}`;

    return fetchJSON(url);
  }

  async function getTxFull(txHash) {
    return fetchJSON(`${MDW_BASE}/v3/transactions/${encodeURIComponent(txHash)}`);
  }

  function toMsOrNull(microTime) {
    if (!microTime) return null;
    const n = Number(microTime);
    if (!Number.isFinite(n)) return null;
    return n > 1e12 ? n : Math.floor(n / 1000);
  }

  function fmtDate(ms) {
    return !ms ? "—" : new Date(ms).toLocaleString();
  }

  function aescanTxUrl(txHash) {
    return `https://aescan.io/transactions/${encodeURIComponent(txHash)}`;
  }

  function safeText(s) {
    return String(s ?? "").replace(/[&<>\"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    }[c]));
  }

  // ---- normalize: keep only DAMAGE token spend calls ----
  function extractTxArguments(txFull) {
    return (
      txFull?.tx?.tx?.tx?.arguments ||
      txFull?.tx?.tx?.arguments ||
      txFull?.tx?.arguments ||
      []
    );
  }

  async function fetchTextFirstLine(url) {
    const res = await fetch(url, { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    return (text || "").split(/\r?\n/)[0] || "—";
  }

  async function normalizeDamageSpend(txFull) {
    const inner = txFull?.tx?.tx?.tx || txFull?.tx?.tx || txFull?.tx || null;
    if (!inner) return null;

    if (inner.function !== "spend") return null;

    const args = extractTxArguments(txFull);
    const amountRaw = args?.[1]?.value;
    const featureCid = typeof args?.[2]?.value === "string" ? args[2].value : null;
    const reportCid = typeof args?.[3]?.value === "string" ? args[3].value : null;
    if (!featureCid || !reportCid) return null;

    const createdMs = toMsOrNull(txFull?.micro_time || inner?.micro_time);
    const featureTitle = await fetchTextFirstLine(`/features/${encodeURIComponent(featureCid)}`)
      .catch(() => "—");

    let reportItems = [];
    try {
      const r = await fetch(`/reports/${encodeURIComponent(reportCid)}`, { cache: "no-store" });
      const t = await r.text();
      const json = JSON.parse(t || "[]");
      reportItems = Array.isArray(json) ? json : [];
    } catch {
      reportItems = [];
    }

    return {
      createdMs,
      createdLabel: createdMs ? new Date(createdMs).toLocaleString() : "—",
      amountRaw: typeof amountRaw === "number" ? amountRaw : Number(amountRaw),
      featureCid,
      featureTitle,
      reportCid,
      reportCount: reportItems.length
    };
  }

  function formatTokenAmount(raw, decimals = 8) {
    const n = Number(raw);
    if (!Number.isFinite(n)) return String(raw ?? "—");
    return (n / Math.pow(10, decimals)).toLocaleString(undefined, { maximumFractionDigits: decimals });
  }

  // --- render ---
  function ensurePagerWiring() {
    const prevBtn = qs("#run-reports-prev");
    const nextBtn = qs("#run-reports-next");
    const info = qs("#run-reports-info");

    if (prevBtn && !prevBtn.dataset.bound) {
      prevBtn.dataset.bound = "1";
      prevBtn.addEventListener("click", () => {
        if (!state.prevPath) return;
        state.pagePath = state.prevPath;
        renderPage();
      });
    }

    if (nextBtn && !nextBtn.dataset.bound) {
      nextBtn.dataset.bound = "1";
      nextBtn.addEventListener("click", () => {
        if (!state.nextPath) return;
        state.pagePath = state.nextPath;
        renderPage();
      });
    }

    // pager state
    if (prevBtn) prevBtn.disabled = !state.prevPath;
    if (nextBtn) nextBtn.disabled = !state.nextPath;
    if (info) info.textContent = `Showing ${state.limit} • newest first`;
  }

  function renderSpendRow(ul, row) {
    const li = el("li", { class: "activity-item" });

    const left = el("div", { class: "activity-left" });
    left.appendChild(el("div", { class: "activity-time" }, fmtDate(row.createdMs)));
    left.appendChild(el("div", { class: "activity-badge" }, "spend"));

    const main = el("div", { class: "activity-main" });
    main.appendChild(el("div", { class: "activity-title" }, row.featureTitle || "Spend"));

    const meta = el("div", { class: "activity-meta" });
    const aFeature = el("a", {
      class: "activity-link",
      href: `/features/${encodeURIComponent(row.featureCid)}`,
      target: "_blank",
      rel: "noopener"
    }, "feature");
    const aReport = el("a", {
      class: "activity-link",
      href: `/reports/${encodeURIComponent(row.reportCid)}`,
      target: "_blank",
      rel: "noopener"
    }, "report");
    const aScan = el("a", {
      class: "activity-link",
      href: aescanTxUrl(row.txHash),
      target: "_blank",
      rel: "noopener"
    }, "aescan");

    meta.appendChild(aFeature);
    meta.appendChild(aReport);
    meta.appendChild(aScan);
    main.appendChild(meta);

    const details = el("div", { class: "activity-details" });
    const body = el("div", { class: "activity-details-body open" });

    const table = el("div", { class: "activity-tx-table" });
    const rows = [
      ["Created", row.createdLabel],
      ["Amount", `${formatTokenAmount(row.amountRaw, 8)} DAMAGE`],
      ["Feature CID", row.featureCid],
      ["Report CID", row.reportCid],
      ["Report items", String(row.reportCount ?? 0)]
    ];

    for (const [k, v] of rows) {
      const r = el("div", { class: "activity-tx-row" });
      r.appendChild(el("span", { class: "tx-key" }, k));
      r.appendChild(el("span", { class: "tx-value" }, v ?? "—"));
      table.appendChild(r);
    }

    body.appendChild(table);
    details.appendChild(body);
    main.appendChild(details);

    li.appendChild(left);
    li.appendChild(main);
    ul.appendChild(li);
  }

  async function renderPage() {
    const ul = qs("#run-reports-list");
    if (!ul) return;

    ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">Loading…</div></div></li>`;
    ensurePagerWiring();

    if (!state.accountId) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No account selected.</div></div></li>`;
      return;
    }

    const page = await getAccountActivities({
      accountId: state.accountId,
      limit: state.limit,
      pagePath: state.pagePath
    });

    state.nextPath = page?.next || null;
    state.prevPath = page?.prev || null;
    ensurePagerWiring();

    const items = Array.isArray(page?.data) ? page.data : [];
    if (!items.length) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No activity found.</div></div></li>`;
      return;
    }

    // Extract tx hashes from activity feed
    const txHashes = items
      .map((it) => it?.payload?.tx_hash || null)
      .filter(Boolean);

    // Fetch tx details and keep only spend calls
    const spendRows = [];
    for (const h of txHashes) {
      try {
        const txFull = await getTxFull(h);
        const spend = await normalizeDamageSpend(txFull);
        if (spend) spendRows.push({ ...spend, txHash: h });
      } catch {}
    }

    ul.innerHTML = "";
    if (!spendRows.length) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No DAMAGE spend activity found.</div></div></li>`;
      return;
    }

    for (const r of spendRows) renderSpendRow(ul, r);
  }

  // --------------------------
  // refresh on input changes
  // --------------------------
  let inputTimer = null;

  async function refreshFromInput() {
    const input = qs("#activity-account");
    if (!input) return;

    const v = String(input.value || "").trim();
    if (!window.AeId || !window.AeId.isValidAeId) return;

    const ok = await window.AeId.isValidAeId(v, ["ak_", "ct_"]);
    if (!ok) {
      input.classList.add("invalid");
      input.title = "Invalid AE id (must be ak_ or ct_ and checksum-valid).";
      return;
    }
    input.classList.remove("invalid");
    input.title = "";

    state.accountId = v;
    state.pagePath = null;
    await renderPage();
  }

  function wireInput() {
    const input = qs("#activity-account");
    if (!input || input.dataset.bound) return;

    input.dataset.bound = "1";
    input.addEventListener("input", () => {
      clearTimeout(inputTimer);
      inputTimer = setTimeout(() => refreshFromInput(), 250);
    });
    input.addEventListener("change", () => refreshFromInput());
  }

  // --------------------------
  // AccountFilter integration
  // --------------------------
  async function getWalletDefault() {
    try {
      const w = await window.TokenManager?.getAddress?.();
      if (typeof w === "string" && w.startsWith("ak_")) return w;
    } catch {}
    return null;
  }

  async function initFilter() {
    if (!window.AccountFilter) return;

    const filter = window.AccountFilter({
      tagsHostId: "activityAddrTags",
      addInputId: "activityAddrInput",
      addBtnId: "activityAddrAddBtn",
      hintId: "activityAddrHint",
      bindInputId: "activity-account",
      storageKey: "damagebdd.activity.filter.v2",
      allowedPrefixes: ["ak_", "ct_"],
      mode: "single",
      getDefaults: async () => {
        const wallet = await getWalletDefault();
        const current = String(qs("#activity-account")?.value || "").trim();
        const defs = [];
        if (wallet) defs.push({ id: wallet, label: "Wallet", selected: true, locked: true });
        if (current && current !== wallet) defs.push({ id: current, label: "Current", selected: true, locked: false });
        return defs;
      },
      onChange: async (_selected, primary) => {
        if (!primary) return;
        state.accountId = primary;
        state.pagePath = null;
        await renderPage();
      }
    });

	  if(filter)
		  await filter.init();
  }

  // Public API (for other tabs if needed)
  async function renderRunReports(accountId, { limit = 10 } = {}) {
    state.accountId = accountId;
    state.limit = limit;
    state.pagePath = null;
    await renderPage();
  }

  window.Reports = { renderRunReports };

  document.addEventListener("DOMContentLoaded", async () => {
    wireInput();
    await initFilter();

    // initial render: wallet if present, else whatever is in the input
    const wallet = await getWalletDefault();
    const inputVal = String(qs("#activity-account")?.value || "").trim();
    state.accountId = wallet || inputVal || null;
    if (state.accountId) renderPage();
  });
})();

