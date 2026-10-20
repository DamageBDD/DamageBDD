import { TokenManager } from "/ecai/auth-assets/js/wallet-switcher.js";

const $ = id => document.getElementById(id);
const state = { type: "file", file: null, analysis: null, source: null, busy: false, queued: false, key: "", jobId: "" };

function currentToken() {
    try { return TokenManager.getToken?.() || ""; } catch (_) { return ""; }
}

function session() {
    try { return TokenManager.session?.() || null; } catch (_) { return null; }
}

function requireManagedSession() {
    const s = session();
    if (!s || s.mode === "wallet") {
        window.DamageAuth?.open?.("login");
        window.DamageAuth?.status?.("Quick Index requires a managed ECAI account.");
        throw new Error("Sign in with a managed ECAI account to use Quick Index.");
    }
    return s;
}

function headers(extra = {}) {
    const h = { Accept: "application/json", ...extra };
    const token = currentToken();
    if (token) h.Authorization = `Bearer ${token}`;
    return h;
}

function pretty(value) {
    if (value == null) return "Request failed";
    if (typeof value === "string") return value.replaceAll("_", " ");
    if (Array.isArray(value)) return value.map(pretty).join(": ");
    if (typeof value === "object") return JSON.stringify(value);
    return String(value);
}

async function parseResponse(response) {
    let body = null;
    try { body = await response.json(); } catch (_) {}
    if (response.status === 401) TokenManager.logout?.();
    if (!response.ok || body?.ok === false) {
        const error = new Error(pretty(body?.error || body?.message || `${response.status} ${response.statusText}`));
        error.status = response.status;
        throw error;
    }
    return body || {};
}

function idempotencyKey() {
    if (globalThis.crypto?.randomUUID) return `ecai-quick-${crypto.randomUUID()}`;
    const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
    return `ecai-quick-${Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")}`;
}

function sourceValue() {
    if (state.type === "file") {
        if (!state.file) throw new Error("Choose a file first.");
        return state.file;
    }
    const id = state.type === "url" ? "quickIndexUrl" : "quickIndexCid";
    const value = $(id).value.trim();
    if (!value) throw new Error(state.type === "url" ? "Enter a URL first." : "Enter an IPFS CID first.");
    return value;
}

async function callQuickIndex(path, enqueue = false) {
    requireManagedSession();
    const value = sourceValue();
    const expected = enqueue ? state.analysis?.sha256 : "";
    const idem = enqueue ? (state.key ||= idempotencyKey()) : "";
    if (state.type === "file") {
        const extra = {
            "Content-Type": "application/octet-stream",
            "X-ECAI-File-Name": encodeURIComponent(value.name || "source.txt"),
            "X-ECAI-File-Type": value.type || "application/octet-stream"
        };
        if (expected) extra["X-ECAI-Expected-Sha256"] = expected;
        if (idem) extra["Idempotency-Key"] = idem;
        return parseResponse(await fetch(path, {
            method: "POST", credentials: "include", cache: "no-store", redirect: "error",
            headers: headers(extra), body: value
        }));
    }
    const body = { source_type: state.type, expected_sha256: expected };
    body[state.type === "url" ? "url" : "cid"] = value;
    const extra = { "Content-Type": "application/json" };
    if (idem) extra["Idempotency-Key"] = idem;
    return parseResponse(await fetch(path, {
        method: "POST", credentials: "include", cache: "no-store", redirect: "error",
        headers: headers(extra), body: JSON.stringify(body)
    }));
}

