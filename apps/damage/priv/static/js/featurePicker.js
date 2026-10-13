// featurePicker.js
// DamageBDD Feature Picker — vanilla JS, no deps.
// Adds:
//  - Samples tab: loads from samplesIndexUrl (JSON index)
//  - Recent Runs tab: loads from localStorage (populated by reports.js or execute flow)
//
// Usage:
//   import { initDamageBDDPicker, rememberRecentFeature } from './featurePicker.js';
//
//   initDamageBDDPicker({
//     opener: '#open-feature-picker',
//     mount:  '#feature-picker-mount',
//     editor: '#feature-editor',
//     gateway: '/features/',              // your app already serves /features/<cid> (see reports.js):contentReference[oaicite:5]{index=5}
//     samplesIndexUrl: '/samples/features/index.json',
//     hashes: [], // optional legacy source
//   });
//
//   // Optional: whenever you execute a feature, call rememberRecentFeature({ cid, title })

// Keep this aligned with reports.js AccountFilter storage key.
const LS_ACTIVITY_FILTER = "damagebdd.activity.filter.v2";

// Aeternity middleware (MDW) base for on-chain activity.
// If you run your own MDW, override with window.DAMAGEBDD_MDW_BASE.
const MDW_BASE = (typeof window !== "undefined" && window.DAMAGEBDD_MDW_BASE)
  ? String(window.DAMAGEBDD_MDW_BASE)
  : "https://mainnet.aeternity.io/mdw";

const LS_RECENT_FEATURES = "dbdd_recent_features_v1";

export function rememberRecentFeature(entry) {
  // entry: { cid, title?, whenMs?, source?, reportCid? }
  try {
    const cid = String(entry?.cid || "").trim();
    if (!cid) return;
    const now = Date.now();
    const rec = loadJSON(LS_RECENT_FEATURES, []);
    const next = [
      {
        cid,
        title: String(entry?.title || "").trim(),
        whenMs: Number(entry?.whenMs || now),
        source: entry?.source || "run",
        reportCid: entry?.reportCid || null
      },
      ...rec.filter((x) => x?.cid !== cid)
    ].slice(0, 30);
    saveJSON(LS_RECENT_FEATURES, next);
  } catch {}
}

