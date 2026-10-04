/* /static/js/reports.js
 * Activity tab: render DAMAGE spend activity from public Aeternity middleware.
 *
 * Standalone-safe: no DamageBDD backend routes and no module imports required.
 * Data source: GET /v3/accounts/{nodeAccount}/activities?owned_only=true&type=transactions
 */
(function () {
  "use strict";

  const DEFAULT_MDW_BASE = "https://mainnet.aeternity.io/mdw";
  const DEFAULT_IPFS_GATEWAY = "https://ipfs.io/ipfs/";
  const DEFAULT_DAMAGE_TOKEN_CONTRACT = "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk";
  const TOKEN_DECIMALS = 8;
  const IPFS_FIRSTLINE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

  const qs = (s, r = document) => r.querySelector(s);
  const el = (tag, attrs = {}, text = "") => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    if (text) n.textContent = text;
    return n;
  };

  // --- standalone-compatible tiny fetch helpers ---
  async function fetchJSON(url, { retries = 1, backoff = 250 } = {}) {
    let lastErr;
    for (let i = 0; i <= retries; i++) {
      try {
        const response = await fetch(url, { headers: { accept: "application/json" } });
        if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
        return await response.json();
      } catch (err) {
        lastErr = err;
        if (i < retries) await new Promise((resolve) => setTimeout(resolve, backoff * (i + 1)));
      }
    }
    throw lastErr;
  }

  async function fetchCachedTextFirstLine(url, {
    cacheKey = null,
    ttlMs = IPFS_FIRSTLINE_TTL_MS,
    retries = 1,
    backoff = 250,
    bypassCache = false
  } = {}) {
    if (cacheKey && !bypassCache) {
      try {
        const cached = JSON.parse(localStorage.getItem(cacheKey) || "null");
        if (cached && Date.now() - cached.at < ttlMs) return cached.value;
      } catch {}
    }

    let lastErr;
    for (let i = 0; i <= retries; i++) {
      try {
        const response = await fetch(url, { headers: { range: "bytes=0-2048" } });
        if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
        const body = await response.text();
        const first = body.split(/\r?\n/).map((x) => x.trim()).find(Boolean) || "—";
        if (cacheKey) {
          try { localStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), value: first })); } catch {}
        }
        return first;
      } catch (err) {
        lastErr = err;
        if (i < retries) await new Promise((resolve) => setTimeout(resolve, backoff * (i + 1)));
      }
    }
    throw lastErr;
  }

  // --- state ---
  const state = {
    accountId: null,       // node/payer account; used in /accounts/{accountId}/activities
    walletId: null,        // optional user wallet/caller filter
    contractId: null,      // optional DAMAGE token contract filter
    limit: 10,
    pagePath: null,
    nextPath: null,
    prevPath: null
  };

  function stripTrailingSlash(s) {
    return String(s || "").replace(/\/+$/, "");
  }

  function controlValue(selectors, fallback = "") {
    for (const selector of selectors) {
      const n = qs(selector);
      if (n && typeof n.value === "string" && n.value.trim()) return n.value.trim();
    }
    return fallback;
  }

  function firstControl(selectors) {
    for (const selector of selectors) {
      const n = qs(selector);
      if (n) return n;
    }
    return null;
  }

  function mdwBase() {
    return stripTrailingSlash(controlValue(
      ["#activity-mdw", "#mdw-base", "#mdw"],
      window.DamageActivity?.mdwBase || DEFAULT_MDW_BASE
    ));
  }

  function ipfsGateway() {
    const value = controlValue(
      ["#activity-ipfs", "#ipfs-gateway", "#ipfs"],
      window.DamageActivity?.ipfsGateway || DEFAULT_IPFS_GATEWAY
    );
    return value.endsWith("/") ? value : `${value}/`;
  }

  function damageTokenContract() {
    return controlValue(
      ["#activity-contract", "#damage-contract", "#contract"],
      window.DamageActivity?.damageTokenContract || DEFAULT_DAMAGE_TOKEN_CONTRACT
    );
  }

  function readLimit() {
    const raw = controlValue(["#activity-limit", "#limit"], String(state.limit || 10));
    const n = Number(raw);
    return Number.isFinite(n) ? Math.min(100, Math.max(1, Math.floor(n))) : 10;
  }

  function syncStateFromControls() {
    const nodeCtl = firstControl(["#activity-node", "#activity-node-account", "#node-account", "#activity-account"]);
    const walletCtl = firstControl(["#activity-wallet", "#wallet-account", "#wallet"]);
    const contractCtl = firstControl(["#activity-contract", "#damage-contract", "#contract"]);

    state.accountId = nodeCtl ? text(nodeCtl.value) || null : state.accountId;
    state.walletId = walletCtl ? text(walletCtl.value) || null : state.walletId;
    state.contractId = (contractCtl ? text(contractCtl.value) : "") || damageTokenContract() || null;
    state.limit = readLimit();
  }

  function mdwUrl(pathOrUrl) {
    const value = String(pathOrUrl || "");
    if (/^https?:\/\//i.test(value)) return value;

    const base = mdwBase();
    try {
      const b = new URL(base);
      if (value.startsWith(b.pathname + "/")) return `${b.origin}${value}`;
      if (value.startsWith("/mdw/") && b.pathname.endsWith("/mdw")) return `${b.origin}${value}`;
    } catch {}

    return `${base}${value.startsWith("/") ? "" : "/"}${value}`;
  }

  function ipfsUrl(cid) {
    return `${ipfsGateway()}${encodeURIComponent(cid)}`;
  }

  function updateUrlFromControls() {
    if (!history?.replaceState) return;
    try {
      const url = new URL(location.href);
      const node = state.accountId || "";
      const wallet = state.walletId || "";
      const contract = state.contractId || "";
      if (node) url.searchParams.set("node", node); else url.searchParams.delete("node");
      if (wallet) url.searchParams.set("wallet", wallet); else url.searchParams.delete("wallet");
      if (contract) url.searchParams.set("contract", contract); else url.searchParams.delete("contract");
      url.searchParams.set("limit", String(state.limit));
      history.replaceState(null, "", url);
    } catch {}
  }

  function prefillFromQuery() {
    try {
      const params = new URLSearchParams(location.search);
      const node = params.get("node") || params.get("account") || params.get("payer") || "";
      const wallet = params.get("wallet") || params.get("caller") || "";
      const contract = params.get("contract") || window.DamageActivity?.damageTokenContract || DEFAULT_DAMAGE_TOKEN_CONTRACT;
      const mdw = params.get("mdw") || "";
      const ipfs = params.get("ipfs") || "";
      const limit = params.get("limit") || "";

      const set = (selectors, value) => {
        if (!value) return;
        for (const selector of selectors) {
          const n = qs(selector);
          if (n) { n.value = value; return; }
        }
      };

      set(["#activity-node", "#activity-node-account", "#node-account", "#activity-account"], node);
      set(["#activity-wallet", "#wallet-account", "#wallet"], wallet);
      set(["#activity-contract", "#damage-contract", "#contract"], contract);
      set(["#activity-mdw", "#mdw-base", "#mdw"], mdw);
      set(["#activity-ipfs", "#ipfs-gateway", "#ipfs"], ipfs);
      set(["#activity-limit", "#limit"], limit);
    } catch {}
  }

  // --- Public MDW queries ---
  async function getAccountActivities({ accountId, limit = 10, pagePath = null } = {}) {
    const url = pagePath
      ? mdwUrl(pagePath)
      : mdwUrl(`/v3/accounts/${encodeURIComponent(accountId)}/activities?owned_only=true&type=transactions&direction=backward&limit=${encodeURIComponent(limit)}`);

    return fetchJSON(url);
  }

  async function getTxFull(txHash) {
    return fetchJSON(mdwUrl(`/v3/transactions/${encodeURIComponent(txHash)}`));
  }

  function toMsOrNull(timeValue) {
    if (!timeValue) return null;
    const n = Number(timeValue);
    if (!Number.isFinite(n)) return null;
    if (n > 1e14) return Math.floor(n / 1000); // microseconds
    if (n > 1e11) return n;                    // milliseconds
    if (n > 1e9) return n * 1000;              // seconds
    return n;
  }

  function fmtDate(ms) {
    return !ms ? "—" : new Date(ms).toLocaleString();
  }

  function aescanTxUrl(txHash) {
    return `https://aescan.io/transactions/${encodeURIComponent(txHash)}`;
  }

  function aescanAccountUrl(account) {
    return `https://aescan.io/accounts/${encodeURIComponent(account)}`;
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

  function text(value) {
    return String(value ?? "").trim();
  }

  function shortId(value, keep = 9) {
    const v = text(value);
    return v.length > keep * 2 + 3 ? `${v.slice(0, keep)}…${v.slice(-keep)}` : v;
  }

  function isLikelyCid(value) {
    const v = text(value);
    return /^Qm[1-9A-HJ-NP-Za-km-z]{44,}$/.test(v) || /^bafy[a-z2-7]+$/i.test(v);
  }

  // ---- normalize: unwrap node PayingForTx and keep only DAMAGE token spend calls ----
  function txCandidates(row) {
    return [
      row,
      row?.payload,
      row?.payload?.tx,
      row?.payload?.tx?.tx,
      row?.payload?.tx?.tx?.tx,
      row?.tx,
      row?.tx?.tx,
      row?.tx?.tx?.tx,
      row?.transaction,
      row?.transaction?.tx,
      row?.transaction?.tx?.tx,
      row?.transaction?.tx?.tx?.tx,
      row?.inner_tx,
      row?.internal_tx
    ].filter((x) => x && typeof x === "object");
  }

  function txHashOf(row) {
    return text(
      row?.hash ||
      row?.tx_hash ||
      row?.call_tx_hash ||
      row?.payload?.hash ||
      row?.payload?.tx_hash ||
      row?.payload?.tx?.hash ||
      row?.tx?.hash ||
      ""
    );
  }

  function isPayingFor(row) {
    return txCandidates(row).some((c) => /paying.?for/i.test(text(c.type || c.tag || c.tx_type || c.kind || c.event || row?.type)));
  }

  function argValue(arg) {
    if (arg == null) return null;
    if (typeof arg !== "object") return arg;
    if (Object.prototype.hasOwnProperty.call(arg, "value")) return arg.value;
    if (Array.isArray(arg) && arg.length >= 2) return arg[1];
    return arg;
  }

  function extractTxArguments(row) {
    for (const c of txCandidates(row)) {
      const args = c?.arguments || c?.args || c?.decoded_args;
      if (Array.isArray(args) && args.length) return args;
    }
    return [];
  }

  function functionName(c) {
    const f = text(c?.function || c?.func || c?.entrypoint);
    return f.includes(".") ? f.split(".").pop() : f;
  }

  function contractIdOf(c, row) {
    return text(
      c?.contract_id ||
      c?.contract ||
      c?.recipient_id ||
      row?.contract_id ||
      row?.contract ||
      row?.payload?.contract_id ||
      row?.payload?.tx?.contract_id ||
      ""
    );
  }

  function findSpendCandidate(row) {
    const contract = state.contractId || damageTokenContract();
    for (const c of txCandidates(row)) {
      const args = c?.arguments || c?.args || c?.decoded_args || [];
      const fn = functionName(c);
      const seenContract = contractIdOf(c, row);
      const maybeSpendByArgs = Array.isArray(args) && args.length >= 4 && isLikelyCid(text(argValue(args[2]))) && isLikelyCid(text(argValue(args[3])));
      if ((fn === "spend" || maybeSpendByArgs) && (!contract || !seenContract || seenContract === contract)) return c;
    }
    return null;
  }

  async function normalizeDamageSpend(txFull, knownHash = "", activityRow = null) {
    const source = activityRow || txFull;
    if (!isPayingFor(source) && !isPayingFor(txFull)) return null;

    const inner = findSpendCandidate(txFull) || (activityRow ? findSpendCandidate(activityRow) : null);
    if (!inner) return null;

    const args = extractTxArguments(inner).length ? extractTxArguments(inner) : extractTxArguments(txFull);
    const nodePublicKey = text(argValue(args?.[0]));
    const amountRaw = Number(argValue(args?.[1]));
    const featureCid = text(argValue(args?.[2]));
    const reportCid = text(argValue(args?.[3]));
    if (!featureCid || !reportCid) return null;

    const callerId = text(
      inner?.caller_id ||
      inner?.sender_id ||
      txFull?.caller_id ||
      txFull?.tx?.caller_id ||
      activityRow?.payload?.tx?.caller_id ||
      ""
    );

    if (state.walletId && callerId !== state.walletId) return null;

    const createdMs = toMsOrNull(
      txFull?.micro_time ||
      txFull?.block_time ||
      txFull?.payload?.micro_time ||
      txFull?.payload?.block_time ||
      activityRow?.payload?.micro_time ||
      activityRow?.block_time ||
      inner?.micro_time
    );

    const featureTitle = await fetchCachedTextFirstLine(
      ipfsUrl(featureCid),
      {
        cacheKey: isLikelyCid(featureCid) ? `ipfs:firstline:feature:${featureCid}` : null,
        ttlMs: IPFS_FIRSTLINE_TTL_MS,
        retries: 1,
        backoff: 250,
        bypassCache: !isLikelyCid(featureCid)
      }
    ).catch(() => shortId(featureCid, 12));

    return {
      createdMs,
      createdLabel: fmtDate(createdMs),
      amountRaw,
      featureCid,
      featureTitle,
      reportCid,
      callerId,
      nodePublicKey,
      txHash: knownHash || txHashOf(activityRow) || txHashOf(txFull),
      payingFor: true
    };
  }

  function formatTokenAmount(raw, decimals = TOKEN_DECIMALS) {
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

    if (prevBtn) prevBtn.disabled = !state.prevPath;
    if (nextBtn) nextBtn.disabled = !state.nextPath;
    if (info) info.textContent = `Scanning ${state.limit} node transactions • newest first`;
  }

  function link(label, href) {
    return el("a", { class: "activity-link", href, target: "_blank", rel: "noopener" }, label);
  }

  function renderSpendRow(ul, row) {
    const li = el("li", { class: "activity-item" });

    const left = el("div", { class: "activity-left" });
    left.appendChild(el("div", { class: "activity-time" }, fmtDate(row.createdMs)));
    left.appendChild(el("div", { class: "activity-badge" }, "paying_for spend"));

    const main = el("div", { class: "activity-main" });
    main.appendChild(el("div", { class: "activity-title" }, row.featureTitle || "DAMAGE spend"));

    const meta = el("div", { class: "activity-meta" });
    meta.appendChild(link("feature", ipfsUrl(row.featureCid)));
    meta.appendChild(link("report", ipfsUrl(row.reportCid)));
    if (row.txHash) meta.appendChild(link("aescan", aescanTxUrl(row.txHash)));
    if (row.callerId) meta.appendChild(link("wallet", aescanAccountUrl(row.callerId)));
    if (row.nodePublicKey) meta.appendChild(link("node", aescanAccountUrl(row.nodePublicKey)));
    main.appendChild(meta);

    const details = el("div", { class: "activity-details" });
    const body = el("div", { class: "activity-details-body open" });

    const table = el("div", { class: "activity-tx-table" });
    const rows = [
      ["Created", row.createdLabel],
      ["Amount", `${formatTokenAmount(row.amountRaw)} DAMAGE`],
      ["Wallet/caller", row.callerId || "—"],
      ["Node argument", row.nodePublicKey || "—"],
      ["PayingFor tx", row.txHash || "—"],
      ["Feature CID", row.featureCid],
      ["Report CID", row.reportCid]
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

  async function normalizeActivityRow(row) {
    const h = txHashOf(row);
    const direct = await normalizeDamageSpend(row, h, row);
    if (direct) return direct;
    if (!h) return null;

    try {
      const full = await getTxFull(h);
      return await normalizeDamageSpend(full, h, row);
    } catch {
      return null;
    }
  }

  async function renderPage() {
    const ul = qs("#run-reports-list");
    if (!ul) return;

    syncStateFromControls();
    updateUrlFromControls();
    ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">Loading public Aeternity middleware activity…</div></div></li>`;
    ensurePagerWiring();

    if (!state.accountId) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">Enter the node/payer account address that submits PayingFor transactions.</div></div></li>`;
      return;
    }

    let page;
    try {
      page = await getAccountActivities({
        accountId: state.accountId,
        limit: state.limit,
        pagePath: state.pagePath
      });
    } catch (err) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">Could not load AEMDW activity: ${safeText(err?.message || err)}</div></div></li>`;
      return;
    }

    state.nextPath = page?.next || null;
    state.prevPath = page?.prev || null;
    ensurePagerWiring();

    const items = Array.isArray(page?.data) ? page.data : [];
    if (!items.length) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No activity found for this node account.</div></div></li>`;
      return;
    }

    const spendRows = [];
    for (const item of items) {
      const spend = await normalizeActivityRow(item);
      if (spend) spendRows.push(spend);
    }

    ul.innerHTML = "";
    if (!spendRows.length) {
      ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No node PayingFor DAMAGE spend activity found on this page.</div></div></li>`;
      return;
    }

    for (const r of spendRows) renderSpendRow(ul, r);
  }

  // --------------------------
  // refresh on input changes
  // --------------------------
  let inputTimer = null;

  async function refreshFromInput() {
    syncStateFromControls();
    const input = qs("#activity-node") || qs("#activity-node-account") || qs("#node-account") || qs("#activity-account");
    if (!input) return;

    const v = String(input.value || "").trim();
    if (!v) return;

    if (window.AeId?.isValidAeId && v.startsWith("ak_")) {
      const ok = await window.AeId.isValidAeId(v, ["ak_"]).catch(() => true);
      if (!ok) {
        input.classList.add("invalid");
        input.title = "Invalid AE account id.";
        return;
      }
    }

    input.classList.remove("invalid");
    input.title = "";
    state.pagePath = null;
    await renderPage();
  }

  function wireInput() {
    const selectors = [
      "#activity-node", "#activity-node-account", "#node-account", "#activity-account",
      "#activity-wallet", "#wallet-account", "#wallet",
      "#activity-contract", "#damage-contract", "#contract",
      "#activity-mdw", "#mdw-base", "#mdw",
      "#activity-ipfs", "#ipfs-gateway", "#ipfs",
      "#activity-limit", "#limit"
    ];

    for (const selector of selectors) {
      const input = qs(selector);
      if (!input || input.dataset.bound) continue;
      input.dataset.bound = "1";
      input.addEventListener("input", () => {
        clearTimeout(inputTimer);
        inputTimer = setTimeout(() => refreshFromInput(), 250);
      });
      input.addEventListener("change", () => refreshFromInput());
    }

    const refresh = qs("#activity-refresh");
    if (refresh && !refresh.dataset.bound) {
      refresh.dataset.bound = "1";
      refresh.addEventListener("click", () => refreshFromInput());
    }
  }

  // --------------------------
  // AccountFilter integration (kept for existing DamageBDD page)
  // --------------------------

  async function initFilter() {
    if (!window.AccountFilter) return;

    const filter = window.AccountFilter({
      tagsHostId: "activityAddrTags",
      addInputId: "activityAddrInput",
      addBtnId: "activityAddrAddBtn",
      hintId: "activityAddrHint",
      bindInputId: "activity-wallet",
      storageKey: "damagebdd.activity.wallet-filter.v3",
      allowedPrefixes: ["ak_"],
      mode: "single",
      getDefaults: async () => {
        const wallet = await getWalletDefault();
        const current = String((qs("#activity-wallet") || qs("#wallet-account") || {}).value || "").trim();
        return current ? [{ id: current, label: "Current", selected: true, locked: false }] : [];
      },
      onChange: async (_selected, primary) => {
        state.walletId = primary || null;
        state.pagePath = null;
        await renderPage();
      }
    });

    if (filter) await filter.init();
  }

  // Public API (for other tabs/pages)
  async function renderRunReports(accountId, { limit = 10, wallet = null, contract = null } = {}) {
    state.accountId = accountId || null;
    state.walletId = wallet || null;
    state.contractId = contract || damageTokenContract() || null;
    state.limit = limit;
    state.pagePath = null;
    await renderPage();
  }

  window.Reports = { renderRunReports, renderPage };

  document.addEventListener("DOMContentLoaded", async () => {
    prefillFromQuery();
    wireInput();
    await initFilter();

    syncStateFromControls();
    if (state.accountId) renderPage();
  });
})();
