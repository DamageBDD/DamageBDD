/* Admin-funded indexing pool. Uses the console's authenticated request helper.
 * No keys, tokens, channel actions or paid-work receipts are accepted from HTML.
 */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const root = "/ecai/admin/index-pool";
  const state = {api: null, authenticated: false, admin: false, visible: false, data: null,
    nodes: new Set(), quote: null, quoteKey: "", idempotency: "", epoch: 0,
    timer: null, refreshBusy: false, mutationBusy: false, controller: null, jobs: new Map()};
  const node = (tag, cls = "", value = null) => {
    const el = document.createElement(tag); el.className = cls;
    if (value !== null) el.textContent = String(value); return el;
  };
  const fmt = (v) => Number.isFinite(v) ? v.toLocaleString(undefined, {maximumFractionDigits: 3}) : "—";
  const sats = (msat) => Number.isFinite(msat) ? fmt(msat / 1000) : "—";
  const title = (s) => String(s ?? "unknown").replace(/_/g, " ");
  const textError = (e) => {
    const r = e?.body?.error ?? e?.message ?? e;
    const known = {indexing_pool_disabled: "Enable index_pool_enabled and index_rewards_enabled, then restart ECAI.",
      bearer_required: "Sign in again to authorize changes with a DamageBDD bearer token.",
      node_not_operator_allowlisted: "Add the node to indexing_worker_nodes in the coordinator configuration first.",
      participation_not_enabled: "The peer has not opted in or has not allowed this coordinator.",
      refund_lightning_node_required: "Enter your external Lightning node ID under refund destination.",
      external_refund_wallet_required: "Use an external refund wallet, not the treasury's own Lightning node.",
      participant_identity_pinned: "This account already has a different pinned Lightning identity. Resolve its existing obligations before changing it.",
      budget_too_small_for_segments: "Increase the budget or prepare fewer segments; each paid role needs at least one satoshi.",
      independent_verifier_node_required: "Select at least two different peers for paid independent verification.",
      plan_already_contracted: "This plan already has a funded-job contract. Open the existing job below.",
      quote_changed: "The selection changed. Calculate and review a new split.",
      outstanding_work: "Work is still allocated or submitted. Funds remain reserved; finish or resolve those segments before refunding.",
      payments_disabled: "Outgoing payments are disabled in the node's reward configuration.",
      participant_unavailable: "The approved peer is unavailable. Check its private cluster connection and CLN service."};
    return known[r] || (typeof r === "string" ? r : JSON.stringify(r));
  };
  function notice(message, bad = false) { $("poolNotice").textContent = message; $("poolNotice").classList.toggle("is-error", bad); }
  function hasBearer() { return Boolean(state.api?.currentToken?.()); }
  function canMutate() { return state.authenticated && state.admin && state.data?.enabled && hasBearer() && !state.mutationBusy; }
  function selection(reveal = false) {
    const budget = Number($("poolBudget").value), fee = Number($("poolFee").value);
    if (!Number.isSafeInteger(budget) || budget < 1 || !Number.isSafeInteger(fee) || fee < 0) throw Error("Enter a whole-satoshi budget and fee cap.");
    if (!$("poolPlan").value) throw Error("Prepare or select a segment plan first.");
    if (!state.nodes.size) throw Error("Select at least one approved participant.");
    if (!/^(02|03)[0-9a-f]{64}$/.test($("poolRefundNode").value.trim())) {
      if (reveal) $("poolRefundNode").closest("details").open = true;
      throw Error("Set the creator’s external Lightning node for refunds under Verification, fees & refund destination.");
    }
    return {plan_id: $("poolPlan").value, budget_sats: budget, nodes: [...state.nodes].sort(),
      verifier_percent: Number($("poolVerify").value), fee_sats: fee, refund_node: $("poolRefundNode").value.trim()};
  }
  function selectionKey() { try { return JSON.stringify(selection()); } catch (_) { return ""; } }
  function invalidate() {
    state.quote = null; state.quoteKey = ""; state.idempotency = "";
    $("poolQuote").className = "pool-quote";
    $("poolQuote").textContent = "Calculate the split for this selection before funding.";
    updateButtons();
  }
  function updateButtons() {
    const permitted = canMutate();
    $("poolPreview").disabled = !permitted;
    $("poolJoin").disabled = !permitted || !$("poolAvailableNode").value;
    $("poolPrepare").disabled = !permitted || !$("poolSource").value;
    $("poolChannels").disabled = !permitted;
    $("poolCreate").disabled = !permitted || !state.quote || selectionKey() !== state.quoteKey;
  }
  async function post(path, body = {}, headers = {}) {
    if (!hasBearer()) { state.api.openLogin("Sign in to authorize funded indexing changes."); throw Error("Bearer sign-in required."); }
    const epoch = state.epoch;
    const result = await state.api.request(root + path, {method: "POST", body, headers});
    if (epoch !== state.epoch || !state.authenticated || !state.admin) throw Error("Session or view changed; reload to reconcile the accepted operation.");
    if (result.ok !== true) throw Error(textError(result));
    return result.data;
  }
  async function action(fn) {
    if (state.mutationBusy) return;
    state.mutationBusy = true; updateButtons();
    const epoch = state.epoch;
    try { await fn(); }
    catch (e) { if (epoch === state.epoch) notice(textError(e), true); }
    finally { state.mutationBusy = false; updateButtons(); }
  }
  function options(id, rows, placeholder) {
    const el = $(id), prior = el.value;
    el.replaceChildren();
    if (!rows.length) { const o = node("option", "", placeholder); o.value = ""; el.append(o); }
    for (const [value, label] of rows) { const o = node("option", "", label); o.value = value; el.append(o); }
    if (rows.some(([value]) => value === prior)) el.value = prior;
  }
  function line(host, label, value) { const row = node("div", "pool-quote-line"); row.append(node("span", "", label), node("strong", "", value)); host.append(row); }
  function renderQuote(q) {
    const host = $("poolQuote"); host.replaceChildren(); host.className = "pool-quote is-ready";
    const b = q.contract.budget;
    line(host, "Pinned segments", fmt(b.segments));
    line(host, "Indexing rewards", `${fmt(b.indexing_sats)} sats`);
    line(host, "Independent verification", `${fmt(b.verification_sats)} sats`);
    line(host, "Routing-fee reserve", `${fmt(b.fee_reserve_sats)} sats`);
    line(host, "Total maximum", `${fmt(b.total_sats)} sats`);
    host.append(node("p", "context-hint", `Indexer reward: ${fmt(b.minimum_index_reward_sats)}–${fmt(b.maximum_index_reward_sats)} sats per segment. Weighted by pinned source bytes, not by claimed run time. Unused routing fees remain in the job balance.`));
    const totals = new Map();
    for (const [id, assignment] of Object.entries(q.contract.assignments)) {
      const price = b.unit_prices[id];
      for (const [member, amount] of [[assignment.indexer, price.index_msat], [assignment.verifier, price.verify_msat]]) {
        if (amount > 0) totals.set(member.node_name, (totals.get(member.node_name) || 0) + amount);
      }
    }
    const projected = node("details", "pool-advanced"); projected.append(node("summary", "", "Projected participant earnings"));
    for (const [name, amount] of [...totals.entries()].sort()) line(projected, name, `${sats(amount)} sats`);
    projected.append(node("p", "context-hint", "Conditional on accepted work and settlement; fees are not worker income.")); host.append(projected);
  }
  function channelsFor(p) { return (state.data?.channels?.channels || []).filter(c => c.peer_id === p.lightning_node); }
  function renderNodes(data) {
    options("poolAvailableNode", (data.available_nodes || []).map(n => [n, n]), "Configure an approved worker node first");
    const choices = $("poolNodeChoices"), list = $("poolNodes"); choices.replaceChildren(); list.replaceChildren();
    const peers = data.peers || [];
    for (const id of state.nodes) if (!peers.some(p => p.node_name === id && p.enabled)) state.nodes.delete(id);
    for (const p of peers) {
      const label = node("label", "pool-check"), cb = node("input"); cb.type = "checkbox";
      cb.checked = state.nodes.has(p.node_name); cb.disabled = !p.enabled;
      cb.addEventListener("change", () => { cb.checked ? state.nodes.add(p.node_name) : state.nodes.delete(p.node_name); invalidate(); });
      label.append(cb, node("span", "", p.node_name)); choices.append(label);
      const row = node("article", "pool-node"), head = node("div", "pool-node-head");
      head.append(node("strong", "", p.node_name), node("span", "code-validation-label verified", "Lightning identity verified"));
      row.append(head, node("span", "mono", p.lightning_node));
      const channels = channelsFor(p), active = channels.filter(c => c.state === "CHANNELD_NORMAL" && c.connected === true);
      let channelText = !data.channels?.observed_at ? "Channel status not checked" : !channels.length ? "No direct channel observed · routed payment may still work" :
        `${active.length}/${channels.length} direct channels ready · ${sats(active.reduce((v,c) => v + (c.spendable_msat || 0), 0))} sats estimated send capacity`;
      row.append(node("p", "", channelText));
      if (channels.length) {
        const details = node("details", "pool-advanced"); details.append(node("summary", "", "Channel observations"));
        for (const c of channels) details.append(node("p", "pool-hash", `${c.channel_id || c.short_channel_id || "Unassigned channel"} · ${c.state || "unknown"} · ${c.connected ? "connected" : "disconnected"}`));
        row.append(details);
      }
      list.append(row);
    }
    if (!peers.length) { choices.append(node("p", "context-hint", "Add an approved node to continue.")); list.append(node("div", "empty-state", "No participants registered.")); }
    const at = data.channels?.observed_at;
    $("poolChannelAge").textContent = at ? `Observed ${new Date(at * 1000).toLocaleTimeString()}. Capacity is advisory, not reserved for this job.` : "Channel capacity has not been checked. Routed payments do not require a direct channel.";
  }
  function renderMetrics(data) {
    const jobs = data.jobs || [], host = $("poolMetrics"); host.replaceChildren();
    const funded = jobs.reduce((n,j) => n + (j.accounting?.funded_msat || 0), 0);
    const held = jobs.reduce((n,j) => n + (j.accounting?.reserved_msat || 0), 0);
    const spent = jobs.reduce((n,j) => n + (j.accounting?.spent_msat || 0), 0);
    const verified = jobs.reduce((n,j) => n + Object.values(j.results || {}).filter(r => r.phase === "accepted").length, 0);
    for (const [label, value] of [["Funded", `${sats(funded)} sats`], ["Reserved for work & fees", `${sats(held)} sats`], ["Paid, including fees", `${sats(spent)} sats`], ["Verified segments", fmt(verified)]]) {
      const card = node("article", "pool-metric"); card.append(node("span", "", label), node("strong", "", value)); host.append(card);
    }
  }
  function button(label, fn, primary = false, enabled = true) {
    const b = node("button", `button ${primary ? "button-primary" : "button-outline"} button-sm`, label); b.type = "button";
    b.disabled = !enabled; b.addEventListener("click", () => action(fn)); return b;
  }
  async function exportContract(j) {
    const response = await state.api.request(`${root}/jobs/${encodeURIComponent(j.id)}/contract`);
    const blob = new Blob([JSON.stringify(response.data, null, 2)], {type: "application/json"});
    const url = URL.createObjectURL(blob), link = node("a"); link.href = url; link.download = `ecai-index-contract-${j.id.slice(0,12)}.json`;
    document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function renderJobDetail(entry, j) {
    const content = entry.content; content.replaceChildren();
    const c = j.accounting || {}, funded = c.state === "funded", owner = state.data.actor === j.owner;
    const allowed = owner && hasBearer() && state.data.enabled;
    if (!funded && j.stage !== "complete" && c.state !== "closed") {
      const funding = node("div", "pool-funding"); funding.append(node("h3", "", "Fund the budget once"), node("p", "context-hint", "Pay this invoice from an external Lightning wallet. Work starts only after CLN confirms funding and you authorize Start."));
      if (c.funding?.bolt11) {
        const invoice = node("textarea", "pool-invoice"); invoice.readOnly = true; invoice.value = c.funding.bolt11; invoice.setAttribute("aria-label", "Funding invoice");
        funding.append(invoice, button("Copy funding invoice", async () => { await navigator.clipboard.writeText(c.funding.bolt11); notice("Funding invoice copied."); }));
      } else funding.append(node("p", "context-hint", "Creating the funding invoice. Refresh to check progress."));
      content.append(funding);
    }
    const actions = node("div", "pool-job-actions");
    actions.append(button(j.active ? "Update authorization" : "Start", async () => {
      const auto = entry.autoPay.checked;
      const confirmation = auto ? "start and pay verified segments" : "start funded indexing";
      if (!confirm(`${auto ? "Authorize indexing and automatic payments" : "Start indexing"} within this fixed ${fmt(j.contract.budget.total_sats)} sat budget?${auto ? " Only independently verified work can be paid; routing fees are capped." : " Earnings are recorded, but outgoing payments will not be started automatically."}`)) return;
      await post(`/jobs/${j.id}/start`, {quote_hash:j.quote_hash, auto_pay:auto, confirm:confirmation}); notice("Job authorization recorded."); await refresh();
    }, true, allowed && funded));
    actions.append(button("Pause", async () => { await post(`/jobs/${j.id}/pause`, {quote_hash:j.quote_hash}); notice("Further scheduling and payments paused. Already-started work or payments may finish."); await refresh(); }, false, allowed && j.active));
    actions.append(button("Check funding / settlement", async () => { await post(`/jobs/${j.id}/reconcile`); notice("Reconciliation requested. No new payment was submitted."); await refresh(); }, false, allowed));
    actions.append(button("Export contract", () => exportContract(j)));
    content.append(actions);
    const consent = node("label", "pool-pay-consent"), cb = node("input"); cb.type = "checkbox";
    cb.checked = entry.autoPay?.checked ?? j.auto_pay; cb.disabled = !allowed || !state.data.payments_enabled;
    entry.autoPay = cb; consent.append(cb, node("span", "", state.data.payments_enabled ? "Authorize bounded automatic payouts after verification" : "Outgoing payments are disabled in node configuration")); content.append(consent);
    const timeline = node("div", "pool-timeline");
    const accepted = Object.values(j.results || {}).filter(r => r.phase === "accepted").length;
    for (const [label, done] of [["Funded", c.funded_msat > 0], [`${accepted}/${j.units.length} verified`, accepted === j.units.length], ["Merged index", !!j.manifest], ["Settled", (c.payouts || []).length > 0 && c.payouts.every(p => p.state === "paid")]]) timeline.append(node("span", done ? "is-done" : "", label));
    content.append(timeline);
    if (j.last_error) content.append(node("div", "pool-detail-error", textError(j.last_error)));
    const segments = node("div", "pool-segment-list");
    for (const u of j.units) {
      const a = j.contract.assignments[u.id], r = j.results?.[u.id] || {}, price = j.contract.budget.unit_prices[u.id];
      const row = node("div", "pool-segment"), id = node("div");
      id.append(node("strong", "", `Segment ${u.ordinal} · ${a.indexer.node_name}`), node("small", "", `Verifier: ${a.verifier.unpaid_local_verifier ? "coordinator rebuild" : a.verifier.node_name}`));
      row.append(id, node("span", `status-tag state-${r.phase || "queued"}`, title(r.phase || "waiting")), node("span", "", `${sats(price.index_msat)} sats index${price.verify_msat ? ` · ${sats(price.verify_msat)} verify` : ""}`));
      segments.append(row);
    }
    content.append(segments);
    const accounts = c.node_allocations || [];
    if (accounts.length) {
      const box = node("details", "pool-advanced"); box.append(node("summary", "", "Participant earnings & settlement"));
      for (const p of accounts) {
        const item = node("p", "pool-hash", `${p.actor} · paid ${sats(p.paid_reward_msat)} sats · earned unpaid ${sats(p.earned_unpaid_msat)} sats · reserved ${sats(p.reserved_msat)} sats`); box.append(item);
      }
      for (const p of c.payouts || []) box.append(node("p", "pool-hash", `${title(p.role)} · ${sats(p.amount_msat)} sats · ${p.state} · ${p.payment_hash || "invoice not bound yet"}`));
      content.append(box);
    }
    if (j.manifest) {
      const form = node("form", "pool-search-form"), label = node("label", "", "Search the merged index"), input = node("input"); input.required = true; input.maxLength = 2048; label.append(input);
      const submit = node("button", "button button-outline button-sm", "Search"); submit.type = "submit"; const output = node("pre", "code-display"); output.hidden = true;
      form.append(label, submit); form.addEventListener("submit", e => {e.preventDefault(); action(async () => {const data = await post(`/jobs/${j.id}/search`, {q:input.value.trim()}); output.hidden = false; output.textContent = JSON.stringify(data, null, 2);});});
      content.append(form, output, node("p", "pool-hash", `Merged root: ${j.manifest.index_root}`));
    }
    const refund = node("details", "pool-advanced"); refund.append(node("summary", "", "Unused funds / refund"), node("p", "context-hint", "Pause first. Submitted work and uncertain payments stay reserved; they cannot be refunded. A refund uses an invoice from the pinned external wallet."));
    refund.append(button("Reserve refundable balance", async () => {if (!confirm("Close this job and reserve its unallocated balance for refund? Outstanding work must be resolved first.")) return; await post(`/jobs/${j.id}/refund`, {confirm:"refund unallocated funds"}); await refresh();}, false, allowed && !j.active && c.funded_msat > 0));
    const pendingRefund = (c.payouts || []).find(p => p.role === "refund" && p.state === "awaiting_invoice");
    if (pendingRefund) {
      const p = pendingRefund;
      refund.append(node("p", "pool-hash", `Amount: ${sats(p.amount_msat)} sats. Exact invoice description: ecai-index:v1:${j.id}:${p.id}:${p.artifact_sha256}`));
      const invoice = node("textarea", "pool-invoice"); invoice.placeholder = "Paste the matching refund invoice"; invoice.setAttribute("aria-label", "Refund invoice"); refund.append(invoice);
      refund.append(button("Pay refund", async () => {if (!confirm(`Pay ${sats(p.amount_msat)} sats to the pinned refund wallet, plus at most ${sats(p.fee_cap_msat)} sats routing fee?`)) return; await post(`/jobs/${j.id}/refund-pay`, {payout_id:p.id, invoice:invoice.value.trim(), confirm:"pay indexing refund"}); await refresh();}, false, allowed && state.data.payments_enabled));
    }
    content.append(refund, node("p", "pool-hash", `Participation contract: ${j.quote_hash}`));
  }
  function renderJobs(data) {
    const host = $("poolJobs"), next = new Map(), jobs = data.jobs || [];
    $("poolJobsCount").textContent = `${jobs.length} job${jobs.length === 1 ? "" : "s"}`;
    for (const j of jobs) {
      let entry = state.jobs.get(j.id);
      if (!entry) {
        const item = node("details", "pool-job"), summary = node("summary"), content = node("div", "pool-job-content");
        item.append(summary, content); entry = {item, summary, content, job:j};
        item.addEventListener("toggle", () => {if (item.open) {for (const other of state.jobs.values()) if (other !== entry) other.item.open = false; renderJobDetail(entry, entry.job);}});
      }
      entry.job = j;
      const identity = node("div", "pool-job-identity"); identity.append(node("strong", "", j.label || "Funded index"), node("small", "mono", j.id.slice(0,20)));
      const reward = node("span", "pool-job-meta"); reward.append(node("strong", "", `${fmt(j.contract.budget.total_sats)} sats`), node("small", "", "maximum budget"));
      const done = Object.values(j.results || {}).filter(r => r.phase === "accepted").length;
      const progress = node("span", "pool-job-meta"); progress.append(node("strong", "", `${done}/${j.units.length}`), node("small", "", "verified"));
      entry.summary.replaceChildren(identity, node("span", "status-tag", title(j.stage)), reward, progress, node("span", "", "⌄"));
      // Preserve form text/focus while an operator edits it. Refresh counters in
      // the summary; refresh expanded detail on the next non-editing poll.
      const editing = entry.content.contains(document.activeElement) && document.activeElement?.matches("input,textarea,select");
      if (entry.item.open && !editing) renderJobDetail(entry, j);
      next.set(j.id, entry);
    }
    state.jobs = next;
    if (!jobs.length) {host.replaceChildren(node("div", "empty-state", "No funded jobs yet.")); return;}
    [...next.values()].forEach((e,i) => {if (host.children[i] !== e.item) host.insertBefore(e.item, host.children[i] || null);});
    while (host.children.length > next.size) host.lastElementChild.remove();
  }
  async function refresh() {
    if (!state.api || !state.authenticated || !state.admin || !state.visible || document.hidden || state.refreshBusy) return;
    const epoch = state.epoch; state.refreshBusy = true; const ctrl = new AbortController(); state.controller = ctrl;
    try {
      const res = await state.api.request(`${root}/status`, {signal:ctrl.signal});
      if (epoch !== state.epoch || !state.visible) return;
      const d = res.data; if (!d || typeof d.enabled !== "boolean") throw Error("The node returned an incompatible pool response.");
      state.data = d;
      if (!d.enabled) {clearPrivateState(); state.data = d; notice("Funded indexing is disabled. Configure the reward ledger and index_pool_enabled, then restart ECAI."); updateButtons(); return;}
      if (!$("poolRefundNode").value && typeof d.refund_node === "string") $("poolRefundNode").value = d.refund_node;
      $("poolBudget").max = String(d.max_budget_sats); $("poolFee").max = String(d.max_fee_sats);
      options("poolPlan", (d.plans || []).map(p => [p.id, `${p.label} · ${p.segments} segments`]), "Prepare a source first");
      options("poolSource", (d.source_jobs || []).map(j => [j.id, `${j.kind} · ${j.id} · ${j.state}`]), "No eligible source jobs");
      renderNodes(d); renderMetrics(d); renderJobs(d); updateButtons();
      if (d.quarantined) notice("Reward ledger quarantined: inspect the settlement proof before enabling further payments.", true);
      else if (d.operation?.state === "failed") notice(`${title(d.operation.kind)} failed: ${textError(d.operation.error)}`, true);
      else if (d.operation?.state === "working") notice(`${title(d.operation.kind)} in progress. Status updates automatically.`);
      else notice(`${String(d.network).toUpperCase()} · ${d.payments_enabled ? "Payments enabled, with per-job authorization" : "Payments disabled"} · ${hasBearer() ? "Node-admin access" : "Read-only session; sign in again for changes"}`);
    } catch (e) {
      if (e.name !== "AbortError" && epoch === state.epoch) notice(e.status === 404 ? "Pool routes are missing. Deploy the funded-indexing patch and restart ECAI." : textError(e), true);
    } finally {if (state.controller === ctrl) {state.controller = null; state.refreshBusy = false;}}
  }
  function init(api) {
    state.api = api;
    $("poolRefresh").addEventListener("click", refresh);
    for (const id of ["poolPlan", "poolBudget", "poolVerify", "poolFee", "poolRefundNode"]) $(id).addEventListener("input", invalidate);
    $("poolAvailableNode").addEventListener("change", updateButtons); $("poolSource").addEventListener("change", updateButtons);
    $("poolJoinForm").addEventListener("submit", e => {e.preventDefault(); action(async () => {await post("/nodes", {node:$("poolAvailableNode").value}); notice("Participation proof requested."); await refresh();});});
    $("poolPrepare").addEventListener("click", () => action(async () => {await post("/prepare", {job_id:$("poolSource").value}); notice("Preparing bounded segments from the selected source."); await refresh();}));
    $("poolChannels").addEventListener("click", () => action(async () => {await post("/channels"); notice("Refreshing read-only channel observations."); await refresh();}));
    $("poolQuoteForm").addEventListener("submit", e => {e.preventDefault(); action(async () => {
      const body = selection(true), key = JSON.stringify(body), epoch = state.epoch; const q = await post("/quote", body);
      if (epoch !== state.epoch || key !== selectionKey()) return;
      state.quote = q; state.quoteKey = key; state.idempotency ||= `ecai-pool-${crypto.randomUUID()}`;
      renderQuote(q); notice("The server calculated and pinned the reward split. No funds have moved.");
    });});
    $("poolCreate").addEventListener("click", () => action(async () => {
      if (!state.quote || state.quoteKey !== selectionKey()) return;
      if (!confirm(`Create a ${fmt(state.quote.contract.budget.total_sats)} sat funded-indexing contract? The funding invoice must be paid separately.`)) return;
      await post("/jobs", {...selection(), quote_hash:state.quote.quote_hash, confirm:"create funded indexing job"}, {"Idempotency-Key":state.idempotency});
      invalidate(); notice("Contract created. Fund its invoice and authorize Start in the job panel."); await refresh();
    }));
    document.addEventListener("visibilitychange", () => {if (!document.hidden) refresh();});
    updateButtons();
  }
  function clearPrivateState() {
    state.data = null; state.jobs.clear(); state.nodes.clear(); invalidate();
    for (const id of ["poolJobs", "poolMetrics", "poolNodes", "poolNodeChoices"]) $(id).replaceChildren();
    options("poolPlan", [], "Prepare a source first"); options("poolSource", [], "No source jobs loaded");
    options("poolAvailableNode", [], "No allowlisted nodes loaded");
    $("poolJobsCount").textContent = "Not loaded"; $("poolRefundNode").value = "";
    $("poolChannelAge").textContent = "Channel capacity has not been checked.";
  }
  function setSession(authenticated, admin) {
    const changed = state.authenticated !== authenticated || state.admin !== admin;
    state.authenticated = !!authenticated; state.admin = !!admin;
    if (changed) {state.epoch++; state.controller?.abort(); state.controller = null; state.refreshBusy = false;}
    if (!authenticated || !admin) {clearPrivateState(); notice("A node-admin session is required.");}
    updateButtons();
  }
  function setVisible(visible) {
    state.visible = visible; clearInterval(state.timer); state.timer = null;
    if (!visible) {state.epoch++; state.controller?.abort(); state.controller = null; state.refreshBusy = false;}
    else state.timer = setInterval(refresh, 10000);
  }
  window.EcaiIndexPool = {init, setSession, setVisible, refresh};
})();