export async function initDamageBDDPicker(opts) {
  const {
    opener,
    mount,
    editor,
    hashes = [],
    gateway = "/features/", // default to your app route (not a public IPFS gateway)
    title = "Feature Picker",
    samplesIndexUrl = null, // e.g. "/samples/features/index.json"
  } = opts || {};

  if (!opener) throw new Error('initDamageBDDPicker: "opener" selector is required');
  if (!mount) throw new Error('initDamageBDDPicker: "mount" selector is required');
  if (!editor) throw new Error('initDamageBDDPicker: "editor" selector is required');

  const $opener = typeof opener === "string" ? document.querySelector(opener) : opener;
  const $root   = typeof mount === "string" ? document.querySelector(mount) : mount;
  const $editor = typeof editor === "string" ? document.querySelector(editor) : editor;
  if (!$opener) throw new Error(`initDamageBDDPicker: opener "${opener}" not found`);
  if (!$root) throw new Error(`initDamageBDDPicker: mount "${mount}" not found`);
  if (!$editor) throw new Error(`initDamageBDDPicker: editor "${editor}" not found`);

  injectStylesOnce();

  // --- sources (tabs) ---
  const sources = [];

  if (samplesIndexUrl) {
    sources.push({
      id: "samples",
      label: "Samples",
      icon: "🧪",
      load: () => loadSamplesIndex(samplesIndexUrl)
    });
  }

  sources.push({
    id: "recent",
	label: "Recent (on-chain)",
    icon: "🕒",
    load: () => loadRecentRuns()
  });

  // legacy provided hashes
  if (hashes && hashes.length) {
    const provided = hashes.map((h) => (typeof h === "string" ? { cid: h, label: h } : h));
    sources.push({
      id: "provided",
      label: "Library",
      icon: "📚",
      load: async () =>
        provided.map((x) => ({
          cid: x.cid,
          label: x.label || x.cid,
          subtitle: "Provided",
          whenMs: null
        }))
    });
  }

  // Build UI shell
  $root.classList.add("dbdd-picker");
  $root.innerHTML = `
    <div class="dbdd-header">
      <div class="dbdd-title">${escapeHtml(title)}</div>
      <div class="dbdd-actions">
        <input class="dbdd-search" type="search" placeholder="Search features…" />
        <button class="dbdd-refresh" aria-label="Refresh">↻</button>
      </div>
    </div>

    <div class="dbdd-tabs" role="tablist" aria-label="Feature sources">
      ${sources
        .map(
          (s, i) => `
        <button class="dbdd-tab ${i === 0 ? "active" : ""}" role="tab"
                aria-selected="${i === 0 ? "true" : "false"}"
                data-tab="${escapeHtml(s.id)}">
          <span class="dbdd-tab-ico">${escapeHtml(s.icon)}</span>
          <span>${escapeHtml(s.label)}</span>
          <span class="dbdd-tab-count" data-count="${escapeHtml(s.id)}">0</span>
        </button>`
        )
        .join("")}
    </div>

    <div class="dbdd-body">
      <div class="dbdd-list" role="list"></div>
      <div class="dbdd-detail" aria-live="polite" aria-atomic="true">
        <div class="dbdd-detail-empty">Select a feature to preview</div>
      </div>
    </div>

    <div class="dbdd-toast" hidden></div>
  `;

  // Wire modal open (your original file already used MicroModal.show):contentReference[oaicite:6]{index=6}
	$opener.addEventListener("click", (event) => {
		event.preventDefault();
		event.stopPropagation();

		const modal = document.getElementById("feature-picker-modal");
		console.log("clicked opener", {
			modal,
			microModal: typeof window.MicroModal,
			ariaHidden: modal?.getAttribute("aria-hidden"),
			className: modal?.className
		});

		window.MicroModal?.show("feature-picker-modal");

		console.log("after show", {
			ariaHidden: modal?.getAttribute("aria-hidden"),
			className: modal?.className
		});
	});

  const $list    = $root.querySelector(".dbdd-list");
  const $detail  = $root.querySelector(".dbdd-detail");
  const $search  = $root.querySelector(".dbdd-search");
  const $refresh = $root.querySelector(".dbdd-refresh");
  const $toast   = $root.querySelector(".dbdd-toast");
  const $tabs    = Array.from($root.querySelectorAll(".dbdd-tab"));

  // cache cid -> { text, meta, error }
  const cache = new Map();
  let activeTabId = sources[0]?.id || "recent";
  let activeItems = [];

  $tabs.forEach((btn) => {
    btn.addEventListener("click", async () => {
      setActiveTab(btn.dataset.tab);
      await loadTab();
    });
  });

  $refresh.addEventListener("click", async (event) => {
    cache.clear();
    await loadTab();
    toast("Refreshed", $toast);
	  event.preventDefault();
  });

  $search.addEventListener("input", () => {
    const q = $search.value.trim().toLowerCase();
    for (const $card of $list.querySelectorAll(".dbdd-card")) {
      const hay =
        ($card.querySelector(".dbdd-card-title")?.textContent || "") +
        " " +
        ($card.querySelector(".dbdd-card-desc")?.textContent || "") +
        " " +
        ($card.dataset.cid || "");
      $card.style.display = hay.toLowerCase().includes(q) ? "" : "none";
    }
  });

  function setActiveTab(id) {
    activeTabId = id;
    $tabs.forEach((t) => {
      const on = t.dataset.tab === id;
      t.classList.toggle("active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
    });
  }

  async function loadTab() {
    $list.innerHTML = `<div class="dbdd-skel">Loading…</div>`;
    $detail.innerHTML = `<div class="dbdd-detail-empty">Select a feature to preview</div>`;

    const src = sources.find((s) => s.id === activeTabId) || sources[0];
    const items = (await src.load()) || [];
    activeItems = normalizeItems(items);

    // update counts
    const cntEl = $root.querySelector(`[data-count="${cssEscape(src.id)}"]`);
    if (cntEl) cntEl.textContent = String(activeItems.length);

    renderList(activeItems);
  }

  function normalizeItems(items) {
    // expects { cid, title/label?, subtitle?, whenMs? }
    return items
      .map((x) => ({
        cid: String(x.cid || "").trim(),
        title: x.title || x.label || x.cid,
        subtitle: x.subtitle || "",
        whenMs: x.whenMs || null,
        reportCid: x.reportCid || null
      }))
      .filter((x) => x.cid);
  }

  function renderList(items) {
    $list.innerHTML = "";
    if (!items.length) {
      $list.innerHTML = `<div class="dbdd-empty">No items.</div>`;
      return;
    }

    for (const it of items) {
      const card = document.createElement("div");
      card.className = "dbdd-card";
      card.dataset.cid = it.cid;

      const when = it.whenMs ? new Date(it.whenMs).toLocaleString() : "";
      card.innerHTML = `
        <div class="dbdd-card-top">
          <div class="dbdd-card-title">${escapeHtml(it.title || it.cid)}</div>
          ${when ? `<div class="dbdd-card-when">${escapeHtml(when)}</div>` : ""}
        </div>
        <div class="dbdd-card-desc">${escapeHtml(it.subtitle || shortCid(it.cid))}</div>
        <div class="dbdd-card-cid">${escapeHtml(shortCid(it.cid))}</div>
      `;

      card.addEventListener("click", async () => {
        selectCard(card);
        await showDetail(it.cid);
      });

      $list.appendChild(card);
    }
  }

  function selectCard(card) {
    for (const c of $list.querySelectorAll(".dbdd-card")) c.classList.remove("selected");
    card.classList.add("selected");
  }

  async function showDetail(cid) {
    $detail.innerHTML = `<div class="dbdd-skel">Loading preview…</div>`;

    let rec = cache.get(cid);
    if (!rec) {
      try {
        rec = await fetchFeature(cid, gateway);
      } catch (e) {
        rec = { error: String(e?.message || e) };
      }
      cache.set(cid, rec);
    }

    if (rec.error) {
      $detail.innerHTML = `<div class="dbdd-empty">Failed to load: ${escapeHtml(rec.error)}</div>`;
      return;
    }

    const { text, meta } = rec;
    const preview = meta.headSnippet || text.slice(0, 1500);

    $detail.innerHTML = `
      <div class="dbdd-detail-head">
        <div class="dbdd-detail-left">
          <div class="dbdd-detail-title">${escapeHtml(meta.title || "(Untitled Feature)")}</div>
          <div class="dbdd-detail-sub">${escapeHtml(meta.description || "")}</div>
        </div>
        <div class="dbdd-detail-right">
          <span class="dbdd-detail-cid">${escapeHtml(shortCid(cid))}</span>
          <a class="dbdd-link" target="_blank" rel="noopener" href="${escapeHtml(gatewayUrl(gateway, cid))}">View raw</a>
        </div>
      </div>

      <pre class="dbdd-code"><code>${escapeHtml(preview)}</code></pre>

      <div class="dbdd-detail-actions">
        <button class="dbdd-insert">Insert</button>
        <button class="dbdd-copy">Copy</button>
      </div>
    `;

    $detail.querySelector(".dbdd-insert").onclick = () => {
      insertIntoEditor($editor, text);
      // keep your existing behavior (close modal):contentReference[oaicite:7]{index=7}
      if (window.MicroModal?.close) window.MicroModal.close("feature-picker-modal");
      rememberRecentFeature({ cid, title: meta.title, source: "picker" });
      toast(`Inserted ${shortCid(cid)}`, $toast);
    };

    $detail.querySelector(".dbdd-copy").onclick = async () => {
      try {
        await navigator.clipboard.writeText(text);
        toast("Copied feature to clipboard", $toast);
      } catch {
        toast("Clipboard copy failed", $toast);
      }
    };
  }

  // initial load
  setActiveTab(activeTabId);
  await loadTab();
}

// ----------------------------- data loaders -----------------------------

async function loadSamplesIndex(indexUrl) {
  // Expect JSON either:
  //  - ["Qm..", "bafy..", ...]
  //  - [{ cid, title, subtitle }, ...]
  const res = await fetch(indexUrl, { cache: "no-store" });
  if (!res.ok) throw new Error(`Samples index HTTP ${res.status}`);
  const data = await res.json();

  const arr = Array.isArray(data) ? data : (Array.isArray(data?.items) ? data.items : []);
  return arr.map((x) => {
    if (typeof x === "string") return { cid: x, title: x, subtitle: "Sample" };
    return {
      cid: x.cid || x.hash || x.id,
      title: x.title || x.label || x.name || x.cid,
      subtitle: x.subtitle || x.description || "Sample"
    };
  });
}

function loadRecentRuns() {
  // On-chain first (wallet + any accounts in the wallet selector), then fall back to localStorage.
  return loadOnchainRecentRuns({
    storageKey: LS_ACTIVITY_FILTER,
    featureLimit: 30,
    perAccountActivities: 18
  }).catch(() => loadRecentRunsFromLocal());
}

function loadRecentRunsFromLocal() {
  const rec = loadJSON(LS_RECENT_FEATURES, []);
  // newest first
  return rec
    .slice()
    .sort((a, b) => Number(b.whenMs || 0) - Number(a.whenMs || 0))
    .map((x) => ({
      cid: x.cid,
      title: x.title || x.cid,
      subtitle: x.reportCid ? `Report: ${shortCid(x.reportCid)}` : "Recently run",
      whenMs: x.whenMs || null,
      reportCid: x.reportCid || null
    }));
}

// ----------------------------- on-chain recents -----------------------------

async function loadOnchainRecentRuns({ storageKey, featureLimit = 30, perAccountActivities = 18 } = {}) {
  const accounts = await getAccountsForOnchainRecents(storageKey);
  if (!accounts.length) {
    // No wallet available — fall back to local recents.
    return loadRecentRunsFromLocal();
  }

  // Fetch activities for all accounts (bounded), then pull tx details only for the newest ones.
  const pages = await Promise.all(
    accounts.map((ak) => getAccountActivities({ accountId: ak, limit: perAccountActivities }).catch(() => null))
  );

  const acts = [];
  for (let i = 0; i < pages.length; i++) {
    const p = pages[i];
    const ak = accounts[i];
    const data = Array.isArray(p?.data) ? p.data : [];
    for (const a of data) {
      const txHash = a?.tx_hash || a?.txHash || null;
      const micro = a?.micro_time || a?.microTime || null;
      if (!txHash) continue;
      acts.push({ txHash: String(txHash), whenMs: toMsOrNull(micro), accountId: ak });
    }
  }

  // newest first
  acts.sort((a, b) => Number(b.whenMs || 0) - Number(a.whenMs || 0));

  // Pull tx-full for the newest tx hashes until we have enough unique features.
  const seenFeatures = new Set();
  const out = [];

  for (const a of acts) {
    if (out.length >= featureLimit) break;

    let txFull = null;
    try {
      txFull = await getTxFull(a.txHash);
    } catch {
      continue;
    }

    const spend = await normalizeDamageSpend(txFull).catch(() => null);
    if (!spend?.featureCid) continue;
    if (seenFeatures.has(spend.featureCid)) continue;

    seenFeatures.add(spend.featureCid);

    // Prefer a cheap title fetch; detail panel will fetch full feature anyway.
    const featureTitle = await fetchTextFirstLine(`/features/${encodeURIComponent(spend.featureCid)}`).catch(
      () => spend.featureCid
    );

    out.push({
      cid: spend.featureCid,
      title: featureTitle || spend.featureCid,
      subtitle: `On-chain • ${shortCid(a.accountId)}${spend.reportCid ? ` • Report ${shortCid(spend.reportCid)}` : ""}`,
      whenMs: spend.createdMs || a.whenMs || null,
      reportCid: spend.reportCid || null
    });
  }

  if (!out.length) return loadRecentRunsFromLocal();
  return out;
}

async function getAccountsForOnchainRecents(storageKey) {
  const out = [];

  // 1) Primary wallet (TokenManager)
  try {
    const w = await window.TokenManager?.getAddress?.();
    if (typeof w === "string" && w.startsWith("ak_")) out.push(w);
  } catch {}

  // 2) AccountFilter wallets used elsewhere (reports/activity tab)
  try {
    const stored = loadJSON(storageKey || LS_ACTIVITY_FILTER, null);
    const ids = extractAccountIdsFromFilterState(stored);
    for (const id of ids) if (typeof id === "string" && id.startsWith("ak_")) out.push(id);
  } catch {}

  // uniq, preserve order
  return Array.from(new Set(out));
}

function extractAccountIdsFromFilterState(stored) {
  if (!stored) return [];
  // Be liberal: AccountFilter implementations vary.
  // Common shapes:
  //  - { items: [{id, ...}, ...] }
  //  - { selected: [{id,...}], primary: "ak_..." }
  //  - [{id,...}, ...]
  const acc = [];

  const add = (v) => {
    if (!v) return;
    const s = String(v).trim();
    if (!s) return;
    acc.push(s);
  };

  if (Array.isArray(stored)) {
    for (const x of stored) add(x?.id || x?.value || x);
    return acc;
  }

  if (typeof stored === "object") {
    add(stored.primary);
    const arrays = [stored.items, stored.selected, stored.tags, stored.values, stored.addresses];
    for (const arr of arrays) {
      if (!Array.isArray(arr)) continue;
      for (const x of arr) add(x?.id || x?.value || x);
    }
  }

  return acc;
}

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

async function getAccountActivities({ accountId, limit = 10, pagePath = null } = {}) {
  const base = String(MDW_BASE || "").replace(/\/$/, "");
  const url = pagePath
    ? `${base}${pagePath}`
    : `${base}/v3/accounts/${encodeURIComponent(accountId)}/activities?direction=backward&limit=${encodeURIComponent(limit)}`;
  return fetchJSON(url);
}

async function getTxFull(txHash) {
  const base = String(MDW_BASE || "").replace(/\/$/, "");
  return fetchJSON(`${base}/v3/transactions/${encodeURIComponent(txHash)}`);
}

function toMsOrNull(microTime) {
  if (!microTime) return null;
  const n = Number(microTime);
  if (!Number.isFinite(n)) return null;
  return n > 1e12 ? n : Math.floor(n / 1000);
}

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

// Keep aligned with reports.js normalization: DAMAGE spend(tx args: amount, featureCid, reportCid)
async function normalizeDamageSpend(txFull) {
  const inner = txFull?.tx?.tx?.tx || txFull?.tx?.tx || txFull?.tx || null;
  if (!inner) return null;
  if (inner.function !== "spend") return null;

  const args = extractTxArguments(txFull);
  const featureCid = typeof args?.[2]?.value === "string" ? args[2].value : null;
  const reportCid = typeof args?.[3]?.value === "string" ? args[3].value : null;
  if (!featureCid) return null;

  const createdMs = toMsOrNull(txFull?.micro_time || inner?.micro_time);
  return { createdMs, featureCid, reportCid };
}

// ----------------------------- helpers -----------------------------

async function fetchFeature(cid, gateway) {
  // If gateway is "/features/" => "/features/<cid>"
  // If gateway is "https://.../ipfs" => "https://.../ipfs/<cid>"
  const url = gatewayUrl(gateway, cid);
  const res = await fetch(url, { mode: "cors" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  const meta = parseGherkinHead(text);
  return { text, meta };
}

function gatewayUrl(gateway, cid) {
  const g = String(gateway || "").trim();
  if (!g) return cid;
  if (g.endsWith("/")) return g + cid;
  return g + "/" + cid;
}

// Extract "summary from the head": the Feature line + its contiguous description lines
function parseGherkinHead(text) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");

  let featureIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^Feature\s*:/.test(s)) { featureIdx = i; break; }
  }

  let title = "";
  let description = "";
  if (featureIdx >= 0) {
    title = lines[featureIdx].replace(/^\s*Feature\s*:\s*/i, "").trim();
    const descLines = [];
    for (let j = featureIdx + 1; j < lines.length; j++) {
      const raw = lines[j];
      const t = raw.trim();
      if (!t) { if (descLines.length) break; else continue; }
      if (/^(Scenario|Background|Rule)\s*:/.test(t)) break;
      if (/^(#|@)/.test(t)) continue;
      descLines.push(raw.trim());
      if (descLines.join(" ").length > 240) break;
    }
    description = descLines.join(" ").trim();
  }

  const headSnippet = lines.slice(Math.max(0, featureIdx), Math.min(lines.length, featureIdx + 18)).join("\n");
  return { title, description, headSnippet };
}

function insertIntoEditor(el, text) {
  if (!el) return;
  if ("value" in el) el.value = text;
  else el.textContent = text;
  el.dispatchEvent(new Event("input", { bubbles: true }));
}

function shortCid(cid) {
  cid = String(cid || "");
  if (cid.length <= 16) return cid;
  return cid.slice(0, 8) + "…" + cid.slice(-6);
}

function toast(msg, $toast) {
  if (!$toast) return;
  $toast.hidden = false;
  $toast.textContent = msg;
  $toast.classList.add("show");
  clearTimeout($toast._t);
  $toast._t = setTimeout(() => {
    $toast.classList.remove("show");
    $toast.hidden = true;
  }, 1600);
}

function escapeHtml(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function cssEscape(s) {
  return String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}

function loadJSON(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key) || ""); }
  catch { return fallback; }
}

