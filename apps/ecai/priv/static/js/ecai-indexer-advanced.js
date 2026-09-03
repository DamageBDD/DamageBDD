(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = {
    jobs: [],
    selectedJobId: null,
    eventAbort: null,
    lastEventId: "",
    pollTimer: null,
    accessToken: null,
    email: null,
    authenticated: false
  };

  const terminalStates = new Set(["completed", "ready_to_mint", "failed", "canceled", "minted"]);

  function currentToken() {
    if (state.accessToken) return state.accessToken;
    try { return window.TokenManager?.getToken?.() || ""; } catch (_) { return ""; }
  }

  function authHeaders(extra = {}) {
    const headers = { ...extra };
    const token = currentToken();
    if (token) headers.Authorization = `Bearer ${token}`;
    return headers;
  }

  function url(path) {
    return new URL(path, window.location.origin).toString();
  }

  async function api(path, options = {}) {
    const response = await fetch(url(path), {
      ...options,
      credentials: "include",
      headers: authHeaders({
        Accept: "application/json",
        ...(options.body ? { "Content-Type": "application/json" } : {}),
        ...(options.headers || {})
      })
    });
    const text = await response.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch (_) { body = { raw: text }; }
    if (!response.ok) {
      if (response.status === 401) {
        setAuthenticated(false);
        showLoginDialog("Your DamageBDD session is not authenticated or has expired.");
      }
      const error = new Error(`HTTP ${response.status}`);
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  }

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  function log(value) {
    $("operatorOutput").textContent = typeof value === "string" ? value : pretty(value);
  }

  function setConnection(text, ok = false) {
    const el = $("connectionState");
    el.textContent = text;
    el.className = ok ? "ok" : "bad";
  }

  function setAuthenticated(authenticated, identity = "") {
    state.authenticated = authenticated;
    const workspace = $("indexerWorkspace");
    const required = $("indexerAuthRequired");
    const loginButton = $("loginBtn");
    const logoutButton = $("logoutBtn");
    const authState = $("authState");
    const authIdentity = $("authIdentity");

    if (workspace) workspace.hidden = !authenticated;
    if (required) required.hidden = authenticated;
    if (loginButton) loginButton.hidden = authenticated;
    if (logoutButton) logoutButton.hidden = !authenticated;
    if (authState) {
      authState.textContent = authenticated ? "authenticated" : "sign in required";
      authState.className = authenticated ? "ok" : "bad";
    }
    if (authIdentity) authIdentity.textContent = authenticated ? (identity || state.email || "DamageBDD session") : "";
    if (!authenticated) setConnection("not authenticated", false);
  }

  function showLoginDialog(message = "") {
    const dialog = $("indexerLoginDialog");
    const status = $("loginStatus");
    if (status) {
      status.textContent = message;
      status.className = message ? "bad" : "ecai-indexer-muted";
    }
    if (!dialog) return;
    if (typeof dialog.showModal === "function") {
      if (!dialog.open) dialog.showModal();
    } else {
      dialog.setAttribute("open", "");
    }
    setTimeout(() => $("loginEmail")?.focus(), 0);
  }

  function closeLoginDialog() {
    const dialog = $("indexerLoginDialog");
    if (!dialog) return;
    if (typeof dialog.close === "function" && dialog.open) dialog.close();
    else dialog.removeAttribute("open");
  }

  function validEmail(email) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
  }

  async function login(event) {
    event?.preventDefault?.();
    const email = $("loginEmail")?.value.trim() || "";
    const password = $("loginPassword")?.value || "";
    const status = $("loginStatus");
    const submit = $("loginSubmitBtn");

    if (!validEmail(email)) {
      if (status) { status.textContent = "Enter a valid email address."; status.className = "bad"; }
      return;
    }
    if (!password) {
      if (status) { status.textContent = "Enter your DamageBDD password."; status.className = "bad"; }
      return;
    }

    if (submit) submit.disabled = true;
    if (status) { status.textContent = "Signing in…"; status.className = "ecai-indexer-muted"; }
    try {
      const response = await fetch("/accounts/auth/", {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          grant_type: "password",
          scope: "basic",
          username: email,
          password
        })
      });
      const text = await response.text();
      let data = {};
      try { data = text ? JSON.parse(text) : {}; } catch (_) { data = { message: text }; }

      if (!response.ok || !data.access_token) {
        throw new Error(data.message || data.error || "Authentication failed.");
      }

      state.accessToken = data.access_token;
      state.email = data.email || email;
      try {
        if (window.TokenManager?.on_custodial_login) {
          window.TokenManager.on_custodial_login(data.address, state.email, data.access_token);
          window.TokenManager.activate?.("custodial");
        }
      } catch (error) {
        console.warn("DamageBDD TokenManager login update failed; continuing with authenticated session", error);
      }

      if ($("loginPassword")) $("loginPassword").value = "";
      setAuthenticated(true, state.email);
      closeLoginDialog();
      await connect();
    } catch (error) {
      if (status) { status.textContent = error.message || "Authentication failed."; status.className = "bad"; }
      setAuthenticated(false);
    } finally {
      if (submit) submit.disabled = false;
    }
  }

  async function logout() {
    try {
      await fetch("/accounts/logout", {
        method: "POST",
        credentials: "include",
        headers: authHeaders({ "Content-Type": "application/json", Accept: "application/json" }),
        body: "{}"
      });
    } catch (error) {
      console.warn("DamageBDD logout request failed; clearing local auth state", error);
    }
    try {
      if (window.TokenManager?.logout) window.TokenManager.logout(window.TokenManager.getMode?.());
    } catch (_) {}
    state.accessToken = null;
    state.email = null;
    stopEventStream();
    setAuthenticated(false);
    showLoginDialog("Signed out.");
  }

  async function probeAuthentication() {
    try {
      await refreshStatus();
      setAuthenticated(true, state.email || "DamageBDD session");
      await refreshJobs();
      setConnection("connected", true);
      return true;
    } catch (error) {
      if (error.status !== 401) log(error.body || error.message);
      setAuthenticated(false);
      showLoginDialog(error.status === 401 ? "Sign in with your DamageBDD account." : "Unable to verify the current DamageBDD session.");
      return false;
    }
  }

  function previousMonths(count = 12) {
    const d = new Date();
    d.setUTCDate(1);
    const out = [];
    for (let i = 0; i < count; i += 1) {
      d.setUTCMonth(d.getUTCMonth() - 1);
      out.unshift(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`);
    }
    return out;
  }

  function newIdempotencyKey() {
    const id = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    $("idempotencyKey").value = `ecai-index-${id}`;
  }

  function buildWikimediaSpec() {
    const months = $("months").value.split(",").map((s) => s.trim()).filter(Boolean);
    const catalogRef = $("catalogRef").value.trim();
    const source = {
      project: $("project").value.trim(),
      pageview_project: $("pageviewProject").value.trim(),
      content_release: $("release").value.trim(),
      pageview_months: months
    };
    if (catalogRef) {
      if (catalogRef.startsWith("bafy") || catalogRef.startsWith("Qm")) source.catalog_cid = catalogRef;
      else source.catalog_path = catalogRef;
    }

    return {
      schema: "ecai-index-job/v1",
      kind: "wikimedia_visibility",
      source,
      target: {
        index_id: $("indexId").value.trim(),
        namespace: $("namespace").value.trim(),
        base_dir: $("baseDir").value.trim(),
        mode: "live_search",
        previous_manifest_cid: null
      },
      options: {
        priority: Number($("priority").value || 100),
        max_retries: 3,
        batch_size: 1,
        limit: Number($("limit").value || 10000),
        minimum_active_months: Number($("minMonths").value || 1),
        selection_shards: 128,
        oversample_percent: 125,
        partition_buffer_bytes: 262144,
        abstract_max_bytes: 16384,
        cirrus_max_line_bytes: 67108864,
        index_chunk_lines: 5000,
        keep_downloads: false,
        keep_intermediates: $("keepIntermediates").checked,
        publish_activity_ipfs: $("publishActivity").checked,
        publish_extracted_ipfs: false
      },
      finalize: {
        build_nft_manifest: true,
        publish_ipfs: $("publishIpfs").checked,
        auto_mint: false
      }
    };
  }

  function writeSpec() {
    const spec = buildWikimediaSpec();
    $("specEditor").value = pretty(spec);
    return spec;
  }

  function jobLinks(job) {
    if (job && job.links) return job.links;
    const id = job.id;
    const base = `/ecai/index-jobs/${encodeURIComponent(id)}`;
    return {
      self: base,
      events: `${base}/events`,
      artifact: `${base}/artifact`,
      controls: {
        pause: `${base}/pause`, resume: `${base}/resume`, cancel: `${base}/cancel`, retry: `${base}/retry`
      }
    };
  }

  async function connect() {
    try {
      await refreshStatus();
      await refreshJobs();
      setConnection("connected", true);
    } catch (error) {
      setConnection(`connection failed (${error.status || error.message})`, false);
      log(error.body || error.message);
    }
  }

  async function refreshStatus() {
    const body = await api("/ecai/index-jobs/status");
    const s = body.status || {};
    $("mConcurrency").textContent = valueOrDash(s.max_concurrency);
    $("mRunning").textContent = valueOrDash(s.running_jobs ?? s.running);
    $("mQueued").textContent = valueOrDash(s.queued_jobs ?? s.queued);
    $("mWorkers").textContent = valueOrDash(s.active_workers ?? s.workers);
    return body;
  }

  function valueOrDash(v) { return v === undefined || v === null ? "–" : String(v); }

  async function refreshJobs() {
    const params = new URLSearchParams({ limit: "100" });
    const filter = $("stateFilter").value;
    if (filter) params.set("state", filter);
    const body = await api(`/ecai/index-jobs?${params.toString()}`);
    state.jobs = body.jobs || [];
    renderJobs();
    if (state.selectedJobId) {
      const selected = state.jobs.find((j) => j.id === state.selectedJobId);
      if (selected) showJob(selected);
    }
  }

  function progressOf(job) {
    const p = job.progress || {};
    if (typeof p.percent === "number") return Math.max(0, Math.min(100, p.percent));
    if (Number.isFinite(p.completed) && Number.isFinite(p.total) && p.total > 0) return 100 * p.completed / p.total;
    return 0;
  }

  function renderJobs() {
    const body = $("jobsBody");
    body.replaceChildren();
    for (const job of state.jobs) {
      const tr = document.createElement("tr");
      const progress = job.progress || {};
      const pct = progressOf(job);
      tr.innerHTML = `
        <td><button class="select-job" data-id="${escapeHtml(job.id)}">${escapeHtml(job.id)}</button><br><span class="muted">${escapeHtml(job.spec?.kind || "")}</span></td>
        <td><span class="pill">${escapeHtml(job.state || "")}</span><br><span class="muted">${escapeHtml(progress.phase || "")}</span></td>
        <td>${pct ? pct.toFixed(1) + "%" : `${valueOrDash(progress.completed)}/${valueOrDash(progress.total)}`}<div class="progress"><i style="width:${pct}%"></i></div><span class="muted">${escapeHtml(progress.current_source || "")}</span></td>
        <td class="controls"></td>`;
      const controls = tr.querySelector(".controls");
      addControlButtons(controls, job);
      body.appendChild(tr);
    }
    body.querySelectorAll(".select-job").forEach((button) => {
      button.addEventListener("click", () => selectJob(button.dataset.id));
    });
  }

  function addControlButtons(container, job) {
    const allowed = controlsForState(job.state);
    for (const action of ["pause", "resume", "cancel", "retry"]) {
      const button = document.createElement("button");
      button.textContent = action;
      button.disabled = !allowed.has(action);
      button.addEventListener("click", () => controlJob(job, action));
      container.appendChild(button);
    }
  }

  function controlsForState(s) {
    const out = new Set();
    if (["preparing", "running"].includes(s)) out.add("pause");
    if (s === "paused") out.add("resume");
    if (["queued", "preparing", "running", "pause_requested", "paused"].includes(s)) out.add("cancel");
    if (["failed", "canceled"].includes(s)) out.add("retry");
    return out;
  }

  async function controlJob(job, action) {
    try {
      const links = jobLinks(job);
      const path = links.controls?.[action] || `/ecai/index-jobs/${encodeURIComponent(job.id)}/${action}`;
      const result = await api(path, { method: "POST", body: "{}" });
      log(result);
      await refreshJobs();
    } catch (error) {
      log(error.body || error.message);
    }
  }

  async function queueJob() {
    let spec;
    try { spec = JSON.parse($("specEditor").value || pretty(writeSpec())); }
    catch (error) { log(`Invalid job JSON: ${error.message}`); return; }

    if (!$("idempotencyKey").value.trim()) newIdempotencyKey();
    try {
      const result = await api("/ecai/index-jobs", {
        method: "POST",
        headers: { "Idempotency-Key": $("idempotencyKey").value.trim() },
        body: JSON.stringify(spec)
      });
      log(result);
      if (result.job?.id) {
        state.selectedJobId = result.job.id;
        showJob(result.job);
      }
      await refreshJobs();
    } catch (error) {
      log(error.body || error.message);
    }
  }

  async function selectJob(id) {
    state.selectedJobId = id;
    try {
      const result = await api(`/ecai/index-jobs/${encodeURIComponent(id)}`);
      showJob(result.job);
    } catch (error) {
      log(error.body || error.message);
    }
  }

  function showJob(job) {
    $("jobOutput").textContent = pretty(job);
    $("trackBtn").disabled = !job?.id;
    $("artifactBtn").disabled = !job?.id;
  }

  async function loadArtifact() {
    const job = state.jobs.find((j) => j.id === state.selectedJobId) || { id: state.selectedJobId };
    if (!job.id) return;
    try {
      const result = await api(jobLinks(job).artifact);
      $("artifactOutput").textContent = pretty(result);
    } catch (error) {
      $("artifactOutput").textContent = pretty(error.body || { error: error.message });
    }
  }

  async function streamSelectedEvents() {
    stopEventStream();
    const job = state.jobs.find((j) => j.id === state.selectedJobId) || { id: state.selectedJobId };
    if (!job.id) return;
    state.eventAbort = new AbortController();
    $("trackBtn").disabled = true;
    $("stopTrackBtn").disabled = false;
    $("eventOutput").textContent = "connecting…\n";
    try {
      await consumeSse(jobLinks(job).events, state.eventAbort.signal);
    } catch (error) {
      if (error.name !== "AbortError") appendEvent(`stream error: ${error.message}`);
    } finally {
      state.eventAbort = null;
      $("trackBtn").disabled = false;
      $("stopTrackBtn").disabled = true;
    }
  }

  async function consumeSse(path, signal) {
    const headers = authHeaders({ Accept: "text/event-stream" });
    if (state.lastEventId) headers["Last-Event-ID"] = state.lastEventId;
    const response = await fetch(url(path), { headers, signal, credentials: "include" });
    if (!response.ok) throw new Error(`SSE HTTP ${response.status}`);
    if (!response.body) throw new Error("SSE response has no body");

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, "\n");
      let boundary;
      while ((boundary = buffer.indexOf("\n\n")) >= 0) {
        const block = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        handleSseBlock(block);
      }
    }
  }

  function handleSseBlock(block) {
    let id = "";
    let event = "message";
    const data = [];
    for (const line of block.split("\n")) {
      if (!line || line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const field = colon < 0 ? line : line.slice(0, colon);
      const value = colon < 0 ? "" : line.slice(colon + 1).replace(/^ /, "");
      if (field === "id") id = value;
      else if (field === "event") event = value;
      else if (field === "data") data.push(value);
    }
    if (id) state.lastEventId = id;
    let payload = data.join("\n");
    try { payload = JSON.parse(payload); } catch (_) { /* keep text */ }
    appendEvent(`${id || "-"} ${event}: ${typeof payload === "string" ? payload : JSON.stringify(payload)}`);
    if (payload && typeof payload === "object" && terminalStates.has(payload.state)) refreshJobs().catch(() => {});
  }

  function appendEvent(line) {
    const output = $("eventOutput");
    output.textContent += `${line}\n`;
    const lines = output.textContent.split("\n");
    if (lines.length > 250) output.textContent = lines.slice(-250).join("\n");
    output.scrollTop = output.scrollHeight;
  }

  function stopEventStream() {
    if (state.eventAbort) state.eventAbort.abort();
    state.eventAbort = null;
    $("trackBtn").disabled = !state.selectedJobId;
    $("stopTrackBtn").disabled = true;
  }

  async function doctor() {
    try { log(await api("/ecai/wikimedia/doctor")); }
    catch (error) { log(error.body || error.message); }
  }

  function sourceQuery() {
    const q = new URLSearchParams({
      project: $("project").value.trim(),
      pageview_project: $("pageviewProject").value.trim(),
      months: $("months").value.trim()
    });
    return q;
  }

  async function listSources() {
    try { log(await api(`/ecai/wikimedia/sources?${sourceQuery()}`)); }
    catch (error) { log(error.body || error.message); }
  }

  async function previewPlan() {
    const q = sourceQuery();
    q.set("limit", $("limit").value);
    q.set("minimum_active_months", $("minMonths").value);
    try { log(await api(`/ecai/wikimedia/plan?${q}`)); }
    catch (error) { log(error.body || error.message); }
  }

  async function search() {
    const q = $("searchQuery").value.trim();
    if (!q) return;
    const params = new URLSearchParams({ q, limit: "20", dedupe_entities: "true" });
    try { $("searchOutput").textContent = pretty(await api(`/ecai/wikimedia/search?${params}`)); }
    catch (error) { $("searchOutput").textContent = pretty(error.body || { error: error.message }); }
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[c]));
  }

  function startPolling() {
    clearInterval(state.pollTimer);
    state.pollTimer = setInterval(() => {
      if (!state.authenticated || !$("autoRefresh").checked) return;
      Promise.all([refreshStatus(), refreshJobs()]).catch(() => {});
    }, 2500);
  }

  function init() {
    if (!$("ecai-indexer-root")) return;
    $("months").value = previousMonths(12).join(",");
    newIdempotencyKey();
    writeSpec();

    $("loginBtn")?.addEventListener("click", () => showLoginDialog());
    $("authRequiredLoginBtn")?.addEventListener("click", () => showLoginDialog());
    $("closeLoginBtn")?.addEventListener("click", closeLoginDialog);
    $("indexerLoginForm")?.addEventListener("submit", login);
    $("logoutBtn")?.addEventListener("click", logout);

    $("refreshBtn").addEventListener("click", () => refreshJobs().catch((e) => log(e.body || e.message)));
    $("stateFilter").addEventListener("change", () => refreshJobs().catch((e) => log(e.body || e.message)));
    $("buildSpecBtn").addEventListener("click", writeSpec);
    $("queueBtn").addEventListener("click", queueJob);
    $("newKeyBtn").addEventListener("click", newIdempotencyKey);
    $("doctorBtn").addEventListener("click", doctor);
    $("sourcesBtn").addEventListener("click", listSources);
    $("planBtn").addEventListener("click", previewPlan);
    $("searchBtn").addEventListener("click", search);
    $("searchQuery").addEventListener("keydown", (e) => { if (e.key === "Enter") search(); });
    $("trackBtn").addEventListener("click", streamSelectedEvents);
    $("stopTrackBtn").addEventListener("click", stopEventStream);
    $("artifactBtn").addEventListener("click", loadArtifact);

    ["project", "pageviewProject", "release", "months", "indexId", "namespace", "baseDir", "catalogRef", "limit", "minMonths", "priority", "publishIpfs", "publishActivity", "keepIntermediates"].forEach((id) => {
      $(id).addEventListener("change", writeSpec);
    });

    setAuthenticated(false);
    startPolling();
    probeAuthentication();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
