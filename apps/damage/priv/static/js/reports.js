/* /static/js/reports.js
 * Minimal history list -> #run-reports (inside #history-tab)
 * Each item: [timestamp] — <first line from feature>  [report link] [aescan tx]
 * Feature CID = arg[2], Report CID = arg[3].
 * Includes Prev/Next pagination using MDW cursors.
 */

(function () {
  "use strict";

  const MDW_BASE = "https://mainnet.aeternity.io/mdw";
  const IPFS_FIRSTLINE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

  // ------------- tiny TTL cache -------------
  const cache = {
    get(k) {
      try {
        const raw = localStorage.getItem(k);
        if (!raw) return null;
        const { v, e } = JSON.parse(raw);
        if (e && Date.now() > e) { localStorage.removeItem(k); return null; }
        return v;
      } catch { return null; }
    },
    set(k, v, ttlMs) {
      try {
        localStorage.setItem(k, JSON.stringify({ v, e: ttlMs ? Date.now() + ttlMs : null }));
      } catch {}
    }
  };

  // ------------- utils -------------
  const qs = (sel, root=document) => root.querySelector(sel);
  const el = (tag, attrs={}, html="") => {
    const e = document.createElement(tag);
    Object.entries(attrs).forEach(([k,v])=>{
      if (k==="style" && v && typeof v==="object") Object.assign(e.style, v);
      else e.setAttribute(k,v);
    });
    if (html) e.innerHTML = html;
    return e;
  };
  const fmtDate = ms => (!ms ? "—" : new Date(ms).toLocaleString());

  async function fetchJSON(url, { retries=2, backoff=300 } = {}) {
    for (let i=0;;i++){
      try{
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
        if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
        return await res.json();
      } catch (e){
        if (i>=retries) throw e;
        await new Promise(r=>setTimeout(r, backoff*(i+1)));
      }
    }
  }

  async function fetchTEXT(url, { retries=1, backoff=250 } = {}) {
    for (let i=0;;i++){
      try{
        const res = await fetch(url, {
          method: "GET",
          cache: "no-store",
          headers: { "Cache-Control": "no-cache, no-store, max-age=0, must-revalidate" }
        });
        if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
        return await res.text();
      } catch (e){
        if (i>=retries) throw e;
        await new Promise(r=>setTimeout(r, backoff*(i+1)));
      }
    }
  }

  async function pMap(items, fn, { concurrency=3 } = {}) {
    const ret=[], inflight=new Set();
    for (const it of items){
      const p=Promise.resolve().then(()=>fn(it));
      ret.push(p); inflight.add(p);
      const done=()=>inflight.delete(p); p.then(done,done);
      if (inflight.size>=concurrency) await Promise.race(inflight);
    }
    return Promise.all(ret);
  }

  function deepFindCall(node){
    if (node && typeof node==="object"){
      if ("arguments" in node) return node;
      for (const k of Object.keys(node)){
        const f=deepFindCall(node[k]); if (f) return f;
      }
    }
    return null;
  }

  function isIpfsCid(str){
    if (typeof str!=="string") return false;
    const v0=/^Qm[1-9A-HJ-NP-Za-km-z]{44}$/;   // base58
    const v1=/^baf[0-9a-z]{20,}$/i;            // base32
    return v0.test(str) || v1.test(str);
  }

  const aescanTxUrl = (txHash) => `https://aescan.io/transactions/${encodeURIComponent(txHash)}`;

  // ------------- data -------------
  async function getAccountActivities({ accountId, limit=10, bypassCache=false, ttlMs=60_000, pagePath=null } = {}) {
    // Support either constructed URL or server-provided cursor path
    const key = pagePath
      ? `ae:act:url:${pagePath}`
      : `ae:act:${accountId}:aex9:backward:${limit}`;
    if (!bypassCache){
      const c=cache.get(key); if (c) return c;
    }
    const url = pagePath
      ? `${MDW_BASE}${pagePath}`
      : `${MDW_BASE}/v3/accounts/${encodeURIComponent(accountId)}/activities?direction=backward&type=aex9&limit=${encodeURIComponent(limit)}`;
    const page = await fetchJSON(url);
    cache.set(key, page, ttlMs);
    return page;
  }

  async function getTxDetail(txHash, { bypassCache=false, ttlMs=3600_000 } = {}) {
    const key = `ae:mdwtx:${txHash}`;
    if (!bypassCache){
      const c=cache.get(key); if (c) return c;
    }
    const url = `${MDW_BASE}/v3/transactions/${encodeURIComponent(txHash)}`;
    const data = await fetchJSON(url);
    const call = deepFindCall(data);
    const args = Array.isArray(call?.arguments) ? call.arguments : [];
    const normalized = {
      tx_hash: data.hash || txHash,
      micro_time: data.micro_time ?? null,
      // Contract convention: args[2] = feature CID, args[3] = report CID
      featureCid: isIpfsCid(args[2]?.value) ? args[2].value : null,
      reportCid:  isIpfsCid(args[3]?.value) ? args[3].value : null
    };
    cache.set(key, normalized, ttlMs);
    return normalized;
  }

  // Cache the feature "first line" locally so subsequent renders are instant
  async function getFeatureFirstLine(cid){
    if (!cid) return "—";
    const k = `ipfs:firstline:${cid}`;
    const cached = cache.get(k);
    if (cached) return cached;

    // Your app should serve raw feature text at this route
    const url = `/features/${encodeURIComponent(cid)}`;
    try {
      const text = await fetchTEXT(url);
      const firstLine = (text || "").split(/\r?\n/)[0] || "—";
      cache.set(k, firstLine, IPFS_FIRSTLINE_TTL_MS);
      return firstLine;
    } catch {
      // Fallback to showing the CID and cache briefly to avoid refetch storms
      cache.set(k, cid, 5 * 60 * 1000);
      return cid;
    }
  }

  // ------------- rendering + pagination -------------
  const state = {
    accountId: null,
    limit: 10,
    bypassCache: false,
    pagePath: null,  // when set, overrides accountId/limit URL
    nextPath: null,
    prevPath: null
  };

  function ensureScaffold() {
    const container = qs("#history-tab");
    if (!container) return null;

    // List
    let ul = qs("#run-reports-list", container);
    if (!ul) {
      ul = el("ul", { id: "run-reports-list", style: "list-style:none; padding-left:0; margin:0;" });
      container.appendChild(ul);
    }

    // Pager
    let pager = qs("#run-reports-pager", container);
    if (!pager) {
      pager = el("div", { id: "run-reports-pager", style: "display:flex; gap:8px; align-items:center; margin-top:8px;" });
      const btnPrev = el("button", { id: "run-reports-prev", type: "button", style: "padding:6px 10px; border:1px solid #e5e7eb; border-radius:8px; background:#fff; cursor:pointer;" }, "◀ Prev");
      const btnNext = el("button", { id: "run-reports-next", type: "button", style: "padding:6px 10px; border:1px solid #e5e7eb; border-radius:8px; background:#fff; cursor:pointer;" }, "Next ▶");
      const spanInfo = el("span", { id: "run-reports-info", style: "color:#6b7280; font-size:12px;" }, "");
      pager.appendChild(btnPrev);
      pager.appendChild(btnNext);
      pager.appendChild(spanInfo);
      container.appendChild(pager);

      btnPrev.addEventListener("click", () => {
        if (!state.prevPath) return;
        state.pagePath = state.prevPath;
        renderPage();
      });
      btnNext.addEventListener("click", () => {
        if (!state.nextPath) return;
        state.pagePath = state.nextPath;
        renderPage();
      });
    }
    return { container, ul, pager };
  }

  function setPagerEnabled() {
    const btnPrev = qs("#run-reports-prev");
    const btnNext = qs("#run-reports-next");
    const spanInfo = qs("#run-reports-info");
    if (btnPrev) {
      btnPrev.disabled = !state.prevPath;
      btnPrev.style.opacity = state.prevPath ? "1.0" : "0.5";
      btnPrev.style.cursor = state.prevPath ? "pointer" : "not-allowed";
    }
    if (btnNext) {
      btnNext.disabled = !state.nextPath;
      btnNext.style.opacity = state.nextPath ? "1.0" : "0.5";
      btnNext.style.cursor = state.nextPath ? "pointer" : "not-allowed";
    }
    if (spanInfo) {
      // Show which direction we’re going (backward chronology) and limit
      spanInfo.textContent = `Showing ${state.limit} (direction=backward)`;
    }
  }

  async function renderPage() {
    const parts = ensureScaffold();
    if (!parts) { console.warn("reports.js: #history-tab not found"); return; }
    const { ul } = parts;

    ul.innerHTML = `<li style="padding:8px 0; color:#6b7280;">Loading…</li>`;
    setPagerEnabled();

    // 1) activities (by cursor or by base URL)
    const page = await getAccountActivities({
      accountId: state.accountId,
      limit: state.limit,
      bypassCache: state.bypassCache,
      pagePath: state.pagePath
    });

    // Update cursor pointers for pager
    state.nextPath = page?.next || null;
    state.prevPath = page?.prev || null;
    setPagerEnabled();

    const items = Array.isArray(page?.data) ? page.data.slice(0, state.limit) : [];
    const hashes = items.map(i => i?.payload?.tx_hash).filter(Boolean);
    if (hashes.length === 0){
      ul.innerHTML = `<li style="padding:8px 0;">No transactions.</li>`;
      return;
    }

    // 2) tx details
    const details = await pMap(hashes, h => getTxDetail(h, { bypassCache: state.bypassCache }).catch(() => null), { concurrency: 3 });

    // 3) feature first lines
    const rows = await pMap(details.map((d,i)=>({ d, i })), async ({ d, i }) => {
      if (!d) return null;
      const firstLine = await getFeatureFirstLine(d.featureCid);
      return {
        time: items[i]?.payload?.micro_time ?? d.micro_time,
        firstLine,
        reportCid: d.reportCid,
        txHash: d.tx_hash
      };
    }, { concurrency: 3 });

    // 4) render
    ul.innerHTML = "";
    rows.filter(Boolean).forEach(row => {
      const li = el("li", { style: "padding:10px 0; border-bottom:1px solid #f3f4f6;" });
      const timeHtml = `<span style="color:#6b7280;">${fmtDate(row.time)}</span>`;
      const featureTxt = row.featureCid
			? ` <a href="/features/${encodeURIComponent(row.featureCid)}" target="_blank" rel="noopener" style="text-decoration:underline;">${row.firstLine}</a>`
        : "";
      const reportHtml = row.reportCid
        ? ` <a href="/reports/${encodeURIComponent(row.reportCid)}" target="_blank" rel="noopener" style="text-decoration:underline;">report</a>`
        : "";
      const txHtml = row.txHash
        ? ` <a href="${aescanTxUrl(row.txHash)}" target="_blank" rel="noopener">aescan</a>`
        : "";
      li.innerHTML = `${timeHtml} — ${featureTxt}${reportHtml ? " — " + reportHtml : ""}${txHtml ? " — " + txHtml : ""}`;
      ul.appendChild(li);
    });
  }

  // ------------- public API -------------
  async function renderRunReports(accountId, { limit=10, bypassCache=false } = {}) {
    state.accountId = accountId;
    state.limit = limit;
    state.bypassCache = bypassCache;
    state.pagePath = null; // start from head (newest)
    await renderPage();
  }

  window.Reports = { renderRunReports };

  // Auto-mount using the stored address, if present
  document.addEventListener("DOMContentLoaded", () => {
    const acct = localStorage.getItem("address");
    if (acct) renderRunReports(acct, { limit: 10, bypassCache: true });
  });
})();