function saveJSON(key, val) {
  localStorage.setItem(key, JSON.stringify(val));
}

let __dbddPickerStyles = false;
function injectStylesOnce() {
  if (__dbddPickerStyles) return;
  __dbddPickerStyles = true;

  const css = `
  .dbdd-picker{
    font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji","Segoe UI Emoji";
    color: rgba(231,233,238,.95);
  }
  .dbdd-header{
    display:flex; align-items:center; justify-content:space-between;
    gap:12px; padding:12px 12px 10px;
  }
  .dbdd-title{ font-weight:700; letter-spacing:.2px; }
  .dbdd-actions{ display:flex; gap:8px; align-items:center; }
  .dbdd-search{
    width:min(340px, 52vw);
    background: rgba(255,255,255,.06);
    border: 1px solid rgba(255,255,255,.10);
    color: inherit;
    border-radius: 12px;
    padding: 10px 12px;
    outline: none;
  }
  .dbdd-search:focus{ border-color: rgba(255,255,255,.22); }
  .dbdd-refresh{
    width:40px; height:40px;
    border-radius: 12px;
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(255,255,255,.06);
    color: inherit;
    cursor:pointer;
  }
  .dbdd-refresh:hover{ background: rgba(255,255,255,.09); }

  .dbdd-tabs{
    display:flex; gap:8px;
    padding: 0 12px 12px;
    flex-wrap: wrap;
  }
  .dbdd-tab{
    display:flex; align-items:center; gap:8px;
    padding: 8px 10px;
    border-radius: 999px;
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(255,255,255,.05);
    color: inherit;
    cursor:pointer;
    user-select:none;
  }
  .dbdd-tab:hover{ background: rgba(255,255,255,.08); }
  .dbdd-tab.active{
    background: rgba(255,255,255,.12);
    border-color: rgba(255,255,255,.22);
  }
  .dbdd-tab-ico{ opacity:.9; }
  .dbdd-tab-count{
    margin-left: 2px;
    font-size: 12px;
    padding: 2px 8px;
    border-radius: 999px;
    background: rgba(0,0,0,.28);
    border: 1px solid rgba(255,255,255,.10);
  }

  .dbdd-body{
    display:grid;
    grid-template-columns: 340px 1fr;
    gap: 12px;
    padding: 0 12px 12px;
    min-height: 440px;
  }
  @media (max-width: 860px){
    .dbdd-body{ grid-template-columns: 1fr; }
  }

  .dbdd-list{
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(255,255,255,.03);
    border-radius: 16px;
    overflow: hidden;
    min-height: 360px;
  }

  .dbdd-card{
    padding: 12px 12px;
    border-bottom: 1px solid rgba(255,255,255,.08);
    cursor:pointer;
  }
  .dbdd-card:hover{ background: rgba(255,255,255,.05); }
  .dbdd-card.selected{ background: rgba(255,255,255,.09); }
  .dbdd-card-top{ display:flex; justify-content:space-between; gap:10px; align-items:baseline; }
  .dbdd-card-title{ font-weight: 700; font-size: 13.5px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dbdd-card-when{ font-size: 11.5px; opacity:.75; white-space:nowrap; }
  .dbdd-card-desc{ font-size: 12px; opacity:.80; margin-top: 6px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dbdd-card-cid{ font-size: 11.5px; opacity:.65; margin-top: 6px; }

  .dbdd-detail{
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(255,255,255,.03);
    border-radius: 16px;
    padding: 12px;
    min-height: 360px;
  }
  .dbdd-detail-empty, .dbdd-empty, .dbdd-skel{
    padding: 18px;
    opacity: .78;
  }

  .dbdd-detail-head{
    display:flex; justify-content:space-between; gap:12px; align-items:flex-start;
    padding: 8px 6px 10px;
  }
  .dbdd-detail-title{ font-weight: 800; letter-spacing:.2px; }
  .dbdd-detail-sub{ margin-top: 6px; opacity:.85; font-size: 13px; }
  .dbdd-detail-right{ display:flex; align-items:center; gap:10px; }
  .dbdd-detail-cid{
    font-size: 12px;
    padding: 4px 10px;
    border-radius: 999px;
    background: rgba(0,0,0,.28);
    border: 1px solid rgba(255,255,255,.10);
    opacity:.9;
  }
  .dbdd-link{
    font-size: 12px;
    color: rgba(231,233,238,.95);
    opacity:.85;
    text-decoration: none;
  }
  .dbdd-link:hover{ opacity: 1; text-decoration: underline; }

  .dbdd-code{
    margin: 8px 0 10px;
    padding: 12px;
    border-radius: 14px;
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(0,0,0,.30);
    overflow:auto;
    max-height: 340px;
  }

  .dbdd-detail-actions{
    display:flex; gap:8px; padding: 6px;
  }
  .dbdd-detail-actions button{
    border-radius: 12px;
    border: 1px solid rgba(255,255,255,.10);
    background: rgba(255,255,255,.06);
    color: inherit;
    padding: 10px 12px;
    cursor:pointer;
  }
  .dbdd-detail-actions button:hover{ background: rgba(255,255,255,.09); }

  .dbdd-toast{
    position: fixed;
    left: 50%;
    bottom: 16px;
    transform: translateX(-50%);
    padding: 10px 14px;
    border-radius: 999px;
    background: rgba(0,0,0,.75);
    border: 1px solid rgba(255,255,255,.12);
    color: rgba(231,233,238,.98);
    opacity: 0;
    transition: opacity .18s ease;
    z-index: 9999;
    pointer-events:none;
  }
  .dbdd-toast.show{ opacity: 1; }
  `;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);
}

