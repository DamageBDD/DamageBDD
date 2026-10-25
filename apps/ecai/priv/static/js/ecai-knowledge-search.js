/* Incremental knowledge retrieval. The server remains the authority for ranking,
 * source access and completeness. No response or source is cached in storage. */
const text = (value) => typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
const compact = (value) => text(value).replace(/\s+/gu, " ").trim();
const clip = (value, max) => value.length > max ? `${value.slice(0, max - 1)}…` : value;

export function resultTitle(result) {
  const record = result?.record || {};
  return clip(compact(record.title || record.name || result?.preview) || "Knowledge record", 180);
}

export function resultExcerpt(result, query = "") {
  const record = result?.record || {};
  const raw = compact(record.description || record.text || record.opening_text || record.category || result?.preview);
  // Hide machine identifiers only in the preview, never in the retained source.
  const clean = raw.replace(/\b(?:(?:ak|ct|th|oq|ok)_[A-Za-z0-9]{20,}|Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]{30,}|[a-f0-9]{64})\b/gu, "…");
  const needle = compact(query).toLocaleLowerCase();
  const found = needle ? clean.toLocaleLowerCase().indexOf(needle) : -1;
  const start = found > 180 ? Math.max(0, clean.lastIndexOf(" ", found - 100)) : 0;
  return { snippet: `${start ? "… " : ""}${clip(clean.slice(start), 360)}`, identifiersHidden: clean !== raw };
}

// null means dynamic "all"; [] means none. Never coerce an empty list to all.
export function searchIndexSelectionBody(selection) {
  if (selection === null) return {};
  if (!Array.isArray(selection) || selection.length > 128 || selection.some((id) =>
    typeof id !== "string" || !id.length || new TextEncoder().encode(id).length > 128)) {
    throw new Error("Invalid index selection");
  }
  return { indexes: [...new Set(selection)].sort() };
}

export function normalizeIndexCatalog(data) {
  if (!Array.isArray(data?.indexes) || data.indexes.length > 1024) throw new Error("Invalid index catalog");
  const entries = new Map();
  for (const item of data.indexes) {
    searchIndexSelectionBody([item?.id]);
    if (entries.has(item.id)) throw new Error("Duplicate index ID in catalog");
    entries.set(item.id, { id: item.id, label: clip(compact(item.label) || item.id, 160),
      description: clip(compact(item.description), 240),
      kind: ["shared", "wikimedia", "disk", "funded"].includes(item.kind) ? item.kind : "other",
      scope: item.scope === "owner" ? "owner" : "public",
      state: ["ready", "not_ready", "unavailable", "limited", "timeout"].includes(item.state) ? item.state : "unknown" });
  }
  return [...entries.values()];
}

