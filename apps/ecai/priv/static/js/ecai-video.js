/* ECAI Video Studio: same-origin Fastpath bridge; no provider secrets in browser storage. */
export function initVideoStudio({request, currentToken, managedSession, openLogin, toast}) {
  // ES modules are strict by default; strict directives are invalid with destructured parameters.
  const $ = (id) => document.getElementById(id);
  const ids = (object) => Object.entries(object).filter(([, value]) => value !== undefined);
  const state = {active: false, enabled: false, projects: [], backends: [], versions: [], project: "", version: "", job: null,
    timer: null, generation: 0, busy: false, mediaUrl: null, controller: null, policy: null};
  const ID = /^[0-9a-f]{32}$/;
  const uri = (path) => `/ecai/video/${path}`;
  function shorten(s, n = 15) { return String(s || "").length > n ? `${String(s).slice(0, n)}…` : String(s || ""); }
  function put(id, value) { if ($(id)) $(id).textContent = value ?? "—"; }
  function el(tag, className = "", text = "") {
    const node = document.createElement(tag);
    if (className) node.className = className;
    node.textContent = String(text ?? "");
    return node;
  }
  function errorText(error) {
    const detail = error?.body?.detail;
    const nested = detail?.detail ?? detail;
    if (typeof nested === "string") return nested.slice(0, 280);
    if (Array.isArray(nested)) return "Please check the form fields and backend configuration.";
    const code = error?.body?.error;
    return typeof code === "string" ? code.replace(/_/g, " ") : (error?.message || "Video service error");
  }
  function notice(message, bad = false) {
    put("videoNotice", message);
    $("videoNotice").classList.toggle("is-error", bad);
  }
  function setStatus(label, connected) {
    put("videoServiceState", label);
    $("videoStatusDot").classList.toggle("connected", connected);
  }
  function authenticated() {
    if (managedSession()) return true;
    notice("Video Studio requires a managed account. Sign in with email; wallet-only sessions cannot manage videos.", true);
    return false;
  }
  function requireAccount() {
    if (authenticated()) return true;
    openLogin("Sign in with your managed account to create and verify videos.");
    return false;
  }
  function requireProject() {
    if (!requireAccount()) return false;
    if (ID.test(state.project)) return true;
    notice("Create or choose a video project first.", true);
    return false;
  }
  function requireVersion() {
    if (!requireProject()) return false;
    if (ID.test(state.version)) return true;
    notice("Select a version from the library first.", true);
    return false;
  }
  function stopTimer() { if (state.timer) clearInterval(state.timer); state.timer = null; }
  function clearPreview() {
    state.controller?.abort(); state.controller = null;
    $("videoPlayer").pause(); $("videoPlayer").removeAttribute("src"); $("videoPlayer").load();
    $("videoPlayer").hidden = true; $("videoPreviewEmpty").hidden = false;
    if (state.mediaUrl) URL.revokeObjectURL(state.mediaUrl);
    state.mediaUrl = null;
  }
  function clearPrivate() {
    state.generation += 1;
    state.project = ""; state.version = ""; state.projects = []; state.versions = []; state.backends = [];
    state.job = null; state.policy = null; state.enabled = false;
    stopTimer(); clearPreview();
    $("videoProjectSelect").replaceChildren(new Option("Choose or create a project", ""));
    $("videoBackendSelect").replaceChildren(new Option("No backend selected", ""));
    $("videoVersions").replaceChildren(el("div", "empty-state", "Sign in to view your videos."));
    $("videoBackendKey").value = "";
    put("videoSelected", "No video version selected.");
    put("videoJobArea", "No active generation.");
    put("videoProofOutput", "Select a version to inspect its provenance.");
    put("videoVerifyResult", "No verification completed.");
    for (const key of ["videoMetricProjects", "videoMetricVersions", "videoMetricAvoided", "videoMetricSubmissions"]) put(key, "—");
    updateActions();
  }
  function updateActions() {
    const canProject = managedSession() && ID.test(state.project);
    const canVersion = canProject && ID.test(state.version);
    for (const id of ["videoReloadVersions", "videoGenerateBtn"]) $(id).disabled = !canProject || state.busy;
    for (const id of ["videoPreviewBtn", "videoDownloadBtn", "videoVerifyBtn", "videoReviseBtn", "videoManifestBtn", "videoNftBtn"])
      $(id).disabled = !canVersion || state.busy;
    $("videoGraphBtn").disabled = !canProject || state.busy;
    $("videoImportForm").querySelector('button[type="submit"]').disabled = !canProject || state.busy;
    $("videoBackendForm").querySelector('button[type="submit"]').disabled = !managedSession() || state.busy || !state.policy?.enabled;
  }
  async function busy(action) {
    if (state.busy) return;
    state.busy = true; updateActions();
    try { await action(); }
    catch (error) { if (error?.name !== "AbortError") { notice(errorText(error), true); toast(errorText(error), true); } }
    finally { state.busy = false; updateActions(); }
  }
  async function refresh() {
    if (!state.active) return;
    const generation = state.generation;
    try {
      const health = await request(uri("status"), {ignoreAuth: true});
      if (generation !== state.generation) return;
      state.enabled = Boolean(health.enabled);
      if (!health.enabled) {
        setStatus("Setup required", false);
        notice("Fastpath is not configured. Set ECAI_VIDEO_BRIDGE_SECRET on both ECAI and Fastpath, and ECAI_VIDEO_URL on the node. The studio remains visible while offline.", true);
        return;
      }
      if (!managedSession()) { setStatus("Sign in required", false); authenticated(); return; }
      const [projects, backends, policy] = await Promise.all([
        request(uri("projects")), request(uri("backends")), request(uri("backend-connection-policy"))
      ]);
      if (generation !== state.generation) return;
      state.projects = Array.isArray(projects) ? projects : [];
      state.backends = Array.isArray(backends) ? backends : [];
      state.policy = policy;
      setStatus("Fastpath connected", true);
      notice("Your projects, provider connections, video versions and signing history are scoped to this managed account.");
      renderProjects(); renderBackends(); updateActions();
      if (state.project) await refreshProject();
    } catch (error) {
      if (generation !== state.generation) return;
      setStatus("Service unavailable", false);
      notice(`Video service unavailable: ${errorText(error)}. Verify the Fastpath sidecar is running with the matching bridge secret.`, true);
    }
  }
  function renderProjects() {
    const select = $("videoProjectSelect");
    if (!state.projects.some((p) => p.id === state.project)) {
      state.project = state.projects[0]?.id || "";
      state.version = "";
    }
    select.replaceChildren(new Option("Choose or create a project", ""));
    for (const p of state.projects) select.add(new Option(p.title, p.id));
    select.value = state.project;
    put("videoMetricProjects", String(state.projects.length));
    updateActions();
  }
  function renderBackends() {
    const select = $("videoBackendSelect"), chosen = select.value;
    select.replaceChildren(new Option("Choose a backend", ""));
    for (const b of state.backends) select.add(new Option(`${b.label || b.id}${b.is_demo ? " · synthetic demo" : ""}`, b.id));
    select.value = state.backends.some((b) => b.id === chosen) ? chosen : state.backends[0]?.id || "";
    const policy = state.policy || {};
    put("videoConnectorPolicy", policy.enabled
      ? `Operator-approved connection hosts: ${(policy.approved_hosts || []).join(", ") || "none"}. URLs and downloads must meet the service's host policy.`
      : "Customer connectors are disabled by the node operator. Configure ECAI_VIDEO_FERNET_KEY and ECAI_VIDEO_ALLOWED_CONNECT_HOSTS on Fastpath to allow encrypted provider onboarding.");
  }
  async function refreshProject() {
    const pid = state.project;
    if (!ID.test(pid) || !managedSession()) { renderVersions(); return; }
    const generation = state.generation;
    const [versions, value, jobs] = await Promise.all([
      request(uri(`projects/${pid}/versions`)), request(uri(`projects/${pid}/value`)), request(uri(`projects/${pid}/jobs`))
    ]);
    if (generation !== state.generation || state.project !== pid) return;
    state.versions = Array.isArray(versions) ? versions : [];
    put("videoMetricVersions", String(state.versions.length));
    put("videoMetricAvoided", String(value?.avoided_provider_regenerations ?? 0));
    put("videoMetricSubmissions", String(value?.external_provider_submissions ?? 0));
    if (!state.versions.some((v) => v.id === state.version)) state.version = state.versions.at(-1)?.id || "";
    renderVersions(); selectVersion(state.version, false);
    const candidate = (Array.isArray(jobs) ? jobs : []).find((j) => !["completed", "failed", "needs_review"].includes(j.state));
    const latest = candidate || (Array.isArray(jobs) && jobs.length ? jobs[0] : null);
    state.job = latest; renderJob();
    if (candidate) startPolling(); else stopTimer();
  }
  function renderVersions() {
    const host = $("videoVersions"); host.replaceChildren();
    if (!state.versions.length) {
      host.append(el("div", "empty-state", state.project ? "No versions yet. Generate a video or import an MP4." : "Create or choose a project."));
      return;
    }
    for (const v of [...state.versions].reverse()) {
      const button = el("button", `video-version${v.id === state.version ? " is-selected" : ""}`);
      button.type = "button";
      const title = el("strong", "", `${v.operation.replace(/_/g, " ")} · ${shorten(v.id, 12)}`);
      const sub = el("span", "", `${v.parent_version_id ? "Revision" : "Original"} · sha256 ${shorten(v.output_sha256, 15)}`);
      button.append(title, sub);
      button.addEventListener("click", () => selectVersion(v.id));
      host.append(button);
    }
  }
  function selectVersion(id, clear = true) {
    if (!ID.test(id)) { state.version = ""; put("videoSelected", "No video version selected."); updateActions(); return; }
    if (id !== state.version || clear) {
      clearPreview();
      put("videoVerifyResult", "Not verified in this session.");
      put("videoProofOutput", "Use the manifest, graph or NFT actions to inspect provenance.");
    }
    state.version = id;
    renderVersions();
    const version = state.versions.find((v) => v.id === id);
    const processing = version?.sealed_manifest?.manifest?.processing;
    put("videoSelected", `${version?.operation || "Version"} · ${id} · ${processing?.provider_generation_skipped ? "No new AI generation" : "Generation/import"}${processing?.reused_exact_video_bytes ? " · identical media bytes" : ""}`);
    updateActions();
  }
  function renderJob() {
    const host = $("videoJobArea"); host.replaceChildren();
    if (!state.job) { host.textContent = "No generation job in this project."; return; }
    const job = state.job;
    const line = el("div", "video-job-summary");
    line.append(el("strong", "", `${job.backend || "Provider"} · ${job.state.replace(/_/g, " ")}`),
      el("span", "", `Job ${shorten(job.id, 14)} · ${job.attempts ?? 0} attempt(s)`));
    host.append(line);
    if (job.error) host.append(el("p", "video-job-error", job.error));
    if (["failed", "needs_review"].includes(job.state)) {
      const retry = el("button", "button button-outline button-sm", "Review and retry job");
      retry.type = "button";
      retry.addEventListener("click", () => busy(async () => {
        if (!requireProject() || !confirm("This job may already have been submitted upstream. Retrying could generate another billable provider request. Continue?")) return;
        state.job = await request(uri(`jobs/${job.id}/retry`), {method: "POST", body: {}});
        renderJob(); startPolling();
      }));
      host.append(retry);
    }
  }
  function startPolling() {
    stopTimer();
    if (!state.active || !state.job) return;
    state.timer = setInterval(async () => {
      if (document.hidden || !state.active || !state.job || !managedSession()) return;
      const expected = state.job.id, generation = state.generation;
      try {
        const job = await request(uri(`jobs/${expected}`));
        if (generation !== state.generation || !state.job || state.job.id !== expected) return;
        const prev = state.job.state;
        state.job = job; renderJob();
        if (["completed", "failed", "needs_review"].includes(job.state)) {
          stopTimer();
          if (job.state === "completed" && prev !== "completed") await refreshProject();
        }
      } catch (_) { stopTimer(); notice("Unable to poll generation. Refresh the studio to recover the persisted job.", true); }
    }, 4000);
  }
  async function uploadVideo(file) {
    if (file.size > 25 * 1024 * 1024) throw new Error("Dashboard MP4 upload is limited to 25 MiB.");
    const token = currentToken();
    if (!token) throw new Error("Sign in before uploading.");
    const response = await fetch(uri(`projects/${state.project}/assets`), {
      method: "POST", mode: "same-origin", credentials: "include", redirect: "error", cache: "no-store",
      headers: {Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "video/mp4"},
      body: file
    });
    if (token !== currentToken()) throw new DOMException("Session changed", "AbortError");
    const data = await response.json();
    if (!response.ok) throw Object.assign(new Error(`HTTP ${response.status}`), {body: data});
    return data;
  }
  async function loadMedia(download = false) {
    if (!requireVersion()) return;
    const version = state.version, token = currentToken();
    clearPreview();
    const controller = new AbortController(); state.controller = controller;
    const response = await fetch(uri(`versions/${version}/video`), {
      method: "GET", mode: "same-origin", credentials: "include", redirect: "error", cache: "no-store",
      headers: {Authorization: `Bearer ${token}`, Accept: "video/mp4"}, signal: controller.signal
    });
    if (!response.ok) {
      let detail = {}; try { detail = await response.json(); } catch (_) { /* bounded user message */ }
      throw Object.assign(new Error(`HTTP ${response.status}`), {body: detail});
    }
    const blob = await response.blob();
    if (token !== currentToken() || state.version !== version || controller.signal.aborted)
      throw new DOMException("Session or version changed", "AbortError");
    if (blob.size > 25 * 1024 * 1024) throw new Error("Preview limit exceeded (25 MiB).");
    const url = URL.createObjectURL(blob);
    state.mediaUrl = url;
    if (download) {
      const link = el("a"); link.href = url; link.download = `ecai-${version}.mp4`;
      document.body.append(link); link.click(); link.remove();
      // Keep the object URL until the next preview or session reset.
    } else {
      $("videoPlayer").src = url;
      $("videoPlayer").hidden = false; $("videoPreviewEmpty").hidden = true;
      $("videoPlayer").load();
    }
  }
  function setVisible(active) {
    state.active = active;
    if (!active) { stopTimer(); clearPreview(); }
    else if (state.job && !["completed", "failed", "needs_review"].includes(state.job.state)) startPolling();
  }
  function reset() { clearPrivate(); setStatus("Sign in required", false); notice("Sign in with a managed account to use Video Studio."); }

  function on(id, event, callback) { $(id).addEventListener(event, callback); }
  on("videoRefresh", "click", () => busy(refresh));
  on("videoStartProject", "click", () => { $("videoProjectTitle").focus(); $("videoProjectSection").scrollIntoView({behavior: "smooth", block: "center"}); });
  on("videoProjectForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireAccount()) return;
    const title = $("videoProjectTitle").value.trim(), license = $("videoLicense").value.trim();
    if (!title || !license) throw new Error("Project name and licence are required.");
    const tags = $("videoTags").value.split(",").map((v) => v.trim()).filter(Boolean).slice(0, 16);
    const created = await request(uri("projects"), {method: "POST", body: {title, license, tags}});
    state.project = created.id; state.version = "";
    $("videoProjectTitle").value = ""; notice("Project created. Choose a backend, import an MP4 or generate a new video.");
    await refresh();
  }); });
  on("videoProjectSelect", "change", () => busy(async () => {
    state.project = $("videoProjectSelect").value; state.version = ""; state.job = null;
    state.versions = []; stopTimer(); clearPreview(); updateActions();
    await refreshProject();
  }));
  on("videoBackendForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireAccount()) return;
    const config = {
      id: $("videoBackendId").value.trim(), kind: $("videoBackendKind").value,
      url: $("videoBackendUrl").value.trim(), api_key: $("videoBackendKey").value,
      auth_scheme: $("videoBackendAuthScheme").value,
      download_hosts: $("videoBackendHosts").value.split(",").map((x) => x.trim()).filter(Boolean),
      output_path: $("videoBackendResultPath").value.trim() || "video_url", defaults: {}, allowed_parameters: []
    };
    await request(uri("backends"), {method: "POST", body: config});
    $("videoBackendKey").value = "";
    state.backends = await request(uri("backends"));
    renderBackends(); $("videoBackendSelect").value = config.id;
    $("videoConnectorDetails").open = false;
    notice(`Backend ${config.id} registered for this account.`);
  }); });
  on("videoGenerateForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireProject()) return;
    const backend = $("videoBackendSelect").value;
    const prompt = $("videoPrompt").value.trim();
    if (!backend || !prompt) throw new Error("Choose a backend and enter a video prompt.");
    const selected = state.backends.find((b) => b.id === backend);
    if (!selected?.is_demo && !confirm("Submit this video generation to the selected provider? It may incur external API charges.")) return;
    state.job = await request(uri(`projects/${state.project}/generations`), {
      method: "POST", body: {backend_id: backend, prompt, parameters: {}}
    });
    renderJob(); startPolling(); notice("Generation queued. This job can recover after the service restarts.");
  }); });
  on("videoImportForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireProject()) return;
    const file = $("videoImportFile").files?.[0];
    if (!file || !file.name.toLowerCase().endsWith(".mp4")) throw new Error("Choose an MP4 file.");
    const result = await uploadVideo(file);
    $("videoImportFile").value = "";
    await refreshProject(); selectVersion(result.version.id);
    notice("MP4 registered and signed. Reuse the source or create local revisions.");
  }); });
  on("videoReloadVersions", "click", () => busy(refreshProject));
  on("videoOperation", "change", () => {
    const op = $("videoOperation").value;
    $("videoRevisionTextLabel").hidden = op === "trim";
    $("videoTrimFields").hidden = op !== "trim";
    $("videoRevisionTextLabel").firstChild.textContent = op === "caption" ? "On-video caption" : "Revision note";
    $("videoRevisionText").maxLength = op === "caption" ? 400 : 1000;
  });
  on("videoRevisionForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireVersion()) return;
    const operation = $("videoOperation").value;
    let options;
    if (operation === "trim") options = {start_seconds: Number($("videoTrimStart").value), end_seconds: Number($("videoTrimEnd").value)};
    else options = {[operation === "caption" ? "text" : "note"]: $("videoRevisionText").value.trim()};
    if (operation === "caption" && !options.text) throw new Error("Enter a caption to render.");
    const created = await request(uri(`projects/${state.project}/versions`), {
      method: "POST", body: {parent_version_id: state.version, operation, options}
    });
    await refreshProject(); selectVersion(created.id);
    notice(created.cache_hit ? "Identical revision found; cached output reused." :
      (operation === "metadata" ? "Exact MP4 reused. No model or renderer call." : "Local revision rendered without a model call."));
  }); });
  on("videoPreviewBtn", "click", () => busy(() => loadMedia(false)));
  on("videoDownloadBtn", "click", () => busy(() => loadMedia(true)));
  on("videoVerifyBtn", "click", () => busy(async () => {
    if (!requireVersion()) return;
    const result = await request(uri(`versions/${state.version}/verify`));
    put("videoVerifyResult", `${result.verified ? "VERIFIED" : "VERIFICATION FAILED"} · signature ${result.signature_valid ? "valid" : "invalid"} · bytes ${result.bytes_match_sha256 ? "match" : "mismatch"} · lineage ${result.lineage_valid ? "valid" : "invalid"}`);
    $("videoVerifyResult").classList.toggle("is-error", !result.verified);
    put("videoProofOutput", JSON.stringify(result, null, 2));
    notice(result.verified ? "Video bytes, signature and ancestry verified." : "Integrity verification failed. Do not publish this version.", !result.verified);
  }));
  on("videoManifestBtn", "click", () => busy(async () => {
    if (!requireVersion()) return;
    const result = await request(uri(`versions/${state.version}/manifest`));
    put("videoProofOutput", JSON.stringify(result, null, 2));
  }));
  on("videoGraphBtn", "click", () => busy(async () => {
    if (!requireProject()) return;
    put("videoProofOutput", JSON.stringify(await request(uri(`projects/${state.project}/graph`)), null, 2));
  }));
  on("videoNftForm", "submit", (e) => { e.preventDefault(); busy(async () => {
    if (!requireVersion()) return;
    const cid = $("videoCid").value.trim();
    if (!/^[a-zA-Z0-9]{10,160}$/.test(cid)) throw new Error("Enter a valid IPFS CID.");
    const draft = await request(uri(`versions/${state.version}/nft-draft`), {method: "POST", body: {video_cid: cid}});
    put("videoProofOutput", JSON.stringify(draft, null, 2));
    notice("NFT metadata draft prepared. Neither IPFS publication nor on-chain minting has occurred.");
  }); });
  updateActions();
  return {refresh, setVisible, reset, accountChanged: updateActions, dispose: () => {stopTimer(); clearPreview();}};
}
