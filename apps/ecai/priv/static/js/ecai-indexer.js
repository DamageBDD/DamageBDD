(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = {
    authenticated: false,
    accessToken: null,
    email: null,
    presets: [],
    jobs: [],
    pollTimer: null
  };

  function currentToken() {
    if (state.accessToken) return state.accessToken;
    try { return window.TokenManager?.getToken?.() || ""; }
    catch (_) { return ""; }
  }

  function authHeaders(extra = {}) {
    const headers = { ...extra };
    const token = currentToken();
    if (token) headers.Authorization = `Bearer ${token}`;
    return headers;
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
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
    try { body = text ? JSON.parse(text) : null; }
    catch (_) { body = { raw: text }; }

    if (!response.ok) {
      const error = new Error(body?.error || body?.message || `HTTP ${response.status}`);
      error.status = response.status;
      error.body = body;
      if (response.status === 401) {
        setAuthenticated(false);
        showLoginDialog("Your DamageBDD session has expired.");
      }
      throw error;
    }

    return body;
  }

  function setAuthenticated(authenticated, identity = "") {
    state.authenticated = authenticated;
    $("indexerWorkspace").hidden = !authenticated;
    $("indexerAuthRequired").hidden = authenticated;
    $("loginBtn").hidden = authenticated;
    $("logoutBtn").hidden = !authenticated;
    $("authIdentity").textContent = authenticated ? (identity || state.email || "signed in") : "";
    if (!authenticated) $("queueSummary").textContent = "queue unavailable";
  }

  function setNotice(message = "", isError = false) {
    const notice = $("indexerNotice");
    notice.hidden = !message;
    notice.textContent = message;
    notice.className = `ecai-indexer-notice${isError ? " is-error" : ""}`;
  }

  function showLoginDialog(message = "") {
    const dialog = $("indexerLoginDialog");
    const status = $("loginStatus");
    status.textContent = message;
    if (typeof dialog.showModal === "function") {
      if (!dialog.open) dialog.showModal();
    } else {
      dialog.setAttribute("open", "");
    }
    setTimeout(() => $("loginEmail")?.focus(), 0);
  }

  function closeLoginDialog() {
    const dialog = $("indexerLoginDialog");
    if (typeof dialog.close === "function" && dialog.open) dialog.close();
    else dialog.removeAttribute("open");
  }

  function validEmail(value) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  }

  async function login(event) {
    event.preventDefault();
    const email = $("loginEmail").value.trim();
    const password = $("loginPassword").value;
    const submit = $("loginSubmitBtn");
    const status = $("loginStatus");

    if (!validEmail(email)) {
      status.textContent = "Enter a valid email address.";
      return;
    }
    if (!password) {
      status.textContent = "Enter your password.";
      return;
    }

    submit.disabled = true;
    status.textContent = "Signing in…";

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
      try { data = text ? JSON.parse(text) : {}; }
      catch (_) { data = { message: text }; }

      if (!response.ok || !data.access_token) {
        throw new Error(data.message || data.error || "Authentication failed.");
      }

      state.accessToken = data.access_token;
      state.email = data.email || email;

      try {
        window.TokenManager?.on_custodial_login?.(data.address, state.email, data.access_token);
        window.TokenManager?.activate?.("custodial");
      } catch (error) {
        console.warn("Unable to update TokenManager; using the authenticated indexer session", error);
      }

      $("loginPassword").value = "";
      status.textContent = "";
      setAuthenticated(true, state.email);
      closeLoginDialog();
      setNotice("");
      await Promise.all([loadPresets(), refreshAll()]);
    } catch (error) {
      status.textContent = error.message || "Authentication failed.";
      setAuthenticated(false);
    } finally {
      submit.disabled = false;
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
    } catch (_) {
      // Local logout still proceeds if the request cannot reach the node.
    }

    try { window.TokenManager?.logout?.(window.TokenManager?.getMode?.()); }
    catch (_) {}

    state.accessToken = null;
    state.email = null;
    state.presets = [];
    state.jobs = [];
    setAuthenticated(false);
    renderPresets();
    renderJobs();
    showLoginDialog("Signed out.");
  }

  async function probeAuthentication() {
    try {
      await refreshStatus();
      setAuthenticated(true, state.email || "DamageBDD session");
      await Promise.all([loadPresets(), refreshJobs()]);
      return true;
    } catch (error) {
      setAuthenticated(false);
      if (error.status === 401) {
        showLoginDialog("Sign in with your DamageBDD account.");
      } else {
        setNotice("Unable to connect to the index queue.", true);
      }
      return false;
    }
  }

  async function loadPresets() {
    const result = await api("/ecai/index-jobs/presets");
    state.presets = Array.isArray(result?.presets) ? result.presets : [];
    renderPresets();
  }

  function renderPresets() {
    const grid = $("presetGrid");
    grid.replaceChildren();

    if (!state.presets.length) {
      const empty = document.createElement("p");
      empty.className = "ecai-indexer-muted";
      empty.textContent = state.authenticated ? "This node has no Wikimedia presets configured." : "Sign in to load sources.";
      grid.appendChild(empty);
      return;
    }

    for (const preset of state.presets) {
      const card = document.createElement("article");
      card.className = "ecai-indexer-preset";

      const title = document.createElement("h3");
      title.textContent = preset.label || preset.id || "Wikimedia";

      const description = document.createElement("p");
      description.className = "ecai-indexer-muted";
      description.textContent = preset.description || "Wikimedia visibility index.";

      const meta = document.createElement("p");
      meta.className = "ecai-indexer-preset-meta ecai-indexer-muted";
      meta.textContent = preset.project || preset.id || "";

      const button = document.createElement("button");
      button.type = "button";
      button.textContent = "Queue index";
      button.addEventListener("click", () => queuePreset(preset, button));

      card.append(title, description, meta, button);
      grid.appendChild(card);
    }
  }

  function presetIdempotencyStorageKey(presetId) {
    return `ecai.indexer.preset.${presetId}.idempotency-key`;
  }

  function createIdempotencyKey(presetId) {
    const nonce = crypto.randomUUID
      ? crypto.randomUUID()
      : Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) =>
          byte.toString(16).padStart(2, "0")
        ).join("");
    return `wikimedia-preset-${presetId}-${nonce}`;
  }

  function pendingPresetIdempotencyKey(presetId) {
    const storageKey = presetIdempotencyStorageKey(presetId);
    let key = sessionStorage.getItem(storageKey);
    if (!key) {
      key = createIdempotencyKey(presetId);
      sessionStorage.setItem(storageKey, key);
    }
    return key;
  }

  function completePresetRequest(presetId) {
    sessionStorage.removeItem(presetIdempotencyStorageKey(presetId));
  }

  async function queuePreset(preset, button) {
    button.disabled = true;
    const previousLabel = button.textContent;
    button.textContent = "Queueing…";
    setNotice("");
    const idempotencyKey = pendingPresetIdempotencyKey(preset.id);

    try {
      const result = await api(`/ecai/index-jobs/presets/${encodeURIComponent(preset.id)}`, {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey },
        body: "{}"
      });
      completePresetRequest(preset.id);
      const jobId = result?.job?.id;
      setNotice(`${preset.label || preset.id} queued${jobId ? ` as ${jobId}` : ""}.`);
      await refreshAll();
    } catch (error) {
      setNotice(errorMessage(error), true);
    } finally {
      button.disabled = false;
      button.textContent = previousLabel;
    }
  }

  async function refreshStatus() {
    const result = await api("/ecai/index-jobs/status");
    const status = result?.status || {};
    const running = status.running_jobs ?? status.running ?? 0;
    const queued = status.queued_jobs ?? status.queued ?? 0;
    $("queueSummary").textContent = `${running} running · ${queued} queued`;
  }

  async function refreshJobs() {
    const result = await api("/ecai/index-jobs?kind=wikimedia_visibility&limit=50");
    state.jobs = Array.isArray(result?.jobs) ? result.jobs : [];
    renderJobs();
  }

  async function refreshAll() {
    await Promise.all([refreshStatus(), refreshJobs()]);
  }

  function renderJobs() {
    const body = $("jobsBody");
    const empty = $("jobsEmpty");
    const tableWrap = $("jobsTableWrap");
    body.replaceChildren();

    const jobs = [...state.jobs].sort((a, b) => String(b.created_at || b.id || "").localeCompare(String(a.created_at || a.id || "")));
    empty.hidden = jobs.length !== 0;
    tableWrap.hidden = jobs.length === 0;

    for (const job of jobs) {
      body.appendChild(renderJobRow(job));
    }
  }

  function renderJobRow(job) {
    const row = document.createElement("tr");

    const sourceCell = document.createElement("td");
    const sourceWrap = document.createElement("div");
    sourceWrap.className = "ecai-indexer-job-source";
    const sourceName = document.createElement("strong");
    sourceName.textContent = labelForProject(job?.spec?.source?.project) || job?.spec?.source?.project || "Wikimedia";
    const jobId = document.createElement("small");
    jobId.textContent = job.id || "";
    sourceWrap.append(sourceName, jobId);
    sourceCell.appendChild(sourceWrap);

    const stateCell = document.createElement("td");
    const statePill = document.createElement("span");
    statePill.className = "ecai-indexer-state";
    statePill.textContent = job.state || "unknown";
    const phase = document.createElement("div");
    phase.className = "ecai-indexer-job-phase";
    phase.textContent = job?.progress?.phase || "";
    stateCell.append(statePill, phase);

    const progressCell = document.createElement("td");
    const progressText = document.createElement("div");
    const percent = progressPercent(job.progress || {});
    progressText.textContent = progressLabel(job.progress || {}, percent);
    const progressBar = document.createElement("div");
    progressBar.className = "ecai-indexer-progress";
    const progressFill = document.createElement("span");
    progressFill.style.width = `${percent}%`;
    progressBar.appendChild(progressFill);
    progressCell.append(progressText, progressBar);

    const actionsCell = document.createElement("td");
    const actions = document.createElement("div");
    actions.className = "ecai-indexer-job-actions";
    for (const action of allowedActions(job.state)) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = actionLabel(action);
      button.addEventListener("click", () => controlJob(job, action, button));
      actions.appendChild(button);
    }
    actionsCell.appendChild(actions);

    row.append(sourceCell, stateCell, progressCell, actionsCell);
    return row;
  }

  function labelForProject(project) {
    return state.presets.find((preset) => preset.project === project)?.label || "";
  }

  function progressPercent(progress) {
    if (Number.isFinite(progress.percent)) {
      return Math.max(0, Math.min(100, Number(progress.percent)));
    }
    if (Number.isFinite(progress.completed) && Number.isFinite(progress.total) && Number(progress.total) > 0) {
      return Math.max(0, Math.min(100, (100 * Number(progress.completed)) / Number(progress.total)));
    }
    return 0;
  }

  function progressLabel(progress, percent) {
    if (percent > 0) return `${percent.toFixed(1)}%`;
    if (Number.isFinite(progress.completed) && Number.isFinite(progress.total)) {
      return `${progress.completed} / ${progress.total}`;
    }
    if (Number.isFinite(progress.records_indexed)) {
      return `${Number(progress.records_indexed).toLocaleString()} records`;
    }
    return "—";
  }

  function allowedActions(jobState) {
    if (["preparing", "running"].includes(jobState)) return ["pause", "cancel"];
    if (jobState === "paused") return ["resume", "cancel"];
    if (["queued", "pause_requested"].includes(jobState)) return ["cancel"];
    if (["failed", "canceled"].includes(jobState)) return ["retry"];
    return [];
  }

  function actionLabel(action) {
    return action.charAt(0).toUpperCase() + action.slice(1);
  }

  async function controlJob(job, action, button) {
    button.disabled = true;
    try {
      const path = job?.links?.controls?.[action] || `/ecai/index-jobs/${encodeURIComponent(job.id)}/${action}`;
      await api(path, { method: "POST", body: "{}" });
      await refreshAll();
    } catch (error) {
      setNotice(errorMessage(error), true);
    } finally {
      button.disabled = false;
    }
  }

  function errorMessage(error) {
    const value = error?.body?.error ?? error?.body?.message ?? error?.message ?? "Request failed.";
    if (typeof value === "string") return value;
    try { return JSON.stringify(value); }
    catch (_) { return "Request failed."; }
  }

  function startPolling() {
    clearInterval(state.pollTimer);
    state.pollTimer = setInterval(() => {
      if (!state.authenticated || document.hidden) return;
      refreshAll().catch(() => {});
    }, 3000);
  }

  function init() {
    if (!$("ecai-indexer-root")) return;

    $("loginBtn").addEventListener("click", () => showLoginDialog());
    $("authRequiredLoginBtn").addEventListener("click", () => showLoginDialog());
    $("closeLoginBtn").addEventListener("click", closeLoginDialog);
    $("indexerLoginForm").addEventListener("submit", login);
    $("logoutBtn").addEventListener("click", logout);
    $("refreshJobsBtn").addEventListener("click", () => refreshAll().catch((error) => setNotice(errorMessage(error), true)));

    setAuthenticated(false);
    renderPresets();
    renderJobs();
    startPolling();
    probeAuthentication();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