export function initKnowledgeIndexSelection({ root, request, authEpoch, isActive, onChange, showError, timeoutMs, ids = {} }) {
  const $ = (id) => root.getElementById(ids[id] || id);
  const panel = $("searchIndexes"), choices = $("searchIndexChoices"), caption = $("searchIndexSummary");
  const message = $("searchIndexStatus"), all = $("searchIndexAll"), none = $("searchIndexNone"), refresh = $("searchIndexRefresh");
  let selection = null, entries = [], attempted = false, loaded = false, pending = null, generation = 0, disposed = false, locked = false;
  const listeners = [], rows = new Map();
  const listen = (target, type, fn) => { if (target) { target.addEventListener(type, fn); listeners.push(() => target.removeEventListener(type, fn)); } };
  const el = (tag, cls, value) => {
    const node = root.createElement(tag); if (cls) node.className = cls;
    if (value !== undefined) node.textContent = value;
    return node;
  };
  const statusText = (state) => ({ready: "Ready", not_ready: "Not ready", unavailable: "Unavailable",
    limited: "Limited", timeout: "Timed out", unknown: "Not checked", removed: "No longer listed"})[state] || "Not checked";
  function summarize() {
    if (caption) caption.textContent = selection === null ? "All indexes" : `${selection.length} selected`;
    if (all) all.setAttribute("aria-pressed", String(selection === null));
    if (none) none.setAttribute("aria-pressed", String(selection?.length === 0));
    for (const [id, {input, row}] of rows) {
      input.checked = selection === null || selection.includes(id);
      input.disabled = locked;
      row.classList.toggle("is-selected", input.checked);
    }
  }
  function choose(next) {
    if (locked) { summarize(); return; }
    try { searchIndexSelectionBody(next); }
    catch (error) { if (message) message.textContent = "Select at most 128 indexes, or use All indexes."; summarize(); return; }
    selection = next === null ? null : [...new Set(next)].sort();
    summarize(); onChange();
  }
  function render() {
    if (!choices) return;
    rows.clear();
    const shown = entries.slice(), available = new Set(shown.map((entry) => entry.id));
    // Keep a disappeared selection explicit until the user changes it. Never
    // broaden a selection, or choose every other index after a refresh failure.
    for (const id of selection || []) if (!available.has(id)) shown.push({id, label: id,
      kind: "other", description: "No longer in this catalog. Uncheck it or refresh the list.", state: "removed", scope: "owner"});
    const fragment = root.createDocumentFragment();
    for (const [kind, label] of [["shared", "Shared live"], ["wikimedia", "Wikimedia"], ["disk", "Published disk"], ["funded", "Your funded indexes"], ["other", "Other / previously selected"]]) {
      const group = shown.filter((entry) => entry.kind === kind);
      if (!group.length) continue;
      const fieldset = el("fieldset", "knowledge-index-group"); fieldset.append(el("legend", "", label));
      for (const entry of group) {
        const row = el("label", "knowledge-index-choice");
        const input = el("input"); input.type = "checkbox"; input.value = entry.id;
        input.setAttribute("aria-label", `Search ${entry.label}`);
        const copy = el("span", "knowledge-index-copy"), name = el("strong", "", entry.label);
        const subtitle = [entry.description, entry.scope === "owner" ? "Only your account" : "Public"].filter(Boolean).join(" · ");
        copy.append(name, el("span", "knowledge-index-description", subtitle), el("code", "knowledge-index-id", entry.id));
        const state = el("span", "knowledge-index-state", statusText(entry.state)); state.dataset.state = entry.state;
        row.append(input, copy, state); fieldset.append(row); rows.set(entry.id, {input, row, state});
        input.addEventListener("change", () => {
          const selected = new Set(selection === null ? entries.map((item) => item.id) : selection);
          if (input.checked) selected.add(entry.id); else selected.delete(entry.id);
          choose([...selected]);
        });
      }
      fragment.append(fieldset);
    }
    if (!shown.length) fragment.append(el("p", "context-hint", loaded ? "No indexes are listed for this session." : "Expand this panel to load the index list."));
    choices.replaceChildren(fragment); summarize();
  }
  function stop() { generation++; pending?.abort(); pending = null; if (refresh) refresh.disabled = locked; choices?.setAttribute("aria-busy", "false"); }
  async function load(force = false) {
    if (!panel || !choices || disposed || locked || !isActive() || (attempted && !force)) return;
    stop(); attempted = true;
    const seq = generation, epoch = authEpoch(), controller = new AbortController(); pending = controller;
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
    if (message) message.textContent = "Loading indexes visible to this session…";
    if (refresh) refresh.disabled = true;
    choices.setAttribute("aria-busy", "true");
    try {
      const data = await request("/ecai/knowledge/indexes", { method: "GET", signal: controller.signal });
      if (seq !== generation || epoch !== authEpoch() || disposed) return;
      if (controller.signal.aborted) throw new DOMException("Catalog aborted", "AbortError");
      if (data?.ok === false) throw new Error("Index catalog unavailable");
      entries = normalizeIndexCatalog(data); loaded = true; render();
      if (message) message.textContent = data.partial
        ? "Public indexes loaded, but your funded index list is unavailable. Your selection has not changed; refresh to retry."
        : `${entries.length} indexes listed. Availability is checked again when searching. All indexes also includes indexes added later.`;
    } catch (error) {
      if (seq !== generation || epoch !== authEpoch() || disposed) return;
      if (error.name !== "AbortError" || timedOut) {
        if (message) message.textContent = `${timedOut ? "Index list timed out." : `Could not load index list: ${showError(error)}`} Your selection has not changed. Refresh to retry.`;
      }
    } finally {
      clearTimeout(timer);
      if (seq === generation) { pending = null; if (refresh) refresh.disabled = locked; choices.setAttribute("aria-busy", "false"); }
    }
  }
  listen(panel, "toggle", () => { if (panel.open) void load(); });
  listen(refresh, "click", () => void load(true));
  listen(all, "click", () => choose(null));
  listen(none, "click", () => choose([]));
  render();
  return {
    key: () => JSON.stringify(selection), body: () => searchIndexSelectionBody(selection),
    isEmpty: () => selection?.length === 0,
    label: () => selection === null ? "all indexes" : `${selection.length} selected index${selection.length === 1 ? "" : "es"}`,
    ensure: () => { void load(); },
    accepts(data) {
      // Mixed frontend/backend deployments must not silently ignore a filter.
      return selection === null || (data?.selection?.mode === "selected" &&
        Array.isArray(data.selection.indexes) && JSON.stringify([...data.selection.indexes].sort()) === JSON.stringify(selection));
    },
    lock(on) {
      locked = Boolean(on);
      if (all) all.disabled = locked;
      if (none) none.disabled = locked;
      if (refresh) refresh.disabled = locked || Boolean(pending);
      summarize();
    },
    observe(states) {
      for (const item of Array.isArray(states) ? states : []) {
        const row = rows.get(item.id); if (!row) continue;
        row.state.textContent = statusText(item.state); row.state.dataset.state = item.state;
      }
    },
    reset() { stop(); selection = null; entries = []; attempted = false; loaded = false; render();
      if (message) message.textContent = "Index selection reset for this session.";
      queueMicrotask(() => { if (isActive() && panel?.open) void load(); }); },
    suspend() { if (pending) { stop(); attempted = false; } },
    dispose() { disposed = true; stop(); for (const remove of listeners) remove(); }
  };
}

