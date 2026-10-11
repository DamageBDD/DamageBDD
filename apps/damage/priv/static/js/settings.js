// Dashboard settings and node-context controls.
(() => {
  const root = document.getElementById("node-context-settings");
  if (!root || root.dataset.bound === "true") return;
  root.dataset.bound = "true";

  const endpoint = "/node/context";
  const redacted = "XX-REDACTED-XX";

  const rows = document.getElementById("node-context-rows");
  const versionEl = document.getElementById("node-context-version");
  const rootEl = document.getElementById("node-context-root");
  const statusEl = document.getElementById("node-context-status");
  const editor = document.getElementById("node-context-editor");
  const nameEl = document.getElementById("node-context-name");
  const valueEl = document.getElementById("node-context-value");
  const typeEl = document.getElementById("node-context-type");
  const sensitiveEl = document.getElementById("node-context-sensitive");
  const exposureEl = document.getElementById("node-context-exposure");
  const inheritanceEl = document.getElementById("node-context-inheritance");

  let currentVersion = null;
  let currentEntries = {};

  function setStatus(message, kind) {
    statusEl.textContent = message || "";
    statusEl.className = "workspace-status";
    if (kind) statusEl.dataset.tone = kind;
    else delete statusEl.dataset.tone;
  }

  async function request(url, options = {}) {
    const headers = new Headers(options.headers || {});
    headers.set("Accept", "application/json");
    if (options.body) headers.set("Content-Type", "application/json");

    const token = window.TokenManager?.getToken?.();
    if (token) headers.set("Authorization", `Bearer ${token}`);

    const response = await fetch(url, {
      credentials: "include",
      cache: "no-store",
      ...options,
      headers
    });

    let body = {};
    const text = await response.text();
    if (text) {
      try {
        body = JSON.parse(text);
      } catch (_) {
        body = {message: text};
      }
    }

    if (!response.ok) {
      const message =
        body.message ||
        body.error ||
        `Node context request failed (${response.status})`;
      const error = new Error(
        typeof message === "string" ? message : JSON.stringify(message)
      );
      error.status = response.status;
      error.body = body;
      throw error;
    }

    return body;
  }

  function displayValue(entry) {
    if (!entry) return "";
    if (entry.sensitive === true || entry.value === redacted) return redacted;
    if (typeof entry.value === "string") return entry.value;
    return JSON.stringify(entry.value);
  }

  function addCell(row, value, useCode = false) {
    const td = document.createElement("td");
    if (useCode) {
      const code = document.createElement("code");
      code.textContent = value == null ? "" : String(value);
      td.appendChild(code);
    } else {
      td.textContent = value == null ? "" : String(value);
    }
    row.appendChild(td);
    return td;
  }

  function renderEntries() {
    rows.replaceChildren();
    const names = Object.keys(currentEntries).sort();

    if (names.length === 0) {
      const row = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = 7;
      td.textContent = "No node context variables configured.";
      row.appendChild(td);
      rows.appendChild(row);
      return;
    }

    for (const name of names) {
      const entry = currentEntries[name] || {};
      const row = document.createElement("tr");

      addCell(row, name, true);
      addCell(row, displayValue(entry), true);
      addCell(row, entry.sensitive === true ? "yes" : "no");
      addCell(row, entry.exposure || "");
      addCell(row, entry.inheritance || "");
      addCell(row, entry.locked === true ? "yes" : "no");

      const actions = document.createElement("td");

      const edit = document.createElement("button");
      edit.type = "button";
      edit.className = "workspace-button";
      edit.textContent = "Edit";
      edit.addEventListener("click", () => editEntry(name, entry));
      actions.appendChild(edit);

      actions.appendChild(document.createTextNode(" "));

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "workspace-button workspace-danger";
      remove.textContent = "Delete";
      remove.addEventListener("click", () => deleteEntry(name));
      actions.appendChild(remove);

      row.appendChild(actions);
      rows.appendChild(row);
    }
  }

  async function loadContext() {
    setStatus("Loading node context…");
    try {
      const data = await request(endpoint);
      currentVersion = Number.isInteger(data.version) ? data.version : null;
      currentEntries = data.entries && typeof data.entries === "object"
        ? data.entries
        : {};

      versionEl.textContent =
        currentVersion === null ? "—" : String(currentVersion);
      rootEl.textContent = data.root || "—";
      renderEntries();
      setStatus("");
    } catch (error) {
      rows.replaceChildren();
      const row = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = 7;
      td.textContent = "Unable to load node context.";
      row.appendChild(td);
      rows.appendChild(row);
      setStatus(error.message, "error");
    }
  }

  function inferType(value) {
    if (typeof value === "boolean") return "boolean";
    if (Number.isInteger(value)) return "integer";
    if (typeof value === "number") return "float";
    if (value !== null && typeof value === "object") return "json";
    return "string";
  }

  function editEntry(name, entry) {
    nameEl.value = name;
    nameEl.readOnly = true;
    sensitiveEl.checked = entry.sensitive === true;
    exposureEl.value = entry.exposure || "template";
    inheritanceEl.value = entry.inheritance || "default";

    if (entry.value === redacted || entry.sensitive === true) {
      valueEl.value = "";
      valueEl.placeholder = "Enter a replacement value for this sensitive setting";
      typeEl.value = "string";
    } else {
      const value = entry.value;
      typeEl.value = inferType(value);
      valueEl.value =
        typeEl.value === "json" ? JSON.stringify(value, null, 2) : String(value ?? "");
      valueEl.placeholder = "";
    }

    valueEl.focus();
  }

  function clearEditor() {
    editor.reset();
    nameEl.readOnly = false;
    valueEl.placeholder = "https://api.example.com";
  }

  function typedValue() {
    const raw = valueEl.value;
    switch (typeEl.value) {
      case "integer": {
        if (!/^-?\d+$/.test(raw.trim())) throw new Error("Value must be an integer.");
        return Number.parseInt(raw, 10);
      }
      case "float": {
        const value = Number(raw);
        if (!Number.isFinite(value)) throw new Error("Value must be a number.");
        return value;
      }
      case "boolean":
        if (raw.trim().toLowerCase() === "true") return true;
        if (raw.trim().toLowerCase() === "false") return false;
        throw new Error('Boolean value must be "true" or "false".');
      case "json":
        return JSON.parse(raw);
      default:
        return raw;
    }
  }

  async function saveEntry(event) {
    event.preventDefault();
    const name = nameEl.value.trim();
    if (!name) {
      setStatus("Name is required.", "error");
      return;
    }

    let value;
    try {
      value = typedValue();
    } catch (error) {
      setStatus(error.message, "error");
      return;
    }

    const spec = {
      value,
      sensitive: sensitiveEl.checked,
      exposure: exposureEl.value,
      inheritance: inheritanceEl.value
    };

    const payload = {
      set: {[name]: spec},
      delete: []
    };
    if (currentVersion !== null) payload.expected_version = currentVersion;

    setStatus(`Saving ${name}…`);
    try {
      await request(endpoint, {
        method: "PATCH",
        body: JSON.stringify(payload)
      });
      clearEditor();
      setStatus(`${name} saved.`, "success");
      await loadContext();
    } catch (error) {
      if (error.status === 409) {
        setStatus("Node context changed elsewhere. Reloading latest version…", "error");
        await loadContext();
      } else {
        setStatus(error.message, "error");
      }
    }
  }

  async function deleteEntry(name) {
    if (!window.confirm(`Delete node context "${name}"?`)) return;

    const payload = {
      set: {},
      delete: [name]
    };
    if (currentVersion !== null) payload.expected_version = currentVersion;

    setStatus(`Deleting ${name}…`);
    try {
      await request(endpoint, {
        method: "PATCH",
        body: JSON.stringify(payload)
      });
      if (nameEl.value === name) clearEditor();
      setStatus(`${name} deleted.`, "success");
      await loadContext();
    } catch (error) {
      if (error.status === 409) {
        setStatus("Node context changed elsewhere. Reloading latest version…", "error");
        await loadContext();
      } else {
        setStatus(error.message, "error");
      }
    }
  }

  editor.addEventListener("submit", saveEntry);
  document.getElementById("node-context-refresh").addEventListener("click", loadContext);
  document.getElementById("node-context-cancel").addEventListener("click", clearEditor);

  loadContext();
})();
