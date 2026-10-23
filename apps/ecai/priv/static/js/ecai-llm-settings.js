/* Node-admin provider registry. The server, never these UI hints, authorizes.
 * API keys live only in volatile draft memory and are cleared after every save
 * attempt, navigation away, and identity change. No third-party code or HTML. */
export function initLlmSettings({request, canManage}) {
  const $ = id => document.getElementById(id);
  const root = document.querySelector('[data-panel="ai-providers"]');
  if (!root) return {refresh() {}, reset() {}, accessChanged() {}, setVisible() {}};
  const roles = [["learning", "Learning"], ["audit", "Audit"], ["patch", "Repair"],
    ["synthesis", "Synthesis"], ["chat", "Chat"], ["bdd", "DamageBDD AI"]];
  const providers = {ollama: "Ollama", openai: "OpenAI", anthropic: "Claude / Anthropic"};
  const fields = {id: "llmId", provider: "llmProvider", host: "llmHost", port: "llmPort",
    transport: "llmTransport", default_model: "llmModel", models: "llmModels", enabled: "llmEnabled",
    auth_type: "llmAuthType", credential_ref: "llmCredentialRef", max_inflight: "llmInflight",
    weight: "llmWeight", timeout_ms: "llmTimeout", connect_timeout_ms: "llmConnectTimeout",
    max_output_tokens: "llmOutputTokens", temperature: "llmTemperature"};
  const runtimeFields = {health_interval_ms: "llmHealthInterval", health_timeout_ms: "llmHealthTimeout",
    failure_threshold: "llmFailureThreshold", queue_timeout_ms: "llmQueueTimeout", cluster_attempts: "llmAttempts"};
  const numeric = new Set(["port", "max_inflight", "weight", "timeout_ms", "connect_timeout_ms", "max_output_tokens", "temperature"]);
  let data = null, draft = null, revision = null, selected = 0, dirty = false;
  let visible = false, granted = false, loading = false, busy = false, epoch = 0, keys = new Map();
  const el = (tag, cls, value) => {const e = document.createElement(tag); e.className = cls;
    if (value !== undefined) e.textContent = String(value); return e;};
  const text = (id, v) => {$(id).textContent = String(v ?? "—");};
  const notice = (v, error = false) => {text("llmNotice", v); $("llmNotice").dataset.error = String(error);};
  const current = () => draft?.connections[selected];
  const unwrap = r => {if (r?.ok !== true || !Number.isInteger(r.llm_settings?.revision) || !r.llm_settings?.config)
    throw new Error("The server did not return a valid provider configuration."); return r.llm_settings;};
  const errorMessage = e => {
    if ([401, 403].includes(e?.status)) return "Sign in with a server-authorized node administrator account.";
    const code = e?.body?.error;
    if (e?.status === 409 || code === "stale_revision") return "Another administrator changed these settings. Your non-secret edits are preserved. Refresh, then discard edits to load the new revision.";
    const friendly = {endpoint_not_allowed: "This endpoint is not approved. Declare additional Ollama hosts/ports in server configuration before using them here.",
      remote_role_not_allowed: "Explicitly allow non-loopback processing for every role assigned to an enabled remote connection.",
      credential_store_unavailable: "The DamageBDD secret vault is unavailable or locked. No key was saved in the settings file.",
      inherited_credential_endpoint_changed: "Changing a destination requires choosing a new credential source. Inherited credentials cannot move to another endpoint.",
      environment_reference_not_allowed: "That environment-variable reference is not approved by this node.",
      inference_pool_unavailable: "The inference pool is not running. Check the code-security supervisor before saving."};
    return friendly[code] || (typeof code === "string" ? code.replaceAll("_", " ") : e?.message || "Provider settings are unavailable.");
  };
  function clearKeys() {keys.clear(); $("llmApiKey").value = ""; text("llmKeyState", "No replacement key queued.");}
  function controls() {
    const allowed = granted && canManage() && draft !== null && !busy && !loading;
    $("llmFields").disabled = !allowed;
    $("llmSave").disabled = !allowed || !dirty;
    $("llmDiscard").disabled = !allowed || !dirty;
    $("llmRefresh").disabled = busy || loading || !canManage();
    const c = current();
    const saved = data?.config.connections.find(n => n.id === c?.id);
    $("llmAuthType").querySelector('[value="vault"]').disabled = saved?.auth_type !== "vault";
    for (const e of $("llmEditor").querySelectorAll("input,select,button")) e.disabled = !allowed || !c;
    $("llmRemove").disabled = !allowed || !c;
    $("llmProbe").disabled = !allowed || !c || dirty || !data.config.connections.some(n => n.id === c.id);
    $("llmCredentialRef").readOnly = !c || c.auth_type !== "environment";
    $("llmId").readOnly = Boolean(c && data?.config.connections.some(n => n.id === c.id));
    $("llmModel").required = c?.enabled === true;
    $("llmTemperature").max = c?.provider === "anthropic" ? "1" : "2";
    text("llmDraftState", dirty ? `Unsaved edits · based on r${revision}` : draft ? `Saved · r${revision}` : "No draft");
  }
  function fillEditor() {
    const c = current(); $("llmEditor").hidden = !c; $("llmEmpty").hidden = Boolean(c);
    $("llmApiKey").value = ""; $("llmDiscoveredModels").replaceChildren();
    text("llmProbeResult", "Tests use the saved connection. No text-generation request is sent.");
    if (c) {
      text("llmEditorTitle", c.id || "New connection");
      for (const [key, id] of Object.entries(fields)) {
        if (key === "enabled") $(id).checked = c[key] === true;
        else $(id).value = key === "models" && Array.isArray(c[key]) ? c[key].join(", ") : c[key] ?? "";
      }
      text("llmKeyState", keys.has(c) ? "A replacement key is queued in this unsaved draft." : "No replacement key queued.");
    }
    controls();
  }
  function renderConnections() {
    const list = $("llmConnectionList"); list.replaceChildren();
    for (const [index, c] of (draft?.connections || []).entries()) {
      const health = data?.pool?.nodes?.find(n => n.id === c.id);
      const b = el("button", "llm-connection"); b.type = "button";
      b.setAttribute("aria-pressed", String(index === selected));
      b.append(el("strong", "", c.id || "New connection"), el("small", "", `${providers[c.provider]} · ${c.enabled ? health?.health || "not tested" : "disabled"}`),
        el("small", "", c.default_model || "Choose a model after discovery"));
      b.addEventListener("click", () => {selected = index; renderConnections(); fillEditor();}); list.append(b);
    }
    if (!draft?.connections.length) list.append(el("p", "context-hint", "No connections. Add a provider to begin."));
  }
  function checkbox(label, checked, onChange) {
    const l = el("label", "llm-toggle"), c = document.createElement("input"); c.type = "checkbox"; c.checked = checked;
    c.setAttribute("aria-label", label); c.addEventListener("change", () => onChange(c.checked)); l.append(c, document.createTextNode(label)); return l;
  }
  function renderRoles() {
    const rows = $("llmRoleRows"); rows.replaceChildren();
    for (const c of draft?.connections || []) {
      const row = el("tr", ""); const name = el("th", "", c.id); name.scope = "row"; row.append(name);
      for (const [role, title] of roles) {
        const cell = el("td", ""), check = document.createElement("input"); check.type = "checkbox";
        check.checked = c.roles.includes(role); check.setAttribute("aria-label", `${c.id}: ${title}`);
        check.addEventListener("change", () => {c.roles = check.checked ? [...c.roles, role] : c.roles.filter(r => r !== role); markDirty();});
        cell.append(check); row.append(cell);
      }
      rows.append(row);
    }
    const remote = $("llmRemoteRoles"); remote.replaceChildren();
    for (const [role, title] of roles) remote.append(checkbox(title, draft?.remote_roles.includes(role), checked => {
      draft.remote_roles = checked ? [...draft.remote_roles, role] : draft.remote_roles.filter(r => r !== role); markDirty();
    }));
  }
  function renderSnapshot() {
    text("llmRevision", `r${data.revision}`); text("llmSource", data.source === "deployment" ? "Inherited deployment configuration" : "Persisted dashboard override");
    text("llmConnectionCount", data.config.connections.length);
    text("llmRuntimeState", data.pool?.available ? (data.pool.revision === data.revision ? "Applied" : "Pending apply") : "Unavailable");
    text("llmRuntimeRevision", data.pool?.available ? `Pool revision r${data.pool.revision}` : "Check the code-security supervisor");
    const profiles = $("llmDamageProfiles"); profiles.replaceChildren();
    for (const p of data.damage_profiles || []) profiles.append(el("div", "llm-profile", `${p.name} · ${p.shared_registry ? "Shared registry / DamageBDD AI role" : "Existing standalone backend (unchanged)"}`));
    if (!data.damage_profiles?.length) profiles.append(el("p", "context-hint", "No DamageBDD AI profiles configured. Add an authorized damage_ai_ecai profile in deployment configuration to opt in."));
  }
  function fillDraft() {
    draft = structuredClone(data.config); revision = data.revision; dirty = false; clearKeys();
    selected = Math.max(0, Math.min(selected, draft.connections.length - 1));
    $("llmRouteChat").checked = draft.route_chat;
    for (const [k, id] of Object.entries(runtimeFields)) $(id).value = draft.runtime[k];
    renderConnections(); renderRoles(); fillEditor();
  }
  function markDirty() {dirty = true; controls();}
  async function refresh(discard = false) {
    if (!visible || busy || loading) return;
    if (!canManage()) {reset(); notice("Sign in with a server-authorized node administrator account."); return;}
    const ticket = epoch; loading = true; controls();
    try {
      const next = unwrap(await request("/ecai/admin/llm/settings"));
      if (ticket !== epoch || !canManage()) return;
      data = next; granted = true; renderSnapshot();
      if (!dirty || discard) fillDraft(); else renderConnections();
      notice(dirty ? `Saved revision r${data.revision}; your draft based on r${revision} is unchanged.` : "Administrator access confirmed. No generation request has been sent. Save a new connection disabled to discover models before enabling it.");
    } catch (e) {
      if (ticket !== epoch) return;
      if ([401, 403].includes(e.status)) reset(); else granted = false;
      notice(errorMessage(e), true);
    } finally {if (ticket === epoch) {loading = false; controls();}}
  }
  async function save(event) {
    event.preventDefault();
    if (!granted || !canManage() || busy || !dirty || !$("llmForm").reportValidity()) return;
    if (!window.confirm("Apply these node-wide provider and role settings? Enabled remote roles may send workload text to the configured provider. Active requests will finish with their previous settings.")) return;
    const ticket = epoch, config = structuredClone(draft);
    config.connections.forEach((c, i) => {if (keys.has(draft.connections[i])) c.api_key = keys.get(draft.connections[i]);});
    busy = true; controls();
    try {
      const next = unwrap(await request("/ecai/admin/llm/settings/update", {method: "POST", body: {revision, config}}));
      if (ticket !== epoch || !canManage()) return;
      data = next; renderSnapshot(); fillDraft();
      notice(next.pool?.available && next.pool.revision === next.revision
        ? `Saved and applied r${next.revision}. Active requests retain their original settings.`
        : `Saved r${next.revision}; runtime application is not yet confirmed. Check the supervisor and refresh.`);
    } catch (e) {if (ticket === epoch) notice(errorMessage(e), true);}
    finally {
      for (const c of config.connections) delete c.api_key;
      if (ticket === epoch) {clearKeys(); busy = false; controls();}
    }
  }
  async function probe() {
    if (busy || dirty || !current() || !granted || !canManage()) return;
    const ticket = epoch, id = current().id; busy = true; controls(); text("llmProbeResult", "Checking the saved connection…");
    try {
      const result = await request("/ecai/admin/llm/probe", {method: "POST", body: {revision, id}});
      if (ticket !== epoch || !canManage()) return;
      if (result?.ok !== true || !Array.isArray(result.probe?.models)) throw new Error("The provider did not return a model list.");
      const models = result.probe.models.filter(m => typeof m === "string");
      const list = $("llmDiscoveredModels"); list.replaceChildren();
      for (const model of models.slice(0, 1000)) {const option = document.createElement("option"); option.value = model; list.append(option);}
      text("llmProbeResult", `${models.length} model(s) listed in ${result.probe.elapsed_ms} ms. Choose a model above; generation was not tested.`);
    } catch (e) {if (ticket === epoch) text("llmProbeResult", `Connection test failed: ${errorMessage(e)}`);}
    finally {if (ticket === epoch) {busy = false; controls();}}
  }
  function defaults(provider, id) {
    const local = provider === "ollama";
    return {id, provider, enabled: false, host: local ? "127.0.0.1" : provider === "openai" ? "api.openai.com" : "api.anthropic.com",
      port: local ? 11434 : 443, transport: local ? "tcp" : "tls", default_model: "", models: "all", roles: [],
      weight: 1, max_inflight: 1, timeout_ms: 180000, connect_timeout_ms: 5000, max_output_tokens: 4096,
      temperature: null, auth_type: local ? "none" : "environment",
      credential_ref: local ? "" : provider === "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"};
  }
  for (const [key, id] of Object.entries(fields)) $(id).addEventListener("input", () => {
    const c = current(); if (!c || !granted || busy) return;
    if (key === "provider") {
      const next = defaults($(id).value, c.id); keys.delete(c);
      Object.assign(c, next); fillEditor(); renderConnections(); renderRoles();
    } else {
      const value = $(id).value;
      c[key] = key === "enabled" ? $(id).checked : numeric.has(key) ? (value === "" ? null : Number(value))
        : key === "models" ? (value.trim() === "all" ? "all" : value.split(",").map(v => v.trim()).filter(Boolean)) : value.trim();
      if (key === "auth_type") {
        c.credential_ref = c.auth_type === "vault" ? (data?.config.connections.find(n => n.id === c.id && n.auth_type === "vault")?.credential_ref || "") : c.auth_type === "environment" ? (c.provider === "anthropic" ? "ANTHROPIC_API_KEY" : c.provider === "openai" ? "OPENAI_API_KEY" : "OLLAMA_API_KEY") : "";
        fillEditor();
      }
      if (["id", "default_model", "enabled"].includes(key)) {renderConnections(); if (key === "id") renderRoles();}
    }
    markDirty();
  });
  for (const [key, id] of Object.entries(runtimeFields)) $(id).addEventListener("input", () => {
    if (draft && granted && !busy) {draft.runtime[key] = Number($(id).value); markDirty();}
  });
  $("llmApiKey").addEventListener("input", () => {
    const c = current(); if (!c || !granted || busy) return;
    const value = $("llmApiKey").value; if (value) keys.set(c, value); else keys.delete(c);
    text("llmKeyState", value ? "Replacement key queued. It will be cleared from this form after the save attempt." : "No replacement key queued."); markDirty();
  });
  $("llmRouteChat").addEventListener("change", () => {if (draft) {draft.route_chat = $("llmRouteChat").checked; markDirty();}});
  $("llmAdd").addEventListener("click", () => {
    if (!draft || busy || !granted || draft.connections.length >= 32) return;
    const provider = $("llmAddProvider").value; let i = 1;
    while (draft.connections.some(c => c.id === `${provider}-${i}`)) i++;
    draft.connections.push(defaults(provider, `${provider}-${i}`)); selected = draft.connections.length - 1;
    markDirty(); renderConnections(); renderRoles(); fillEditor();
  });
  $("llmRemove").addEventListener("click", () => {
    const c = current(); if (!c || busy || !granted || !window.confirm(`Remove ${c.id} from the registry on the next save? Its vault entries will not be deleted.`)) return;
    keys.delete(c); draft.connections.splice(selected, 1); selected = Math.max(0, selected - 1);
    markDirty(); renderConnections(); renderRoles(); fillEditor();
  });
  $("llmForm").addEventListener("submit", save);
  $("llmRefresh").addEventListener("click", () => refresh());
  $("llmDiscard").addEventListener("click", () => {if (window.confirm("Discard unsaved provider edits?")) {clearKeys(); refresh(true);}});
  $("llmProbe").addEventListener("click", probe);
  function reset() {
    epoch++; clearKeys(); data = null; draft = null; revision = null; dirty = false; granted = false; busy = false; loading = false; selected = 0;
    $("llmConnectionList").replaceChildren(); $("llmRoleRows").replaceChildren(); $("llmRemoteRoles").replaceChildren(); $("llmEditor").hidden = true; $("llmEmpty").hidden = false;
    for (const id of ["llmRevision", "llmSource", "llmRuntimeState", "llmRuntimeRevision", "llmConnectionCount", "llmDamageProfiles"]) text(id, "Not loaded");
    controls();
  }
  controls();
  return {refresh, reset,
    accessChanged() {if (!canManage()) {reset(); notice("Node-administrator access is required.");} else controls();},
    setVisible(value) {visible = value; if (!value) {epoch++; clearKeys(); busy = false; loading = false;} controls();}
  };
}