export function initKnowledgeSearch({ request, showError = (e) => e.message || "Request failed", authEpoch = () => 0,
  root = document, debounceMs = 300, refreshMs = 3000, timeoutMs = 30000 } = {}) {
  const $ = (id) => root.getElementById(id);
  const form = $("searchForm"), query = $("searchQuery"), limit = $("searchLimit");
  const results = $("searchResults"), status = $("searchStatus"), proofs = $("searchProofs");
  const warning = $("searchWarning"), live = $("searchLiveRefresh"), clear = $("searchClear");
  const panel = form?.closest('[data-panel="search"]');
  if (!form || !query || !results || typeof request !== "function") throw new Error("Knowledge search is not mounted");
  let sequence = 0, debounceTimer = null, refreshTimer = null, controller = null;
  let composing = false, visible = !panel?.hidden, disposed = false, renderedKey = "", renderedQuery = "", hasLive = false;
  const sourceRequests = new Set(), listeners = [];
  const listen = (target, type, fn) => { if (target) { target.addEventListener(type, fn); listeners.push(() => target.removeEventListener(type, fn)); } };
  const el = (tag, cls, value) => {
    const node = root.createElement(tag); if (cls) node.className = cls;
    if (value !== undefined) node.textContent = value;
    return node;
  };
  const active = () => visible && !panel?.hidden && root.visibilityState !== "hidden" && !disposed;
  const count = () => Math.min(100, Math.max(1, Math.trunc(Number(limit?.value) || 10)));
  const currentKey = () => JSON.stringify([query.value.trim(), count(), authEpoch(), indexChooser.key()]);
  const indexChooser = initKnowledgeIndexSelection({root, request, authEpoch, isActive: active,
    onChange: indexesChanged, showError, timeoutMs});
  const setStatus = (value) => { if (status) status.textContent = value; };
  const stopPolling = () => { clearTimeout(refreshTimer); refreshTimer = null; };
  const busy = (on) => {
    results.setAttribute("aria-busy", String(on));
    form.classList.toggle("is-searching", on);
    if (clear) clear.hidden = !query.value;
  };
  const lockOldResults = () => results.querySelectorAll("button").forEach((button) => { button.disabled = true; });
  function cancel() {
    sequence++;
    clearTimeout(debounceTimer); debounceTimer = null;
    stopPolling(); controller?.abort(); controller = null;
    for (const pending of sourceRequests) pending.abort();
    sourceRequests.clear(); busy(false);
  }
  function empty(message = "Start typing a name, term, category or location.") {
    results.replaceChildren(el("div", "empty-state", message));
    renderedKey = ""; renderedQuery = ""; hasLive = false;
    if (warning) { warning.hidden = true; warning.textContent = ""; }
    if (proofs) proofs.textContent = "Run a search to inspect backend availability. Live previews are not final artifact proofs.";
  }
  function highlight(node, value, term) {
    // Literal matching and text nodes: source text can never become HTML.
    const words = [...new Set(compact(term).split(/\s+/u).filter(Boolean))].slice(0, 12).sort((a, b) => b.length - a.length);
    if (!words.length) { node.textContent = value; return; }
    const escaped = words.map((word) => word.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"));
    const pattern = new RegExp(escaped.join("|"), "giu");
    let offset = 0;
    for (const match of value.matchAll(pattern)) {
      node.append(root.createTextNode(value.slice(offset, match.index)), el("mark", "", match[0]));
      offset = match.index + match[0].length;
    }
    node.append(root.createTextNode(value.slice(offset)));
  }
  function scheduleRefresh() {
    stopPolling();
    if (!active() || !live?.checked || !hasLive || controller || composing || renderedKey !== currentKey()) return;
    // Do not replace a source/technical-details view while someone is reading it.
    if (results.querySelector("details[open]") || sourceRequests.size) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; void run(); }, refreshMs);
  }
  function detailRow(list, name, value) {
    if (value === undefined || value === null || value === "") return;
    list.append(el("dt", "", name), el("dd", "", String(value)));
  }
  function renderCard(result, term, key, epoch) {
    const card = el("article", "result-card knowledge-result");
    const heading = el("h2", "knowledge-result-title");
    const title = el(result.source_ref ? "button" : "span", result.source_ref ? "knowledge-title-action" : "");
    if (result.source_ref) title.type = "button";
    highlight(title, resultTitle(result), term); heading.append(title);
    const meta = el("div", "result-meta");
    meta.append(el("span", "knowledge-source-kind", result.live ? "Live build" : "Published snapshot"));
    if (result.index) meta.append(el("span", "", clip(text(result.index), 100)));
    if (result.record?.city) meta.append(el("span", "", text(result.record.city)));
    const preview = resultExcerpt(result, term);
    const snippet = el("p", "knowledge-result-snippet");
    highlight(snippet, preview.snippet || "No preview retained. Open the source for its available representation.", term);
    const completeness = result.record?.source_retrieval?.complete === true;
    const hint = el("p", "knowledge-result-hint", `${completeness ? "Complete retained representation available" : "Preview · source completeness unknown"}${preview.identifiersHidden ? " · identifiers in technical details" : ""}`);
    const actions = el("div", "knowledge-result-actions");
    const technical = el("details", "knowledge-technical");
    technical.append(el("summary", "", "Technical details"));
    const fields = el("dl", "knowledge-metadata");
    detailRow(fields, "Document ID", result.doc_id);
    detailRow(fields, "Score", Number.isFinite(result.score) ? result.score.toFixed(3) : undefined);
    detailRow(fields, "Index", result.index);
    detailRow(fields, "State", result.live ? "Live / partial build" : "Published snapshot");
    // Keep the original excerpt available, including identifiers omitted above.
    if (preview.identifiersHidden) detailRow(fields, "Original preview", compact(result.record?.description || result.record?.text || result.preview));
    technical.append(fields);
    technical.addEventListener("toggle", scheduleRefresh);
    card.append(meta, heading, snippet, hint, actions, technical);
    if (result.source_ref) {
      const resolve = el("button", "button button-outline button-sm", "Retrieve source"); resolve.type = "button";
      const sourceStatus = el("span", "knowledge-source-status"); sourceStatus.setAttribute("role", "status");
      actions.append(resolve, sourceStatus);
      let openedSource = null, pending = false;
      const retrieve = async () => {
        if (pending || key !== currentKey() || epoch !== authEpoch()) return;
        if (openedSource) { openedSource.open = true; openedSource.scrollIntoView?.({block: "nearest"}); return; }
        stopPolling(); pending = true; resolve.disabled = true; title.disabled = true;
        sourceStatus.textContent = "Retrieving retained source…";
        sourceStatus.classList.remove("is-error");
        const sourceController = new AbortController(); sourceRequests.add(sourceController);
        let timedOut = false;
        const timer = setTimeout(() => { timedOut = true; sourceController.abort(); }, timeoutMs);
        try {
          const source = await request("/ecai/knowledge/source", {
            method: "POST", body: { source_ref: result.source_ref }, signal: sourceController.signal
          });
          if (sourceController.signal.aborted || epoch !== authEpoch() || key !== currentKey() || !card.isConnected) return;
          if (source?.ok === false || source?.status === "error") throw new Error(text(source.message) || JSON.stringify(source.error || "Retrieval failed"));
          openedSource = el("details", "knowledge-source"); openedSource.open = true;
          openedSource.append(el("summary", "", `${source.complete === true ? "Complete" : "Partial"} retained source · ${text(source.representation) || "stored text"} · ${text(source.integrity) || "unverified"}`));
          const sourceText = text(source.text);
          openedSource.append(el("pre", "code-display", sourceText.slice(0, 64000)));
          if (sourceText.length > 64000) openedSource.append(el("p", "context-hint", "The endpoint returned the full source; this viewer shows the first 64,000 characters."));
          card.append(openedSource); openedSource.addEventListener("toggle", scheduleRefresh);
          sourceStatus.textContent = "Source loaded"; resolve.textContent = "Open source";
        } catch (error) {
          if (epoch !== authEpoch() || key !== currentKey() || !card.isConnected) return;
          if (error.name !== "AbortError" || timedOut) {
            sourceStatus.textContent = timedOut ? "Source request timed out. Try again." : `Retrieval failed: ${showError(error)}`;
            sourceStatus.classList.add("is-error");
          }
        } finally {
          clearTimeout(timer); sourceRequests.delete(sourceController); pending = false;
          resolve.disabled = title.disabled = key !== currentKey() || epoch !== authEpoch();
          scheduleRefresh();
        }
      };
      // These nodes are owned by the result tree and are collected on replacement.
      resolve.addEventListener("click", () => void retrieve());
      title.addEventListener("click", () => void retrieve());
    }
    return card;
  }
  async function run(event) {
    event?.preventDefault();
    if (composing || !active()) return;
    const term = query.value.trim();
    cancel(); indexChooser.ensure();
    if (indexChooser.isEmpty()) { empty("Select at least one index in Search indexes."); setStatus("No indexes selected. Search is paused."); return; }
    if (!term) { empty(); setStatus("Search as you type. Enter searches immediately."); return; }
    if (term.length > 2048) { setStatus("Use a query of at most 2,048 characters."); return; }
    const epoch = authEpoch(), key = currentKey(), seq = sequence;
    const pending = new AbortController(); controller = pending;
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; pending.abort(); }, timeoutMs);
    const started = performance.now();
    busy(true); lockOldResults();
    setStatus(`Searching for “${clip(term, 80)}”…${renderedQuery && renderedQuery !== term ? ` Showing previous results for “${clip(renderedQuery, 60)}” until it finishes.` : ""}`);
    if (warning) warning.hidden = true;
    try {
      const data = await request("/ecai/knowledge/search", { method: "POST", body: { q: term, limit: count(), ...indexChooser.body() }, signal: pending.signal });
      if (seq !== sequence || epoch !== authEpoch() || key !== currentKey() || !active()) return;
      if (pending.signal.aborted) throw new DOMException("Search aborted", "AbortError");
      if (data?.ok === false || data?.status === "error") throw new Error(text(data.message) || JSON.stringify(data.error || "Search failed"));
      if (!indexChooser.accepts(data)) throw new Error("The server did not confirm the selected indexes. Update the search backend before filtering.");
      indexChooser.observe(data.backends);
      const items = (Array.isArray(data.results) ? data.results : []).filter((r) => r && typeof r === "object").slice(0, count());
      results.replaceChildren(...items.map((result) => renderCard(result, term, key, epoch)));
      if (!items.length) results.append(el("div", "empty-state", data.partial ? "No matches from the available backends. Other sources could not be searched." : "No matching records. Try a broader term or index a sample."));
      renderedKey = key; renderedQuery = term; hasLive = items.some((result) => result.live === true);
      setStatus(`${items.length} result${items.length === 1 ? "" : "s"} for “${clip(term, 80)}” · ${((performance.now() - started) / 1000).toFixed(2)} s · ${indexChooser.label()}`);
      if (warning) {
        warning.hidden = !data.partial;
        const states = Array.isArray(data.backends) ? data.backends : [];
        const limitedOnly = states.some((item) => item.state === "limited") && states.every((item) => ["ready", "limited"].includes(item.state));
        warning.textContent = data.partial ? (limitedOnly
          ? "Search limits were reached in selected indexes. Results may be incomplete; expand Retrieval status for details."
          : "Some selected indexes are unavailable or could not be fully searched. Results may be incomplete; expand Retrieval status for details.") : "";
      }
      if (proofs) proofs.textContent = JSON.stringify({ ranking: data.ranking, consistency: data.consistency, selection: data.selection, backends: data.backends,
        note: "Live previews omit Merkle proofs. Use a finalized artifact for release verification." }, null, 2);
    } catch (error) {
      if (seq !== sequence || epoch !== authEpoch() || key !== currentKey() || !active()) return;
      if (error.name === "AbortError" && !timedOut) return;
      hasLive = false; // No automatic error/retry storm while a backend is down.
      if (error.body?.error === "invalid_index_selection") {
        empty("One or more selected indexes are no longer accessible. Refresh Search indexes and update your selection.");
      }
      setStatus(`${timedOut ? "Search timed out. Try again." : `Search failed: ${showError(error)}`}${renderedQuery ? ` Previous results for “${clip(renderedQuery, 60)}” are still shown.` : ""}`);
      if (renderedKey === key) results.querySelectorAll("button").forEach((button) => { button.disabled = false; });
    } finally {
      clearTimeout(timer);
      if (seq === sequence) { controller = null; busy(false); scheduleRefresh(); }
    }
  }
  function indexesChanged() {
    cancel(); empty(); // No results or source text from the previous scope remain visible.
    if (indexChooser.isEmpty()) { empty("Select at least one index in Search indexes."); setStatus("No indexes selected. Search is paused."); return; }
    if (query.value.trim()) void run();
    else setStatus(`Search scope: ${indexChooser.label()}. Start typing to search.`);
  }
  function queueSearch() {
    cancel(); lockOldResults();
    if (indexChooser.isEmpty()) { empty("Select at least one index in Search indexes."); setStatus("No indexes selected. Search is paused."); return; }
    if (!query.value.trim()) { empty(); setStatus("Search as you type. Enter searches immediately."); return; }
    if (composing || !active()) return;
    setStatus(`Waiting for typing to pause…${renderedQuery ? ` Previous results: “${clip(renderedQuery, 60)}”.` : ""}`);
    debounceTimer = setTimeout(() => { debounceTimer = null; void run(); }, debounceMs);
  }
  function reset() {
    cancel(); query.value = ""; busy(false); empty(); indexChooser.reset();
    setStatus("Identity changed. Start a new search.");
  }
  listen(form, "submit", (event) => void run(event));
  listen(query, "input", queueSearch);
  listen(query, "compositionstart", () => { composing = true; cancel(); });
  listen(query, "compositionend", () => { composing = false; queueSearch(); });
  listen(limit, "input", queueSearch);
  listen(live, "change", scheduleRefresh);
  listen(clear, "click", () => { query.value = ""; queueSearch(); query.focus(); });
  listen(root, "ecai:identity-changed", reset);
  listen(root, "visibilitychange", () => { if (!active()) { cancel(); indexChooser.suspend(); } else { indexChooser.ensure(); if (query.value.trim()) queueSearch(); } });
  if (active()) indexChooser.ensure();
  return {
    run, reset,
    setQuery(value) { query.value = text(value).slice(0, 2048); query.focus(); return run(); },
    setVisible(on) { visible = Boolean(on); if (!visible) { cancel(); indexChooser.suspend(); } else { indexChooser.ensure(); scheduleRefresh(); } },
    dispose() { disposed = true; cancel(); indexChooser.dispose(); for (const remove of listeners) remove(); }
  };
}
