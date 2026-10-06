/* IPFS File Picker - standalone ES module
 *
 * - Injects its own MicroModal-compatible HTML
 * - Uses window.MicroModal if present, else minimal open/close fallback
 * - Browses immutable /ipfs/<cid>/... paths
 * - Recents + pinned stored in localStorage
 *
 * Uses DamageBDD's same-origin IPFS browser API by default:
 *   POST /api/ipfs/ls  {"path":"/ipfs/<cid>/..."}
 *
 * Direct Kubo upload support is optional and disabled in the dashboard
 * integration. This keeps the browser away from the node's loopback-only
 * Kubo control API.
 */
const LS_RECENTS = "ipfsfp_recents_v1";
const LS_PINNED  = "ipfsfp_pinned_v1";

function escapeHtml(s){
  return String(s)
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#039;");
}

function normalizePath(p){
  if (!p) return "/ipfs/";
  p = String(p).trim();
  if (p.startsWith("ipfs://")) p = "/ipfs/" + p.slice("ipfs://".length);
  if (!p.startsWith("/")) p = "/" + p;
  p = p.replace(/\/{2,}/g, "/");
  if (p === "/ipfs") p = "/ipfs/";
  return p;
}

function isRoot(p){ p = normalizePath(p); return p === "/ipfs/"; }
function isIpfsPath(p){ p = normalizePath(p); return p.startsWith("/ipfs/") && !isRoot(p); }

function parentPath(p){
  p = normalizePath(p);
  if (isRoot(p)) return p;
  if (p.endsWith("/") && p.length > 1) p = p.slice(0, -1);
  const i = p.lastIndexOf("/");
  if (i <= 0) return "/ipfs/";
  return p.slice(0, i + 1);
}

function loadJSON(key, fallback){
  try { return JSON.parse(localStorage.getItem(key) || ""); }
  catch { return fallback; }
}

function saveJSON(key, val){ localStorage.setItem(key, JSON.stringify(val)); }

function addRecent(path){
  path = normalizePath(path);
  const rec = loadJSON(LS_RECENTS, []);
  const next = [path, ...rec.filter(x => x !== path)].slice(0, 20);
  saveJSON(LS_RECENTS, next);
}

function togglePinned(path){
  path = normalizePath(path);
  const pins = new Set(loadJSON(LS_PINNED, []));
  if (pins.has(path)) pins.delete(path); else pins.add(path);
  saveJSON(LS_PINNED, Array.from(pins));
  return pins.has(path);
}

function isPinned(path){
  const pins = new Set(loadJSON(LS_PINNED, []));
  return pins.has(normalizePath(path));
}

