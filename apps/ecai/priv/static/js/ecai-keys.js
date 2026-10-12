(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  let api = null;
  let config = null;
  let issued = null;
  let secretTimer = null;

  function showNotice(message, bad = false) {
    const node = $("ollamaKeysNotice");
    if (!node) return;
    node.textContent = message;
    node.classList.toggle("is-error", bad);
  }
  function fmtWhen(ms) {
    if (!Number.isFinite(ms)) return "Never";
    try { return new Date(ms).toLocaleString(); } catch (_) { return String(ms); }
  }
  function scopesFromForm() {
    const scopes = [];
    if ($("ollamaScopeModels").checked) scopes.push("models");
    if ($("ollamaScopeChat").checked) scopes.push("chat");
    if ($("ollamaScopeGenerate").checked) scopes.push("generate");
    return scopes;
  }
  function createBody() {
    const expiry = Number($("ollamaKeyExpiry").value || 0);
    return {
      label: $("ollamaKeyLabel").value.trim(),
      expires_in_days: expiry,
      scopes: scopesFromForm(),
    };
  }
  async function copyText(text, label = "Copied") {
    if (!text || !navigator.clipboard?.writeText) throw new Error("Clipboard is unavailable in this browser");
    await navigator.clipboard.writeText(text);
    api.toast(label);
  }
  function setSnippet(id, value) { const node = $(id); if (node) node.textContent = value || "—"; }
  function renderConfig(value) {
    config = value || null;
    $("ollamaBaseUrl").textContent = value?.base_url || "—";
    $("ollamaDefaultModel").textContent = value?.default_model || "—";
    $("ollamaGatewayStatus").textContent = value ? (value.auth_required ? "AUTH REQUIRED" : "AUTH OPTIONAL") : "UNAVAILABLE";
    setSnippet("ollamaEnvSnippet", value?.environment);
    setSnippet("ollamaPythonSnippet", value?.python);
    setSnippet("ollamaJsSnippet", value?.javascript);
    setSnippet("ollamaCurlSnippet", value?.curl);
  }
  function clearSecret() {
    if (secretTimer) clearTimeout(secretTimer);
    secretTimer = null;
    issued = null;
    const panel = $("ollamaSecretPanel");
    if (panel) panel.hidden = true;
    if ($("ollamaSecretValue")) $("ollamaSecretValue").value = "";
  }
  function revealIssued(data) {
    issued = data;
    $("ollamaSecretValue").value = data.secret || "";
    $("ollamaSecretPanel").hidden = false;
    if (data.quick_config) renderConfig(data.quick_config);
    if (secretTimer) clearTimeout(secretTimer);
    secretTimer = setTimeout(clearSecret, 120000);
    $("ollamaSecretValue").focus();
    $("ollamaSecretValue").select();
  }
  function keyRow(key) {
    const row = document.createElement("article");
    row.className = "keys-row";
    const main = document.createElement("div"); main.className = "keys-row-main";
    const title = document.createElement("div"); title.className = "keys-row-title";
    const strong = document.createElement("strong"); strong.textContent = key.label || "Ollama key";
    const status = document.createElement("span"); status.className = `status-tag keys-status-${key.status || "unknown"}`; status.textContent = key.status || "unknown";
    title.append(strong, status);
    const hint = document.createElement("code"); hint.textContent = key.hint || key.id || "";
    const meta = document.createElement("div"); meta.className = "keys-row-meta";
    const items = [
      `Scopes: ${(key.scopes || []).join(", ") || "none"}`,
      `Created: ${fmtWhen(key.created_at_ms)}`,
      `Last used: ${fmtWhen(key.last_used_at_ms)}`,
      `Expires: ${fmtWhen(key.expires_at_ms)}`,
    ];
    for (const item of items) { const span = document.createElement("span"); span.textContent = item; meta.append(span); }
    main.append(title, hint, meta);
    const actions = document.createElement("div"); actions.className = "keys-actions";
    if (key.status === "active") {
      const rotate = document.createElement("button"); rotate.type = "button"; rotate.className = "button button-outline button-sm"; rotate.textContent = "Rotate";
      rotate.addEventListener("click", () => void rotateKey(key));
      const revoke = document.createElement("button"); revoke.type = "button"; revoke.className = "button button-outline button-sm danger-outline"; revoke.textContent = "Revoke";
      revoke.addEventListener("click", () => void revokeKey(key));
      actions.append(rotate, revoke);
    }
    row.append(main, actions);
    return row;
  }
  function renderKeys(keys) {
    const host = $("ollamaKeyList"); host.replaceChildren();
    const list = Array.isArray(keys) ? keys : [];
    $("ollamaKeyCount").textContent = `${list.length} key${list.length === 1 ? "" : "s"}`;
    if (!list.length) {
      const empty = document.createElement("div"); empty.className = "empty-state"; empty.textContent = "No Ollama API keys for this account."; host.append(empty); return;
    }
    for (const key of list) host.append(keyRow(key));
  }
  async function refresh() {
    if (!api?.currentToken?.()) {
      renderKeys([]); renderConfig(null); showNotice("Sign in with a managed account to manage Ollama API keys."); return;
    }
    showNotice("Loading keys and gateway configuration…");
    const [keysResult, cfgResult] = await Promise.all([
      api.request("/ecai/keys/ollama"),
      api.request("/ecai/keys/ollama/quick-config"),
    ]);
    renderKeys(keysResult?.data || []);
    renderConfig(cfgResult?.data || null);
    showNotice("Keys are scoped to this account. Revocation is effective on the next Ollama request.");
  }
  async function createKey(event) {
    event?.preventDefault?.();
    const body = createBody();
    if (!body.label) return showNotice("Enter a key name.", true);
    if (!body.scopes.length) return showNotice("Select at least one permission.", true);
    const result = await api.request("/ecai/keys/ollama", {method: "POST", body});
    revealIssued(result.data);
    api.toast("Ollama API key created. Copy the secret now.");
    await refresh();
  }
  async function quickCreate() {
    const body = createBody();
    if (!body.label) body.label = "Quick Ollama client";
    if (!body.scopes.length) return showNotice("Select at least one permission.", true);
    const result = await api.request("/ecai/keys/ollama/quick-config", {method: "POST", body});
    revealIssued(result.data);
    api.toast("Quick client configuration created.");
    await refresh();
  }
  async function rotateKey(key) {
    if (!confirm(`Rotate ${key.label}? The current key will stop working immediately.`)) return;
    const result = await api.request(`/ecai/keys/ollama/${encodeURIComponent(key.id)}/rotate`, {method: "POST", body: {}});
    revealIssued(result.data);
    api.toast("Key rotated. Update clients with the new secret.");
    await refresh();
  }
  async function revokeKey(key) {
    if (!confirm(`Revoke ${key.label}? Clients using it will be denied immediately.`)) return;
    await api.request(`/ecai/keys/ollama/${encodeURIComponent(key.id)}/revoke`, {method: "POST", body: {}});
    api.toast("Key revoked.");
    await refresh();
  }
  function bind() {
    $("ollamaKeyCreateForm")?.addEventListener("submit", (event) => { event.preventDefault(); void createKey(event).catch(handleError); });
    $("ollamaQuickCreate")?.addEventListener("click", () => void quickCreate().catch(handleError));
    $("ollamaKeysRefresh")?.addEventListener("click", () => void refresh().catch(handleError));
    $("ollamaSecretDismiss")?.addEventListener("click", clearSecret);
    $("ollamaSecretCopy")?.addEventListener("click", () => void copyText(issued?.secret, "API key copied").catch(handleError));
    $("ollamaSecretCopyEnv")?.addEventListener("click", () => void copyText(issued?.quick_config?.environment, "Environment setup copied").catch(handleError));
    $("ollamaSecretCopyPython")?.addEventListener("click", () => void copyText(issued?.quick_config?.python, "Python example copied").catch(handleError));
    $("ollamaSecretCopyJs")?.addEventListener("click", () => void copyText(issued?.quick_config?.javascript, "JavaScript example copied").catch(handleError));
    $("ollamaSecretCopyCurl")?.addEventListener("click", () => void copyText(issued?.quick_config?.curl, "curl example copied").catch(handleError));
    $("ollamaCopyEnv")?.addEventListener("click", () => void copyText(config?.environment, "Environment setup copied").catch(handleError));
    document.querySelector('[data-panel="keys"]')?.addEventListener("click", (event) => {
      const button = event.target.closest("[data-copy-id]");
      if (!button) return;
      const node = $(button.dataset.copyId);
      void copyText(node?.textContent || "").catch(handleError);
    });
  }
  function handleError(error) {
    const message = error?.body?.error || error?.message || "Ollama key operation failed";
    showNotice(String(message), true); api?.toast?.(String(message), true);
  }
  function clear() {
    clearSecret(); renderKeys([]); renderConfig(null); showNotice("Sign in with a managed account to manage Ollama API keys.");
  }
  function init(options) { api = options; bind(); }
  window.EcaiOllamaKeys = {init, refresh, clear};
})();