function formatBytes(bytes) {
    const n = Number(bytes);
    if (!Number.isFinite(n)) return "—";
    if (n < 1024) return `${n} B`;
    if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / 1024 ** 2).toFixed(1)} MB`;
}

function badge(text) {
    const el = document.createElement("span"); el.className = "quick-index-badge"; el.textContent = text; return el;
}

function planItem(label, value) {
    const item = document.createElement("div"); item.className = "quick-index-plan-item";
    const k = document.createElement("span"); k.textContent = label;
    const v = document.createElement("strong"); v.textContent = value || "—";
    item.append(k, v); return item;
}

function clearAnalysis(message = "Choose a source, then detect its structure before indexing.") {
    state.analysis = null; state.source = null; state.queued = false; state.key = ""; state.jobId = ""; if ($("quickIndexViewJob")) $("quickIndexViewJob").hidden = true;
    $("quickIndexQueue").disabled = true;
    const host = $("quickIndexAnalysis"); host.className = "quick-index-analysis"; host.replaceChildren();
    const p = document.createElement("p"); p.className = "quick-index-empty"; p.textContent = message; host.append(p);
}

function renderAnalysis(result) {
    state.analysis = result.analysis || null; state.source = result.source || null; state.queued = false; state.key = ""; state.jobId = ""; if ($("quickIndexViewJob")) $("quickIndexViewJob").hidden = true;
    const a = state.analysis || {};
    const host = $("quickIndexAnalysis");
    host.className = `quick-index-analysis ${a.indexable ? "is-ready" : "is-blocked"}`; host.replaceChildren();

    const head = document.createElement("div"); head.className = "quick-index-analysis-head";
    const symbol = document.createElement("span"); symbol.className = "quick-index-analysis-symbol"; symbol.textContent = a.indexable ? "✓" : "!";
    const copy = document.createElement("div");
    const title = document.createElement("strong"); title.textContent = a.label || "Detected source";
    const sub = document.createElement("span"); sub.textContent = a.indexable ? "Ready for the durable searchable index" : "This source needs conversion before indexing";
    copy.append(title, sub); head.append(symbol, copy);

    const badges = document.createElement("div"); badges.className = "quick-index-badges";
    badges.append(badge(String(a.format || "text").toUpperCase()), badge(formatBytes(a.size_bytes)));
    if (Number.isFinite(a.line_count)) badges.append(badge(`${a.line_count} lines`));
    if (Number.isFinite(a.records_estimate)) badges.append(badge(`${a.records_estimate} records`));
    if (Number.isFinite(a.field_count)) badges.append(badge(`${a.field_count} fields`));

    const grid = document.createElement("div"); grid.className = "quick-index-plan-grid";
    grid.append(
        planItem("Detected structure", a.structure || "UTF-8 text"),
        planItem("Content identity", a.sha256 ? `sha256:${a.sha256.slice(0, 16)}…` : "—"),
        planItem("Index method", a.pipeline || "IPFS → searchable disk")
    );
    host.append(head, badges, grid);
    if (a.warning) {
        const warning = document.createElement("div"); warning.className = "quick-index-warning"; warning.textContent = a.warning; host.append(warning);
    }
    $("quickIndexQueue").disabled = !a.indexable;
}

function setStatus(text, error = false) {
    const el = $("quickIndexStatus"); el.textContent = text; el.classList.toggle("is-error", error);
}

function setBusy(on) {
    state.busy = on;
    $("quickIndexInspect").disabled = on;
    $("quickIndexQueue").disabled = on || state.queued || !state.analysis?.indexable;
    $("quickIndexFile").disabled = on;
    for (const tab of document.querySelectorAll("[data-quick-index-source]")) tab.disabled = on;
}

async function inspect() {
    if (state.busy) return;
    setBusy(true); setStatus("Inspecting source…");
    try {
        const result = await callQuickIndex("/ecai/quick-index/inspect", false);
        renderAnalysis(result); setStatus(result.analysis?.indexable ? "Inspection complete · no job queued yet" : "Conversion required", !result.analysis?.indexable);
    } catch (error) {
        clearAnalysis("Inspection did not complete."); setStatus(error.message || "Inspection failed", true);
    } finally { setBusy(false); }
}

async function enqueue() {
    if (state.busy || state.queued) return;
    if (!state.analysis?.indexable) { await inspect(); if (!state.analysis?.indexable) return; }
    setBusy(true); setStatus("Staging source and creating durable job…");
    try {
        const result = await callQuickIndex("/ecai/quick-index", true);
        const jobId = result.job?.id;
        if (!jobId) throw new Error("The server did not return a job ID. Retry this unchanged source with the same request key.");
        setStatus(`Job queued · ${jobId}${result.cid ? ` · ${result.cid.slice(0, 18)}…` : ""}`);
        state.queued = true;
        state.jobId = jobId;
        if ($("quickIndexViewJob")) $("quickIndexViewJob").hidden = false;
        $("quickIndexQueue").disabled = true;
        $("refreshJobs")?.click();
        document.dispatchEvent(new CustomEvent("ecai:quick-index-queued", { detail: { job: result.job, cid: result.cid } }));
    } catch (error) {
        setStatus(error.message || "Could not queue source", true);
    } finally { setBusy(false); }
}

function selectType(type) {
    if (!['file', 'url', 'ipfs'].includes(type)) return;
    state.type = type;
    for (const tab of document.querySelectorAll("[data-quick-index-source]")) {
        const active = tab.dataset.quickIndexSource === type;
        tab.classList.toggle("is-active", active); tab.setAttribute("aria-selected", String(active));
    }
    for (const pane of document.querySelectorAll("[data-quick-index-pane]")) pane.hidden = pane.dataset.quickIndexPane !== type;
    clearAnalysis(); setStatus("Inspect a source to review the plan.");
}

function setFile(file) {
    if (!file) return;
    state.file = file;
    $("quickIndexFileName").textContent = `${file.name} · ${formatBytes(file.size)}`;
    clearAnalysis("File selected. Detect its structure to verify the indexing plan.");
    void inspect();
}

function overviewCtaMarkup() {
    const cta = document.createElement("section");
    cta.id = "quickIndexOverviewCta";
    cta.className = "surface panel-pad quick-index-overview-cta";
    cta.setAttribute("aria-labelledby", "quickIndexOverviewTitle");
    cta.innerHTML = `
      <div class="quick-index-overview-copy">
        <div class="eyebrow">START HERE · QUICK INDEX</div>
        <h2 id="quickIndexOverviewTitle">Turn something you already have into searchable ECAI knowledge.</h2>
        <p>Drop a file, paste a public URL, or use an IPFS CID. ECAI detects the structure first, lets you verify what it found, then queues a durable searchable index job.</p>
        <div class="quick-index-overview-inputs" aria-label="Quick Index source types">
          <span>↥ File</span><span>↗ URL</span><span>◇ IPFS CID</span>
        </div>
        <div class="quick-index-overview-actions">
          <button type="button" class="button button-primary" id="quickIndexOverviewStart">Quick Index a source ↗</button>
          <span>No schema setup · detect before index</span>
        </div>
      </div>
      <div class="quick-index-overview-flow" aria-label="Quick Index workflow">
        <div><b>01</b><span>Add source</span><small>File, URL or CID</small></div>
        <i aria-hidden="true">→</i>
        <div><b>02</b><span>Detect</span><small>Format + structure</small></div>
        <i aria-hidden="true">→</i>
        <div><b>03</b><span>Index</span><small>Durable queue</small></div>
      </div>`;
    return cta;
}

function indexNavigationControl() {
    const controls = [...document.querySelectorAll('button, a, [role="button"]')]
        .filter(el => !el.closest?.("#quickIndexOverviewCta"));
    const datasetMatch = controls.find(el =>
        Object.values(el.dataset || {}).some(value => String(value).toLowerCase() === "indexing")
    );
    if (datasetMatch) return datasetMatch;
    return controls.find(el => /^index jobs(?:\s|$)/i.test((el.textContent || "").trim())) || null;
}

function revealQuickIndex() {
    const panel = document.querySelector('[data-panel="indexing"]');
    const nav = indexNavigationControl();
    if (nav) nav.click();
    else if (panel) {
        document.querySelectorAll('.view[data-panel]').forEach(view => { view.hidden = view !== panel; });
        panel.hidden = false;
    }
    requestAnimationFrame(() => {
        const card = $("quickIndexCard");
        card?.scrollIntoView?.({ behavior: "smooth", block: "start" });
        card?.classList.add("is-overview-target");
        window.setTimeout(() => card?.classList.remove("is-overview-target"), 1400);
    });
}

function installOverviewCta() {
    if ($("quickIndexOverviewCta")) return;
    const overview = document.querySelector('[data-panel="overview"]');
    if (!overview) return;
    const cta = overviewCtaMarkup();
    const intro = overview.querySelector(".page-intro");
    if (intro) intro.insertAdjacentElement("afterend", cta);
    else overview.prepend(cta);
    $("quickIndexOverviewStart")?.addEventListener("click", revealQuickIndex);
}

function resetForIdentityChange() {
    state.file = null; state.analysis = null; state.source = null; state.queued = false; state.key = ""; state.jobId = ""; if ($("quickIndexViewJob")) $("quickIndexViewJob").hidden = true;
    if ($("quickIndexFile")) $("quickIndexFile").value = "";
    if ($("quickIndexUrl")) $("quickIndexUrl").value = "";
    if ($("quickIndexCid")) $("quickIndexCid").value = "";
    if ($("quickIndexFileName")) $("quickIndexFileName").textContent = "Drop a text or structured-text file here, or click to browse";
    clearAnalysis(); setStatus("Inspect a source to review the plan.");
}

function init() {
    if (!$("quickIndexCard")) return;
    installOverviewCta();
    document.querySelectorAll("[data-quick-index-source]").forEach(tab => tab.addEventListener("click", () => selectType(tab.dataset.quickIndexSource)));
    $("quickIndexInspect").addEventListener("click", () => void inspect());
    $("quickIndexQueue").addEventListener("click", () => void enqueue());
    $("quickIndexViewJob")?.addEventListener("click", () => {
        if (state.jobId) document.dispatchEvent(new CustomEvent("ecai:view-index-job", {detail: {id: state.jobId}}));
    });
    $("quickIndexFile").addEventListener("change", event => setFile(event.target.files?.[0]));
    const drop = $("quickIndexDrop");
    drop.addEventListener("click", () => $("quickIndexFile").click());
    drop.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); $("quickIndexFile").click(); } });
    for (const name of ["dragenter", "dragover"]) drop.addEventListener(name, event => { event.preventDefault(); drop.classList.add("is-dragover"); });
    for (const name of ["dragleave", "drop"]) drop.addEventListener(name, event => { event.preventDefault(); drop.classList.remove("is-dragover"); });
    drop.addEventListener("drop", event => setFile(event.dataTransfer?.files?.[0]));
    for (const id of ["quickIndexUrl", "quickIndexCid"]) {
        $(id).addEventListener("input", () => clearAnalysis());
        $(id).addEventListener("keydown", event => { if (event.key === "Enter") { event.preventDefault(); void inspect(); } });
    }
    document.addEventListener("ecai:identity-changed", resetForIdentityChange);
    selectType("file");
}

init();