function fmtBytes(n){
  if (n === 0) return "0 B";
  if (!n || n < 0) return "";
  const u = ["B","KB","MB","GB","TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const v = n / Math.pow(1024, i);
  return (v >= 10 || i === 0) ? `${Math.round(v)} ${u[i]}` : `${v.toFixed(1)} ${u[i]}`;
}

function damageAuthHeaders(extra = {}){
  const headers = new Headers(extra);
  const token = window.TokenManager?.getToken?.();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  return headers;
}

async function ipfsLs(apiBase, ipfsPath){
  const path = normalizePath(ipfsPath);
  if (!isIpfsPath(path)) throw new Error("Enter an immutable /ipfs/<cid> path.");
  const url = apiBase.replace(/\/$/, "") + "/ls";
  const res = await fetch(url, {
    method: "POST",
    credentials: "include",
    headers: damageAuthHeaders({
      "Content-Type": "application/json",
      "Accept": "application/json"
    }),
    body: JSON.stringify({ path })
  });
  if (!res.ok) throw new Error(`ls failed: ${res.status}`);
  const data = await res.json();

  const links = Array.isArray(data.links) ? data.links : [];
  return links.map(l => ({
    name: l.name || l.Name || "",
    hash: l.hash || l.Hash || "",
    size: typeof (l.size ?? l.Size) === "number" ? (l.size ?? l.Size) : null,
    type: (l.type || l.kind) === "dir" ? "dir" : "file"
  }));
}

async function ipfsAdd(apiBase, file){
  const url = apiBase.replace(/\/$/, "") + "/api/v0/add?pin=true&wrap-with-directory=false";
  const fd = new FormData();
  fd.append("file", file, file.name);
  const res = await fetch(url, { method: "POST", body: fd });
  if (!res.ok) throw new Error(`add failed: ${res.status}`);
  // Kubo returns NDJSON lines
  const text = await res.text();
  const lines = text.trim().split("\n").filter(Boolean);
  return JSON.parse(lines[lines.length - 1]); // { Name, Hash, Size }
}

function buildModalHtml(modalId){
  return `
<div class="modal micromodal-slide ipfsfp" id="${escapeHtml(modalId)}" aria-hidden="true">
  <div class="modal__overlay" tabindex="-1" data-micromodal-close>
    <div class="modal__container" role="dialog" aria-modal="true" aria-labelledby="${escapeHtml(modalId)}-title">
      <aside class="ipfsfp-side">
        <div class="ipfsfp-title">
          <div>IPFS Picker</div>
          <div class="ipfsfp-pill" data-ipfsfp-node>node</div>
        </div>

        <div class="ipfsfp-nav">
          <button type="button" data-ipfsfp-tab="browse" class="active">📁 Browse</button>
          <button type="button" data-ipfsfp-tab="recents">🕘 Recents</button>
          <button type="button" data-ipfsfp-tab="pinned">⭐ Pinned</button>
          <button type="button" data-ipfsfp-tab="upload">⬆️ Upload</button>
        </div>

        <div class="ipfsfp-sep"></div>

        <div class="ipfsfp-kv">
          <div class="ipfsfp-mini">Start path</div>
          <input type="text" data-ipfsfp-startpath value="/ipfs/" placeholder="/ipfs/<cid>/path/to.feature" />
          <div class="ipfsfp-rowbtn">
            <button type="button" data-ipfsfp-go>Go</button>
            <button type="button" data-ipfsfp-up>Up</button>
          </div>
          <button type="button" data-ipfsfp-usepath>Use feature path</button>
        </div>

        <div class="ipfsfp-sep"></div>

        <div class="ipfsfp-mini">
          Double-click folders to open. Double-click files to select.<br/>
          Recents + pinned are stored locally in your browser.
        </div>
      </aside>

      <main class="ipfsfp-main">
        <div class="ipfsfp-topbar">
          <div class="ipfsfp-crumbs">
            <button type="button" data-ipfsfp-back>←</button>
            <button type="button" data-ipfsfp-forward>→</button>
            <button type="button" data-ipfsfp-refresh>↻</button>
            <div class="ipfsfp-path" data-ipfsfp-path>/ipfs/</div>
          </div>
          <div class="ipfsfp-actions">
            <button type="button" data-ipfsfp-copy>Copy path</button>
            <button type="button" aria-label="Close" data-micromodal-close>✕</button>
          </div>
        </div>

        <div class="ipfsfp-searchbar">
          <input type="search" data-ipfsfp-search placeholder="Search in folder…" />
          <div class="ipfsfp-hint" data-ipfsfp-status>Ready</div>
        </div>

        <div class="ipfsfp-list" data-ipfsfp-list></div>

        <div class="ipfsfp-footer">
          <div class="ipfsfp-selection" data-ipfsfp-selection>No selection</div>
          <div class="right">
            <button type="button" data-micromodal-close>Cancel</button>
            <button type="button" class="primary" data-ipfsfp-select disabled>Select</button>
          </div>
        </div>
      </main>
    </div>
  </div>
</div>`;
}

/**
 * Create an IPFS file picker instance.
 *
 * @param {object} opts
 * @param {string} [opts.apiBase="/api/ipfs"] DamageBDD same-origin IPFS browser API
 * @param {string} [opts.modalId="ipfs-filepicker-modal"]
 * @param {boolean} [opts.allowFolders=false] Allow selecting folders
 * @param {boolean} [opts.allowUpload=false] Show direct Kubo upload tab
 * @param {string|null} [opts.uploadApiBase=null] Direct Kubo API base for upload when enabled
 */
export function createIpfsFilePicker(opts = {}){
  const apiBaseDefault = opts.apiBase || "/api/ipfs";
  const modalId = opts.modalId || "ipfs-filepicker-modal";
  const allowFolders = !!opts.allowFolders;
  const allowUpload = !!opts.allowUpload;
  const uploadApiBase = opts.uploadApiBase || null;

  // Inject modal once
  let modal = document.getElementById(modalId);
  if (!modal){
    const wrap = document.createElement("div");
    wrap.innerHTML = buildModalHtml(modalId);
    document.body.appendChild(wrap.firstElementChild);
    modal = document.getElementById(modalId);
  }

  const $ = (sel) => modal.querySelector(sel);
  const $$ = (sel) => Array.from(modal.querySelectorAll(sel));

  const els = {
    node: modal.querySelector("[data-ipfsfp-node]"),
    tabBtns: $$("[data-ipfsfp-tab]"),
    startPath: modal.querySelector("[data-ipfsfp-startpath]"),
    go: modal.querySelector("[data-ipfsfp-go]"),
    up: modal.querySelector("[data-ipfsfp-up]"),
    usePath: modal.querySelector("[data-ipfsfp-usepath]"),
    back: modal.querySelector("[data-ipfsfp-back]"),
    forward: modal.querySelector("[data-ipfsfp-forward]"),
    refresh: modal.querySelector("[data-ipfsfp-refresh]"),
    path: modal.querySelector("[data-ipfsfp-path]"),
    copy: modal.querySelector("[data-ipfsfp-copy]"),
    search: modal.querySelector("[data-ipfsfp-search]"),
    status: modal.querySelector("[data-ipfsfp-status]"),
    list: modal.querySelector("[data-ipfsfp-list]"),
    selection: modal.querySelector("[data-ipfsfp-selection]"),
    select: modal.querySelector("[data-ipfsfp-select]")
  };

  const state = {
    apiBase: apiBaseDefault,
    uploadApiBase,
    allowFolders,
    allowUpload,
    tab: "browse",
    path: "/ipfs/",
    entries: [],
    filtered: [],
    selected: null, // {path,name,type,size,hash}
    history: [],
    histPos: -1,
    onSelect: null
  };

  const uploadTab = modal.querySelector('[data-ipfsfp-tab="upload"]');
  if (uploadTab && !state.allowUpload) uploadTab.hidden = true;

  function setStatus(s){ els.status.textContent = s; }

  function setActiveTab(tab){
    state.tab = tab;
    els.tabBtns.forEach(b => b.classList.toggle("active", b.dataset.ipfsfpTab === tab));
    clearSelection();
    render();
  }

  function pushHistory(p){
    state.history = state.history.slice(0, state.histPos + 1);
    state.history.push(p);
    state.histPos++;
    updateNavButtons();
  }

  function updateNavButtons(){
    els.back.disabled = state.histPos <= 0;
    els.forward.disabled = state.histPos >= state.history.length - 1;
  }

  function setPath(p, push=true){
    p = normalizePath(p);
    state.path = p;
    els.path.textContent = p;
    els.startPath.value = p;
    if (push) pushHistory(p);
  }

  function clearSelection(){
    state.selected = null;
    els.selection.textContent = "No selection";
    els.select.classList.add("disabled");
    els.select.disabled = true;
  }

  function selectEntry(entry){
    state.selected = entry;
    els.selection.textContent = entry.path + (entry.type === "dir" ? " (folder)" : "");
    const ok = entry.type === "file" || (state.allowFolders && entry.type === "dir");
    els.select.disabled = !ok;
    els.select.classList.toggle("disabled", !ok);
  }

  function iconFor(type){ return type === "dir" ? "📁" : "📄"; }

  async function refreshBrowse(){
    clearSelection();
    els.search.value = "";
    const p = normalizePath(state.path);

    setStatus("Loading…");

    try{
      if (p === "/ipfs/"){
        state.entries = [];
        els.list.innerHTML = `
          <div style="padding:18px;color:rgba(231,233,238,.75)">
            Paste an immutable CID or feature path into <b>Start path</b>, then hit <b>Go</b>.<br/>
            Example: <code>/ipfs/&lt;cid&gt;/features/login.feature</code>
          </div>`;
        setStatus("Enter a CID");
        return;
      }

      const links = await ipfsLs(state.apiBase, p);
      const sorted = links.sort((a,b) => (a.type === b.type) ? a.name.localeCompare(b.name) : (a.type === "dir" ? -1 : 1));
      state.entries = sorted.map(e => ({
        ...e,
        path: (p.endsWith("/") ? p : (p + "/")) + e.name + (e.type === "dir" ? "/" : "")
      }));

      addRecent(p);
      setStatus(`${state.entries.length} items`);
      renderListFrom(state.entries);
    }catch(e){
      state.entries = [];
      els.list.innerHTML = `<div style="padding:18px;color:rgba(231,233,238,.75)">Error: ${escapeHtml(e.message)}</div>`;
      setStatus("Error");
    }
  }

  function renderListFrom(entries){
    const q = (els.search.value || "").toLowerCase().trim();
    const filtered = q ? entries.filter(e => (e.name || e.path).toLowerCase().includes(q)) : entries.slice();

    els.list.innerHTML = "";

    if (!filtered.length){
      els.list.innerHTML = `<div style="padding:18px;color:rgba(231,233,238,.75)">No items</div>`;
      return;
    }

    filtered.forEach((e, idx) => {
      const pin = isPinned(e.path);
      const row = document.createElement("div");
      row.className = "ipfsfp-item";
      row.dataset.idx = String(idx);
      row.innerHTML = `
        <div>${iconFor(e.type)}</div>
        <div style="min-width:0">
          <div class="ipfsfp-name">${escapeHtml(e.name || e.path)}</div>
          <div class="ipfsfp-sub">${escapeHtml(e.hash || e.path)}</div>
        </div>
        <div class="ipfsfp-size">${e.size != null ? fmtBytes(e.size) : ""}</div>
        <div class="ipfsfp-type">${e.type === "dir" ? "Folder" : "File"}</div>
        <div class="ipfsfp-star"><button type="button" title="Pin">${pin ? "★" : "☆"}</button></div>
      `;

      row.addEventListener("click", () => {
        selectEntry(e);
        Array.from(els.list.querySelectorAll(".ipfsfp-item")).forEach(x => x.classList.remove("selected"));
        row.classList.add("selected");
      });

      row.addEventListener("dblclick", async () => {
        if (e.type === "dir"){
          setPath(e.path, true);
          await refreshBrowse();
        } else {
          selectEntry(e);
          confirmSelection();
        }
      });

      row.querySelector("button").addEventListener("click", (ev) => {
        ev.stopPropagation();
        const nowPinned = togglePinned(e.path);
        ev.currentTarget.textContent = nowPinned ? "★" : "☆";
      });

      els.list.appendChild(row);
    });
  }

  function render(){
    if (state.tab === "browse"){
      refreshBrowse();
      return;
    }

    clearSelection();

    if (state.tab === "recents"){
      const rec = loadJSON(LS_RECENTS, []);
      setStatus("Recents");
      const entries = rec.map(p => ({
        name: p.split("/").filter(Boolean).slice(-1)[0] || p,
        hash: "",
        size: null,
        type: p.endsWith("/") ? "dir" : "file",
        path: p
      }));
      renderListFrom(entries);
      return;
    }

    if (state.tab === "pinned"){
      const pins = loadJSON(LS_PINNED, []);
      setStatus("Pinned");
      const entries = pins.map(p => ({
        name: p.split("/").filter(Boolean).slice(-1)[0] || p,
        hash: "",
        size: null,
        type: p.endsWith("/") ? "dir" : "file",
        path: p
      }));
      renderListFrom(entries);
      return;
    }

    if (state.tab === "upload"){
      if (!state.allowUpload || !state.uploadApiBase){
        setStatus("Upload disabled");
        els.list.innerHTML = `
          <div style="padding:18px;color:rgba(231,233,238,.75)">
            Browser uploads are disabled on this node. Add the feature to IPFS through
            your normal publication workflow, then paste its CID above.
          </div>`;
        return;
      }
      setStatus("Upload");
      els.list.innerHTML = `
        <div style="padding:18px;border:1px dashed rgba(255,255,255,.18);border-radius:12px;margin:10px;">
          <div style="font-weight:900;margin-bottom:8px;">Upload a local file to IPFS</div>
          <div style="color:rgba(231,233,238,.75);font-size:12px;margin-bottom:12px;">
            Uses <code>/api/v0/add</code> on your configured IPFS node.
          </div>
          <input data-ipfsfp-upload type="file" />
          <div data-ipfsfp-uploadout style="margin-top:12px;font-size:12px;color:rgba(231,233,238,.8);"></div>
        </div>
      `;
      const inp = modal.querySelector("[data-ipfsfp-upload]");
      const out = modal.querySelector("[data-ipfsfp-uploadout]");
      inp.addEventListener("change", async () => {
        if (!inp.files || !inp.files[0]) return;
        out.textContent = "Uploading…";
        try{
          const r = await ipfsAdd(state.uploadApiBase, inp.files[0]);
          const p = "/ipfs/" + r.Hash;
          out.innerHTML = `Added: <code>${escapeHtml(p)}</code> (${fmtBytes(parseInt(r.Size,10) || 0)})`;
          addRecent(p);
          // jump to new CID and switch back to browse
          setActiveTab("browse");
          setPath(p, true);
          await refreshBrowse();
        }catch(e){
          out.textContent = "Upload failed: " + e.message;
        }
      });
      return;
    }
  }

  function confirmSelection(){
    if (!state.selected) return;
    const ok = state.selected.type === "file" || (state.allowFolders && state.selected.type === "dir");
    if (!ok) return;

    addRecent(state.selected.path);
    close();

    if (typeof state.onSelect === "function"){
      state.onSelect({ ...state.selected });
    }
  }

  // --- controls ---
  els.tabBtns.forEach(btn => btn.addEventListener("click", () => setActiveTab(btn.dataset.ipfsfpTab)));

  els.go.addEventListener("click", async () => { setPath(els.startPath.value, true); await refreshBrowse(); });
  els.up.addEventListener("click", async () => { setPath(parentPath(state.path), true); await refreshBrowse(); });
  els.usePath?.addEventListener("click", () => {
    const path = normalizePath(els.startPath.value || state.path);
    if (!isIpfsPath(path)) {
      setStatus("Enter an immutable /ipfs/<cid> feature path");
      return;
    }
    state.selected = {
      path,
      name: path.split("/").filter(Boolean).slice(-1)[0] || path,
      hash: path.split("/").filter(Boolean)[1] || "",
      size: null,
      type: "file"
    };
    confirmSelection();
  });

  els.refresh.addEventListener("click", refreshBrowse);

  els.back.addEventListener("click", async () => {
    if (state.histPos > 0){
      state.histPos--;
      const p = state.history[state.histPos];
      state.path = p;
      els.path.textContent = p;
      els.startPath.value = p;
      updateNavButtons();
      await refreshBrowse();
    }
  });

  els.forward.addEventListener("click", async () => {
    if (state.histPos < state.history.length - 1){
      state.histPos++;
      const p = state.history[state.histPos];
      state.path = p;
      els.path.textContent = p;
      els.startPath.value = p;
      updateNavButtons();
      await refreshBrowse();
    }
  });

  els.copy.addEventListener("click", async () => {
    const text = state.selected ? state.selected.path : state.path;
    try { await navigator.clipboard.writeText(text); setStatus("Copied"); }
    catch { setStatus("Copy failed"); }
    setTimeout(() => setStatus("Ready"), 800);
  });

  els.search.addEventListener("input", () => {
    // re-render current view list from cached data
    if (state.tab === "browse") renderListFrom(state.entries);
    if (state.tab === "recents") {
      const rec = loadJSON(LS_RECENTS, []);
      renderListFrom(rec.map(p => ({ name:p.split("/").filter(Boolean).slice(-1)[0]||p, hash:"", size:null, type:p.endsWith("/")?"dir":"file", path:p })));
    }
    if (state.tab === "pinned") {
      const pins = loadJSON(LS_PINNED, []);
      renderListFrom(pins.map(p => ({ name:p.split("/").filter(Boolean).slice(-1)[0]||p, hash:"", size:null, type:p.endsWith("/")?"dir":"file", path:p })));
    }
  });

  els.select.addEventListener("click", confirmSelection);

  // Fallback close (if MicroModal not present, overlay click closes via our handler)
  modal.addEventListener("click", (e) => {
    const overlay = modal.querySelector(".modal__overlay");
    if (e.target === overlay) close();
  });

  window.addEventListener("keydown", (e) => {
    if (!isOpen()) return;
    if (e.key === "Escape") close();
    if (e.key === "Enter") confirmSelection();
  });

  // --- modal open/close integration ---
  const hasMicroModal = typeof window !== "undefined" && window.MicroModal && typeof window.MicroModal.show === "function";

  function isOpen(){
    return modal.classList.contains("is-open") || modal.getAttribute("aria-hidden") === "false";
  }

  function open({ onSelect, startPath, apiBase } = {}){
    state.onSelect = onSelect || null;
    state.apiBase = apiBase || state.apiBase;
    els.node.textContent = state.apiBase;

    const start = normalizePath(startPath || els.startPath.value || "/ipfs/");
    state.history = [];
    state.histPos = -1;
    setPath(start, true);
    setActiveTab("browse");

    if (hasMicroModal){
      window.MicroModal.show(modalId, { awaitOpenAnimation: false, awaitCloseAnimation: false, disableScroll: true });
    } else {
      modal.classList.add("is-open");
      modal.setAttribute("aria-hidden", "false");
      document.body.style.overflow = "hidden";
    }

    setTimeout(() => els.search.focus(), 30);
  }

  function close(){
    if (hasMicroModal){
      window.MicroModal.close(modalId);
    } else {
      modal.classList.remove("is-open");
      modal.setAttribute("aria-hidden", "true");
      document.body.style.overflow = "";
    }
    clearSelection();
    setStatus("Ready");
  }

  return { open, close, refresh: refreshBrowse, element: modal };
}
