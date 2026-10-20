/* Node-admin Model Internals. Backend is authoritative; hints only gate the UI.
 * No third-party dependencies, executable uploads, raw HTML or provider URLs. */
export function initModelInternals({request, canManage}) {
  const $ = id => document.getElementById(id);
  const root = $("modelInternalsPanel");
  if (!root) return {setVisible() {}, refresh() {}, reset() {}, accessChanged() {}, poll() {}};
  const fields = {
    ollama: {temperature: "miTemperature", top_p: "miTopP", top_k: "miTopK", min_p: "miMinP",
      seed: "miSeed", repeat_penalty: "miRepeatPenalty", num_ctx: "miNumCtx", max_output_tokens: "miMaxOutput"},
    openai: {temperature: "miOpenaiTemperature", max_output_tokens: "miOpenaiMaxOutput"}
  };
  let visible = false, epoch = 0, loading = false, busy = false, dirty = false;
  let data = null, baseRevision = null, granted = false, lastPoll = 0;
  const text = (id, value) => { $(id).textContent = String(value ?? "—"); };
  const el = (tag, cls, value) => { const n = document.createElement(tag); n.className = cls; if (value !== undefined) n.textContent = String(value); return n; };
  const notice = (message, error = false) => {text("miNotice", message); $("miNotice").dataset.error = String(error);};
  const message = error => error?.body?.error === "stale_revision" || error?.status === 409
    ? "Another administrator changed this policy. Your draft is preserved. Refresh telemetry, then discard local edits to load the latest revision before editing again."
    : error?.message || "Model Internals is unavailable.";
  const unwrap = response => {
    if (response?.ok !== true || !response.model_internals) throw new Error("The server did not return Model Internals data.");
    return response.model_internals;
  };
  function controls() {
    const allowed = granted && canManage() && data !== null;
    $("miFields").disabled = !allowed || busy;
    $("miSave").disabled = !allowed || busy || !dirty;
    $("miDiscard").disabled = !allowed || busy || !dirty;
    $("miPreview").disabled = !allowed || busy;
    $("miRefresh").disabled = loading || busy || !canManage();
    text("miDraftState", dirty ? `Unsaved · based on r${baseRevision}` : data ? `Saved · r${baseRevision}` : "No draft");
  }
  function fill(config, revision) {
    $("miEnabled").checked = config.enabled === true;
    $("miPatchSchema").checked = config.patch_json_schema === true;
    $("miSystemSuffix").value = config.system_suffix || "";
    for (const check of root.querySelectorAll('[name="miRole"]')) check.checked = (config.roles || []).includes(check.value);
    for (const [provider, mapping] of Object.entries(fields)) {
      for (const [key, id] of Object.entries(mapping)) $(id).value = config[provider]?.[key] ?? "";
    }
    baseRevision = revision; dirty = false;
  }
  function draft() {
    if (!$("miForm").reportValidity()) throw new Error("Correct the highlighted numeric values before continuing.");
    const roles = [...root.querySelectorAll('[name="miRole"]:checked')].map(n => n.value);
    if (!roles.length) throw new Error("Select at least one code role.");
    const system = $("miSystemSuffix").value;
    if (new TextEncoder().encode(system).byteLength > 2048) throw new Error("System guidance exceeds 2,048 UTF-8 bytes.");
    const config = {enabled: $("miEnabled").checked, roles, system_suffix: system, patch_json_schema: $("miPatchSchema").checked};
    for (const [provider, mapping] of Object.entries(fields)) {
      config[provider] = {};
      for (const [key, id] of Object.entries(mapping)) {
        const raw = $(id).value.trim(), value = raw === "" ? null : Number(raw);
        if (value !== null && !Number.isFinite(value)) throw new Error("Enter a finite number or leave the field blank.");
        config[provider][key] = value;
      }
    }
    return config;
  }
  function events(id, entries, render, empty) {
    const target = $(id); target.replaceChildren();
    if (!entries.length) {target.append(el("p", "context-hint", empty)); return;}
    for (const entry of entries.slice(0, 32)) target.append(render(entry));
  }
  function render() {
    text("miPolicyState", data.config.enabled ? "Enabled" : "Disabled");
    text("miPolicyScope", `Roles: ${data.config.roles.join(", ")}`);
    text("miRevision", `r${data.revision}`); text("miUpdatedAt", data.updated_at || "Never changed");
    text("miConfigHash", data.config_sha256);
    const nodes = data.pool?.nodes || [];
    text("miNodeCount", data.pool?.state === "available" ? nodes.length : "Unavailable");
    text("miPoolState", data.pool?.state || "Unavailable");
    const caps = $("miCapabilities"); caps.replaceChildren();
    for (const cap of data.capabilities || []) {
      const item = el("article", "mi-capability");
      item.dataset.state = cap.state === "wired" ? "wired" : "bridge_required";
      const title = el("div", ""); title.append(el("strong", "", cap.title), el("span", "status-tag", cap.state === "wired" ? "Wired" : "Runtime required"));
      item.append(title, el("p", "", cap.note)); caps.append(item);
    }
    events("miChanges", data.changes || [], item => {
      const row = el("article", "mi-event"); row.append(el("strong", "", `Revision ${item.revision}`), el("p", "", `${item.at} · ${item.actor}`)); return row;
    }, "No policy changes recorded.");
    events("miNodes", nodes, node => {
      const item = el("article", "mi-node");
      item.append(el("strong", "", `${node.id} · ${node.provider}`), el("p", "", `${node.default_model || "Role-specific model"} · ${node.health || "unknown"}`),
        el("p", "", `${node.inflight ?? 0}/${node.max_inflight ?? "?"} in flight · ${(node.roles || []).join(", ")}`));
      return item;
    }, "Inference pool unavailable or no configured targets. No discovery request was sent to a remote provider.");
    events("miObservations", data.observations || [], item => {
      const row = el("article", "mi-event"), policy = item.model_internals;
      row.append(el("strong", "", `${item.role || "code"} · ${item.provider || "unknown"} · ${item.model || "unknown"}`),
        el("p", "", `${item.observed_at || ""} · ${policy ? `policy r${policy.revision}` : "inherited settings"}${item.cache_hit ? " · receipt cache hit" : ""}`),
        el("p", "", `${item.wall_duration_ms ?? "—"} ms · ${item.eval_count ?? "—"} output tokens`));
      if (policy) row.append(el("p", "", `Policy ${policy.config_sha256} · applied: ${(policy.applied || []).join(", ") || "no numeric overrides"}`));
      return row;
    }, "No successful code inference observed since this service started.");
    controls();
  }
  async function refresh() {
    if (!visible || busy || loading) return;
    if (!canManage()) {notice("Sign in with a server-authorized node administrator account."); controls(); return;}
    const ticket = epoch; loading = true; controls();
    try {
      const next = unwrap(await request("/ecai/admin/code/model-internals"));
      if (ticket !== epoch || !canManage()) return;
      if (!next.config || !Number.isInteger(next.revision)) throw new Error("The server returned an invalid policy snapshot.");
      data = next; granted = true; lastPoll = Date.now();
      if (!dirty) fill(data.config, data.revision);
      render();
      notice(dirty ? `Telemetry refreshed; your draft based on r${baseRevision} is unchanged. Saved revision: r${data.revision}.`
        : "Administrator access confirmed. Draft previews do not call models. Blank values inherit existing settings.");
    } catch (error) {
      if (ticket !== epoch) return;
      if ([401, 403].includes(error.status)) {reset(); notice("Model Internals requires a server-authorized node administrator.", true);}
      else {granted = false; notice(message(error), true);}
    } finally {if (ticket === epoch) {loading = false; controls();}}
  }
  async function save(event) {
    event.preventDefault();
    if (!granted || busy || !canManage()) return;
    const ticket = epoch;
    try {
      const config = draft();
      if (!window.confirm("Save node-wide inference policy? This affects new requests for the selected code roles, not in-flight requests or publication approvals.")) return;
      busy = true; controls();
      const saved = unwrap(await request("/ecai/admin/code/model-internals/update", {method: "POST", body: {revision: baseRevision, config}}));
      if (ticket !== epoch || !canManage()) return;
      data = {...data, ...saved}; fill(saved.config, saved.revision); render();
      notice(`Saved revision ${saved.revision}. New selected-role requests will use this snapshot. Publication gates are unchanged.`);
      text("miPreviewOutput", "Policy saved. Preview again to inspect the current draft overrides.");
    } catch (error) {
      if (ticket === epoch) {
        if ([401, 403].includes(error.status)) {reset(); notice("Authorization changed. Sign in again before editing this node policy.", true);}
        else notice(message(error), true);
      }
    } finally {if (ticket === epoch) {busy = false; controls();}}
  }
  async function preview() {
    if (!granted || busy || !canManage()) return;
    const ticket = epoch;
    try {
      const body = {config: draft(), provider: $("miPreviewProvider").value, role: $("miPreviewRole").value};
      busy = true; controls();
      const result = unwrap(await request("/ecai/admin/code/model-internals/preview", {method: "POST", body}));
      if (ticket !== epoch || !canManage()) return;
      text("miPreviewOutput", JSON.stringify(result, null, 2));
      notice("Draft validated. No inference was run and no settings were saved.");
    } catch (error) {
      if (ticket === epoch) {
        if ([401, 403].includes(error.status)) {reset(); notice("Authorization changed. Sign in again before previewing.", true);}
        else notice(message(error), true);
      }
    } finally {if (ticket === epoch) {busy = false; controls();}}
  }
  function reset() {
    epoch++; loading = false; busy = false; dirty = false; data = null; granted = false; baseRevision = null; lastPoll = 0;
    $("miForm").reset();
    for (const id of ["miCapabilities", "miNodes", "miChanges", "miObservations"]) $(id).replaceChildren();
    for (const id of ["miRevision", "miNodeCount", "miUpdatedAt", "miConfigHash", "miPolicyScope", "miPoolState"]) text(id, "—");
    text("miPolicyState", "Not loaded"); text("miPreviewOutput", "No preview requested.");
    notice("Sign in with a server-authorized node administrator account."); controls();
  }
  $("miForm").addEventListener("submit", save);
  $("miForm").addEventListener("input", () => {if (granted) {dirty = true; controls();}});
  $("miRefresh").addEventListener("click", refresh);
  $("miPreview").addEventListener("click", preview);
  $("miDiscard").addEventListener("click", () => {
    if (!data || busy) return;
    if (dirty && !window.confirm("Discard your local edits and load the last fetched policy revision?")) return;
    fill(data.config, data.revision); controls(); text("miPreviewOutput", "Draft reset. Preview again to inspect overrides.");
    notice(`Loaded saved revision ${data.revision}.`);
  });
  controls();
  return {
    refresh, reset,
    setVisible(value) {visible = value;},
    accessChanged() {if (!canManage()) {if (data || loading || busy) reset();} else if (visible && !data && !loading) void refresh();},
    poll() {if (visible && Date.now() - lastPoll > 25000) void refresh();}
  };
}
