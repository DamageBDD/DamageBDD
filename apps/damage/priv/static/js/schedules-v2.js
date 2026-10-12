import * as wallet from "./wallet.js";

const API = "/api/schedules/v2";
const TOKEN_DECIMALS = 8;
let mounted = false;
let host = null;
let currentRangeDays = 30;
let previewState = null;
let modalReturnFocus = null;
let modalKeyHandler = null;
let vaultCustodial = false;
let vaultAutoInitAttempted = false;

export async function updateSchedulesTable() {
  ensureStyles();
  host = findHost();
  if (!host) return;
  if (!mounted || !host.querySelector(".sv2-shell")) {
    mount(host);
    mounted = true;
    await resumeMobileWalletFlow();
  }
  await Promise.all([loadSchedules(), loadAnalytics(currentRangeDays), loadStatus()]);
}

function findHost() {
  const explicit = document.querySelector("[data-schedules-v2-root]");
  if (explicit) return explicit;
  return document.getElementById("schedules-tab")
    || document.querySelector("[id$='schedules-tab']")
    || document.querySelector("[data-tab='schedules']");
}

function ensureStyles() {
  if (document.querySelector('link[href="/static/css/schedules-v2.css"]')) return;
  const link = document.createElement("link");
  link.id = "schedules-v2-css";
  link.rel = "stylesheet";
  link.href = "/static/css/schedules-v2.css";
  document.head.appendChild(link);
}

function mount(root) {
  root.innerHTML = `
    <div class="sv2-shell">
      <div class="sv2-heading">
        <div>
          <div class="sv2-eyebrow">Verification</div>
          <h2>Schedules</h2>
          <p>Recurring verification with dry-run budgeting and locked DAMAGE.</p>
        </div>
        <div class="sv2-heading-actions">
          <span id="sv2-chain-status" class="sv2-chain-pill">Checking vault…</span>
          <button type="button" id="sv2-setup" class="sv2-secondary" hidden>Initialize vault</button>
          <button type="button" id="sv2-new" class="sv2-primary">+ New schedule</button>
        </div>
      </div>

      <div class="sv2-toolbar">
        <div class="sv2-range" role="group" aria-label="Analytics range">
          <button type="button" data-days="1">24h</button><button type="button" data-days="7">7d</button>
          <button type="button" data-days="30" class="active">30d</button><button type="button" data-days="90">90d</button>
          <button type="button" data-days="custom">Custom</button>
        </div>
        <div id="sv2-custom-range" class="sv2-custom-range" hidden>
          <input id="sv2-range-from" type="date"><span>to</span><input id="sv2-range-to" type="date">
          <button type="button" id="sv2-range-apply">Apply</button>
        </div>
        <button type="button" id="sv2-refresh" class="sv2-secondary">Refresh</button>
      </div>

      <div id="sv2-stats" class="sv2-stats"></div>
      <div class="sv2-chart-card">
        <div class="sv2-card-title"><span>Runs & spend</span><small id="sv2-chart-caption"></small></div>
        <div id="sv2-chart" class="sv2-chart"></div>
      </div>

      <div class="sv2-list-heading">
        <div><h3>Scheduled verification</h3><span id="sv2-count"></span></div>
      </div>
      <div id="sv2-list" class="sv2-list"><div class="sv2-empty">Loading schedules…</div></div>
    </div>
    <div id="sv2-modal" class="sv2-modal" hidden></div>
    <div id="sv2-toast" class="sv2-toast" hidden></div>
  `;

  root.querySelector("#sv2-new").addEventListener("click", openCreateModal);
  root.querySelector("#sv2-setup").addEventListener("click", () => initializeVault());
  root.querySelector("#sv2-refresh").addEventListener("click", updateSchedulesTable);
  root.querySelectorAll(".sv2-range button[data-days]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const value = btn.dataset.days;
      root.querySelectorAll(".sv2-range button").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      if (value === "custom") {
        root.querySelector("#sv2-custom-range").hidden = false;
        setDefaultCustomRange();
        return;
      }
      root.querySelector("#sv2-custom-range").hidden = true;
      currentRangeDays = Number(value);
      await loadAnalytics(currentRangeDays);
    });
  });
  root.querySelector("#sv2-range-apply").addEventListener("click", async () => {
    const from = dateInputEpoch(root.querySelector("#sv2-range-from").value, false);
    const to = dateInputEpoch(root.querySelector("#sv2-range-to").value, true);
    if (!from || !to || from > to) return toast("Choose a valid date range", "error");
    await loadAnalytics(null, from, to);
  });
}

async function loadStatus() {
  const pill = host.querySelector("#sv2-chain-status");
  const setup = host.querySelector("#sv2-setup");
  try {
    const r = await apiFetch(`${API}/status`);
    vaultCustodial = r.custodial === true;
    if (r.status === "ok") {
      pill.textContent = `Vault ${short(r.contract)}`;
      pill.className = "sv2-chain-pill ok";
      pill.title = r.contract;
      setup.hidden = true;
      return;
    }

    if (r.auto_setup === true && vaultCustodial && !vaultAutoInitAttempted) {
      vaultAutoInitAttempted = true;
      pill.textContent = "Initializing vault…";
      pill.className = "sv2-chain-pill";
      pill.title = "Custodial wallet detected; deploying the Schedule V2 vault";
      setup.hidden = true;
      await initializeVault({automatic: true});
      return;
    }

    pill.textContent = vaultCustodial ? "Vault initialization required" : "Vault setup required";
    pill.className = "sv2-chain-pill warn";
    pill.title = r.reason || "Schedule V2 vault has not been deployed";
    setup.textContent = vaultCustodial ? "Retry vault" : "Initialize vault";
    setup.hidden = !(vaultCustodial || isNodeAdmin());
  } catch (e) {
    pill.textContent = "Vault unavailable";
    pill.className = "sv2-chain-pill warn";
    pill.title = e.message || "Schedule V2 status request failed";
    setup.hidden = true;
  }
}

async function initializeVault({automatic = false} = {}) {
  const btn = host?.querySelector("#sv2-setup");
  if (!btn || !(vaultCustodial || isNodeAdmin())) return false;
  if (!automatic && !confirm("Deploy the Schedule V2 vault using the node account?")) return false;
  setBusy(btn, true);
  try {
    const r = await apiFetch(`${API}/setup`, {method: "POST", body: "{}"});
    if (!automatic) {
      toast(`Schedule V2 vault ready: ${short(r.contract || r.data?.contract || "")}`, "success");
    }
    await loadStatus();
    return true;
  } catch (e) {
    const pill = host?.querySelector("#sv2-chain-status");
    if (pill) {
      pill.textContent = "Vault initialization failed";
      pill.className = "sv2-chain-pill warn";
      pill.title = e.message || "Schedule V2 vault deployment failed";
    }
    btn.textContent = "Retry vault";
    btn.hidden = false;
    toast(e.message, "error");
    return false;
  } finally {
    setBusy(btn, false);
  }
}

function isNodeAdmin() {
  return String(document.body?.dataset?.nodeAdmin || "").toLowerCase() === "true";
}

async function loadSchedules() {
  const list = host.querySelector("#sv2-list");
  try {
    const response = await apiFetch(API);
    const schedules = response.data || [];
    host.querySelector("#sv2-count").textContent = `${schedules.length} schedule${schedules.length === 1 ? "" : "s"}`;
    if (!schedules.length) {
      list.innerHTML = `<div class="sv2-empty"><strong>No Schedule V2 jobs yet.</strong><span>Legacy schedules are intentionally not imported. Create a new budgeted schedule.</span><button type="button" class="sv2-primary" id="sv2-empty-create">Create schedule</button></div>`;
      list.querySelector("#sv2-empty-create")?.addEventListener("click", openCreateModal);
      return;
    }
    list.innerHTML = schedules.map(renderSchedule).join("");
    bindScheduleActions();
  } catch (e) {
    list.innerHTML = `<div class="sv2-empty error">${escapeHtml(e.message)}</div>`;
  }
}

function renderSchedule(s) {
  const status = String(s.status || "unknown");
  const remaining = Number(s.remaining ?? Math.max(0, (s.funded || 0) - (s.spent || 0) - (s.reserved || 0) - (s.refunded || 0)));
  const funded = Number(s.funded || 0);
  const spent = Number(s.spent || 0);
  const reserved = Number(s.reserved || 0);
  const pct = funded ? Math.min(100, (spent / funded) * 100) : 0;
  const last = s.last_run || null;
  const successRate = Number(s.success_rate || 0);
  return `
    <article class="sv2-schedule" data-id="${escapeAttr(s.id)}">
      <div class="sv2-schedule-top">
        <div class="sv2-feature">
          <div class="sv2-feature-title">${escapeHtml(cleanFeatureTitle(s.feature_title || "Feature"))}</div>
          <div class="sv2-feature-meta"><code title="${escapeAttr(s.feature_hash || "")}">${escapeHtml(short(s.feature_hash || ""))}</code><button type="button" class="sv2-copy" data-copy="${escapeAttr(s.feature_hash || "")}" title="Copy feature hash">⧉</button></div>
        </div>
        <span class="sv2-status ${escapeAttr(status)}">${escapeHtml(status)}</span>
      </div>
      <div class="sv2-schedule-grid">
        <div><label>Schedule</label><strong>${escapeHtml(s.cron_human || s.cron_spec || "—")}</strong><small>${escapeHtml(s.timezone || "UTC")} · ${windowLabel(s)}</small></div>
        <div><label>Next run</label><strong>${formatRelative(s.next_run_at)}</strong><small>${formatDateTime(s.next_run_at)}</small></div>
        <div><label>Last run</label><strong class="${lastStatusClass(last)}">${last ? statusSymbol(last.status) + " " + formatRelative(last.at) : "No runs yet"}</strong><small>${last ? `${formatDuration(last.duration_ms)} · ${formatDamage(last.cost)}` : "—"}</small></div>
        <div><label>Success</label><strong>${successRate.toFixed(1)}%</strong><small>${s.success_runs || 0} / ${s.total_runs || 0} runs</small></div>
      </div>
      <div class="sv2-budget">
        <div class="sv2-budget-row"><span><b>Budget</b> ${formatDamage(spent)} spent</span><span>${formatDamage(remaining)} available${reserved ? ` · ${formatDamage(reserved)} reserved` : ""}</span></div>
        <div class="sv2-progress"><i style="width:${pct.toFixed(2)}%"></i></div>
        <div class="sv2-budget-foot"><span>${formatDamage(funded)} locked</span><span>max ${formatDamage(s.max_cost_per_run || 0)} / run</span></div>
      </div>
      <div class="sv2-actions">
        <button type="button" data-action="run" class="sv2-secondary" ${status !== "active" ? "disabled" : ""}>Run now</button>
        ${status === "active" ? `<button type="button" data-action="pause" class="sv2-secondary">Pause</button>` : status === "paused" || status === "exhausted" ? `<button type="button" data-action="resume" class="sv2-secondary">Resume</button>` : ""}
        <button type="button" data-action="details" class="sv2-link">Details</button>
        <button type="button" data-action="cancel" class="sv2-danger" ${status === "cancelled" ? "disabled" : ""}>Cancel & unlock</button>
      </div>
    </article>`;
}

function bindScheduleActions() {
  host.querySelectorAll(".sv2-schedule").forEach(card => {
    const id = card.dataset.id;
    card.querySelectorAll("button[data-action]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const action = btn.dataset.action;
        if (action === "details") return openDetails(id);
        if (action === "cancel" && !confirm("Cancel this schedule and unlock all unreserved DAMAGE?")) return;
        await mutateSchedule(id, action, btn);
      });
    });
  });
  host.querySelectorAll(".sv2-copy").forEach(btn => btn.addEventListener("click", () => copy(btn.dataset.copy)));
}

async function mutateSchedule(id, action, btn) {
  setBusy(btn, true);
  try {
    const path = action === "run" ? "run" : action;
    const response = await apiFetch(`${API}/${encodeURIComponent(id)}/${path}`, { method: "POST", body: "{}" });
    await maybeSignResponse(response);
    toast(action === "cancel" ? "Schedule cancelled; unlocked balance is returning to the account." : `Schedule ${action} submitted`, "success");
    await updateSchedulesTable();
  } catch (e) { toast(e.message, "error"); }
  finally { setBusy(btn, false); }
}

async function openDetails(id) {
  try {
    const [detail, history] = await Promise.all([
      apiFetch(`${API}/${encodeURIComponent(id)}`),
      apiFetch(`${API}/${encodeURIComponent(id)}/runs?limit=12`)
    ]);
    const s = detail.data || {};
    const runs = history.data || [];
    showModal(`
      <div class="sv2-modal-card sv2-details">
        <button type="button" class="sv2-modal-close" data-close aria-label="Close schedule details">×</button>
        <div class="sv2-eyebrow">Schedule V2</div><h3>${escapeHtml(cleanFeatureTitle(s.feature_title || "Schedule"))}</h3>
        <dl>
          <dt>Status</dt><dd>${escapeHtml(s.status || "—")}</dd>
          <dt>Schedule ID</dt><dd><code>${escapeHtml(s.id || id)}</code></dd>
          <dt>Feature hash</dt><dd><code>${escapeHtml(s.feature_hash || "—")}</code></dd>
          <dt>Cron</dt><dd><code>${escapeHtml(s.cron_spec || "—")}</code> · ${escapeHtml(s.cron_human || "")}</dd>
          <dt>Window</dt><dd>${windowLabel(s)}</dd>
          <dt>Concurrency</dt><dd>${Number(s.concurrency || 1)}</dd>
          <dt>Locked</dt><dd>${formatDamage(s.funded || 0)}</dd>
          <dt>Spent</dt><dd>${formatDamage(s.spent || 0)}</dd>
          <dt>Reserved</dt><dd>${formatDamage(s.reserved || 0)}</dd>
          <dt>Available</dt><dd>${formatDamage(s.remaining || 0)}</dd>
          <dt>Max/run</dt><dd>${formatDamage(s.max_cost_per_run || 0)}</dd>
        </dl>
        <div class="sv2-history">
          <h4>Recent runs</h4>
          ${renderRunHistory(runs)}
        </div>
      </div>`);
  } catch (e) { toast(e.message, "error"); }
}

function renderRunHistory(runs) {
  if (!runs.length) return `<div class="sv2-empty compact">No runs yet.</div>`;
  return `<div class="sv2-history-list">${runs.map(run => {
    const status = String(run.status || "unknown");
    const report = run.report_hash
      ? `<code title="${escapeAttr(run.report_hash)}">${escapeHtml(short(run.report_hash))}</code>`
      : "—";
    return `<div class="sv2-history-row">
      <span class="sv2-run-state ${escapeAttr(status)}">${statusSymbol(status)} ${escapeHtml(status.replaceAll("_", " "))}</span>
      <span>${formatDateTime(run.ended_at || run.started_at)}</span>
      <span>${formatDuration(run.duration_ms || 0)}</span>
      <span>${formatDamage(run.cost || 0)}</span>
      <span>${report}</span>
    </div>`;
  }).join("")}</div>`;
}

async function loadAnalytics(days, customFrom, customTo) {
  const now = Math.floor(Date.now() / 1000);
  const from = customFrom || now - (days || 30) * 86400;
  const to = customTo || now;
  try {
    const r = await apiFetch(`${API}/analytics?from=${from}&to=${to}`);
    const data = r.data || {};
    renderStats(data.summary || {});
    renderChart(data.buckets || []);
    host.querySelector("#sv2-chart-caption").textContent = `${formatDate(from)} – ${formatDate(to)}`;
  } catch (e) {
    host.querySelector("#sv2-chart").innerHTML = `<div class="sv2-empty error">${escapeHtml(e.message)}</div>`;
  }
}

function renderStats(s) {
  host.querySelector("#sv2-stats").innerHTML = [
    ["Active", s.active_schedules ?? 0, "scheduled jobs"],
    ["Runs", s.runs ?? 0, `${s.failed ?? 0} failed`],
    ["Success", `${Number(s.success_rate || 0).toFixed(1)}%`, `${s.success ?? 0} successful`],
    ["Spend", formatDamage(s.spend || 0), "selected range"],
    ["Budget available", formatDamage(s.budget_available || 0), "locked & unspent"]
  ].map(([k,v,n]) => `<div class="sv2-stat"><label>${k}</label><strong>${v}</strong><small>${n}</small></div>`).join("");
}

function renderChart(buckets) {
  const el = host.querySelector("#sv2-chart");
  if (!buckets.length) { el.innerHTML = `<div class="sv2-empty compact">No runs in this range.</div>`; return; }
  const maxRuns = Math.max(1, ...buckets.map(b => Number(b.runs || 0)));
  const maxSpend = Math.max(1, ...buckets.map(b => Number(b.spend || 0)));
  el.innerHTML = `<div class="sv2-bars">${buckets.map(b => {
    const rh = Math.max(4, Math.round((Number(b.runs || 0) / maxRuns) * 100));
    const sh = Math.max(2, Math.round((Number(b.spend || 0) / maxSpend) * 100));
    return `<div class="sv2-bar-col" title="${b.day}: ${b.runs} runs, ${formatDamage(b.spend)}">
      <div class="sv2-bar-stack"><i class="runs" style="height:${rh}%"></i><i class="spend" style="height:${sh}%"></i></div>
      <span>${escapeHtml(String(b.day).slice(5))}</span></div>`;
  }).join("")}</div><div class="sv2-chart-legend"><span><i class="runs"></i>Runs</span><span><i class="spend"></i>Spend</span></div>`;
}

function openCreateModal() {
  previewState = null;
  const feature = document.getElementById("damageTextArea")?.value || "";
  const now = new Date();
  const end = new Date(Date.now() + 30 * 86400000);
  showModal(`
    <form id="sv2-create-form" class="sv2-modal-card sv2-create">
      <button type="button" class="sv2-modal-close" data-close aria-label="Close new schedule dialog">×</button>
      <div class="sv2-eyebrow">New Schedule V2</div><h3>Schedule verification</h3>
      <p class="sv2-form-intro">Dry-run the feature, count upcoming executions, then lock a bounded DAMAGE budget before activation.</p>

      <label class="sv2-field"><span>Feature</span><textarea id="sv2-feature" rows="9" required>${escapeHtml(feature)}</textarea></label>
      <div class="sv2-form-grid">
        <label class="sv2-field"><span>Frequency</span><select id="sv2-frequency">
          <option value="hourly">Every hour</option><option value="15m">Every 15 minutes</option>
          <option value="daily">Daily</option><option value="weekdays">Weekdays</option><option value="custom">Custom cron</option>
        </select></label>
        <label class="sv2-field" id="sv2-time-field"><span>Time</span><input id="sv2-time" type="time" value="09:00"></label>
        <label class="sv2-field sv2-custom-cron" hidden><span>Cron (UTC)</span><input id="sv2-cron" value="0 * * * *"></label>
        <label class="sv2-field"><span>Concurrency</span><input id="sv2-concurrency" type="number" min="1" max="1" value="1" disabled><small>Initial Schedule V2 serializes each account so measured execution cost remains exact.</small></label>
      </div>
      <div class="sv2-field"><span>Execution window</span><div class="sv2-presets"><button type="button" data-window="7">7 days</button><button type="button" data-window="30" class="active">30 days</button><button type="button" data-window="90">90 days</button></div></div>
      <div class="sv2-form-grid">
        <label class="sv2-field"><span>Starts</span><input id="sv2-start" type="datetime-local" value="${localDateTimeValue(now)}"></label>
        <label class="sv2-field"><span>Ends</span><input id="sv2-end" type="datetime-local" value="${localDateTimeValue(end)}"></label>
      </div>
      <div class="sv2-timezone-note">Times are converted to the Schedule V2 canonical UTC cron. Browser timezone: <b>${escapeHtml(browserTimezone())}</b>.</div>

      <div class="sv2-preview-card" id="sv2-preview-card"><div class="sv2-preview-empty">Run a dry-run preview to calculate the budget.</div></div>
      <div class="sv2-form-actions"><button type="button" id="sv2-preview" class="sv2-secondary">Calculate budget</button><button id="sv2-create" class="sv2-primary" disabled>Create & lock budget</button></div>
    </form>`);
  bindCreateForm();
}

function bindCreateForm() {
  const modal = document.getElementById("sv2-modal");
  const form = modal.querySelector("#sv2-create-form");
  const freq = form.querySelector("#sv2-frequency");
  freq.addEventListener("change", () => {
    form.querySelector(".sv2-custom-cron").hidden = freq.value !== "custom";
    form.querySelector("#sv2-time-field").hidden = !["daily","weekdays"].includes(freq.value);
    previewState = null; form.querySelector("#sv2-create").disabled = true;
  });
  form.querySelectorAll("[data-window]").forEach(btn => btn.addEventListener("click", () => {
    form.querySelectorAll("[data-window]").forEach(b => b.classList.remove("active")); btn.classList.add("active");
    const start = new Date(form.querySelector("#sv2-start").value || Date.now());
    form.querySelector("#sv2-end").value = localDateTimeValue(new Date(start.getTime() + Number(btn.dataset.window) * 86400000));
    previewState = null; form.querySelector("#sv2-create").disabled = true;
  }));
  form.querySelector("#sv2-preview").addEventListener("click", async () => {
    const btn = form.querySelector("#sv2-preview"); setBusy(btn, true);
    try {
      const spec = formSpec(form);
      const r = await apiFetch(`${API}/preview`, {method:"POST", body: JSON.stringify(spec)});
      previewState = {spec, preview:r}; renderBudgetPreview(form, r); form.querySelector("#sv2-create").disabled = false;
    } catch(e) { toast(e.message,"error"); }
    finally { setBusy(btn,false); }
  });
  form.addEventListener("submit", async (e) => {
    e.preventDefault(); if (!previewState) return;
    const btn = form.querySelector("#sv2-create"); setBusy(btn,true);
    try {
      const lockInput = form.querySelector("#sv2-lock");
      const spec = {...previewState.spec, lock_amount: Number(lockInput.dataset.baseUnits)};
      const r = await apiFetch(API, {method:"POST", body:JSON.stringify(spec)});
      await maybeSignResponse(r);
      hideModal(); toast("Schedule V2 created and budget locked.","success"); await updateSchedulesTable();
    } catch(e) { toast(e.message,"error"); }
    finally { setBusy(btn,false); }
  });
}

function formSpec(form) {
  const start = new Date(form.querySelector("#sv2-start").value);
  const end = new Date(form.querySelector("#sv2-end").value);
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || end <= start) throw new Error("Choose a valid execution window.");
  return {
    feature: form.querySelector("#sv2-feature").value,
    cron_spec: buildCron(form, start),
    timezone: browserTimezone(),
    start_at: Math.floor(start.getTime()/1000),
    end_at: Math.floor(end.getTime()/1000),
    concurrency: 1,
    safety_percent: 15,
    run_safety_percent: 15
  };
}

function buildCron(form, start) {
  const freq = form.querySelector("#sv2-frequency").value;
  if (freq === "custom") return form.querySelector("#sv2-cron").value.trim();
  if (freq === "15m") return "*/15 * * * *";
  if (freq === "hourly") return "0 * * * *";
  const [h,m] = (form.querySelector("#sv2-time").value || "09:00").split(":").map(Number);
  const local = new Date(start); local.setHours(h,m,0,0);
  const minute = local.getUTCMinutes(), hour = local.getUTCHours();
  if (freq === "weekdays") return `${minute} ${hour} * * 1-5`;
  return `${minute} ${hour} * * *`;
}

function renderBudgetPreview(form, r) {
  const dry = r.dry_run || {}, w = r.window || {}, b = r.budget || {};
  const card = form.querySelector("#sv2-preview-card");
  card.innerHTML = `<div class="sv2-preview-grid">
    <div><label>Dry-run cost</label><strong>${formatDamage(dry.cost_per_run || 0)} / run</strong></div>
    <div><label>Runs in range</label><strong>${Number(w.occurrences || 0)}</strong></div>
    <div><label>Estimated</label><strong>${formatDamage(b.estimated || 0)}</strong></div>
    <div><label>Safety reserve</label><strong>${Number(b.safety_percent || 0)}%</strong></div>
  </div>
  <div class="sv2-lock-row"><div><label>Amount to lock</label><small>Recommended from dry-run + reserve</small></div><input id="sv2-lock-display" value="${formatDamageNumber(b.recommended_lock || 0)}"><input id="sv2-lock" type="hidden" data-base-units="${Number(b.recommended_lock || 0)}" data-minimum="${Number(b.max_cost_per_run || 0)}"></div>
  <div class="sv2-cap-note">Hard per-run cap: <b>${formatDamage(b.max_cost_per_run || 0)}</b>. A run above this cap is blocked from settlement.</div>`;
  const display = card.querySelector("#sv2-lock-display"), hidden = card.querySelector("#sv2-lock");
  display.addEventListener("change", () => {
    const minimum = Number(hidden.dataset.minimum || 0);
    let v = parseDamage(display.value);
    if (v < minimum) {
      v = minimum;
      toast(`Lock must cover at least one capped run (${formatDamage(minimum)}).`, "error");
    }
    hidden.dataset.baseUnits = String(v);
    display.value = formatDamageNumber(v);
  });
}

async function maybeSignResponse(response) {
  let r = response;
  while (r && r.status === "signing_required") {
    const signed = await signPreparedTx(r.tx, {schedule_id:r.schedule_id, stage:r.stage});
    if (signed === "redirect") return;
    r = await apiFetch(`${API}/tx/submit`, {method:"POST", body:JSON.stringify({schedule_id:r.schedule_id, stage:r.stage, signed_tx:signed})});
  }
  return r;
}

async function signPreparedTx(tx, state) {
  if (/Android|iPhone|iPad|iPod/i.test(navigator.userAgent)) {
    localStorage.setItem("damage_schedule_v2_pending", JSON.stringify(state));
    const callback = new URL(window.location.href); callback.searchParams.set("schedule_v2_resume","1"); callback.searchParams.set("schedule_v2_tx_hash","{transaction-hash}");
    const cancel = new URL(window.location.href); cancel.searchParams.set("schedule_v2_cancel","1");
    const params = new URLSearchParams({transaction:tx, networkId:"ae_mainnet", broadcast:"true", "x-success":callback.toString(), "x-cancel":cancel.toString()});
    window.location.href = `https://wallet.superhero.com/sign-transaction?${params.toString()}`;
    return "redirect";
  }
  const result = await wallet.signTransactionSmart(tx, window.location.href, window.location.href);
  const signed = extractSignedTx(result);
  if (!signed) throw new Error("Wallet did not return a signed transaction.");
  return signed;
}

async function resumeMobileWalletFlow() {
  const params = new URLSearchParams(window.location.search);
  const txHash = params.get("schedule_v2_tx_hash");
  const pendingRaw = localStorage.getItem("damage_schedule_v2_pending");
  if (!txHash || !pendingRaw) return;
  try {
    const pending = JSON.parse(pendingRaw);
    localStorage.removeItem("damage_schedule_v2_pending");
    let r = await apiFetch(`${API}/tx/submit`, {method:"POST", body:JSON.stringify({...pending, tx_hash:txHash})});
    await maybeSignResponse(r);
    toast("Schedule transaction confirmed.","success");
  } catch(e) { toast(e.message,"error"); }
  finally {
    const url = new URL(window.location.href); url.searchParams.delete("schedule_v2_tx_hash"); url.searchParams.delete("schedule_v2_resume"); history.replaceState({},"",url);
  }
}

function extractSignedTx(result) {
  if (typeof result === "string" && result.startsWith("tx_")) return result;
  const candidates = [result?.tx, result?.signedTx, result?.signed_tx, result?.transaction, result?.result?.tx, result?.data?.tx, result?.result?.signedTx];
  return candidates.find(v => typeof v === "string" && v.length > 20) || null;
}

function showModal(html) {
  const modal = document.getElementById("sv2-modal");
  if (!modal) return;

  modalReturnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  modal.innerHTML = `<div class="sv2-modal-backdrop">${html}</div>`;
  modal.hidden = false;

  const card = modal.querySelector(".sv2-modal-card");
  if (card) {
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-modal", "true");
    card.setAttribute("tabindex", "-1");
    const title = card.querySelector("h3");
    if (title) {
      if (!title.id) title.id = `sv2-dialog-title-${Date.now()}`;
      card.setAttribute("aria-labelledby", title.id);
    }
  }

  modal.querySelectorAll("[data-close]").forEach(b => b.addEventListener("click", hideModal));
  modal.querySelector(".sv2-modal-backdrop")?.addEventListener("click", e => {
    if (e.target.classList.contains("sv2-modal-backdrop")) hideModal();
  });

  modalKeyHandler = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      hideModal();
    }
  };
  document.addEventListener("keydown", modalKeyHandler);

  const firstFocus = modal.querySelector("[data-close], input, textarea, select, button, [href]");
  window.requestAnimationFrame(() => (firstFocus || card)?.focus?.());
}

function hideModal() {
  const modal = document.getElementById("sv2-modal");
  if (!modal || modal.hidden) return;

  if (modalKeyHandler) {
    document.removeEventListener("keydown", modalKeyHandler);
    modalKeyHandler = null;
  }

  const returnFocus = modalReturnFocus;
  modalReturnFocus = null;
  if (document.activeElement && modal.contains(document.activeElement)) {
    (returnFocus?.isConnected ? returnFocus : host?.querySelector("#sv2-new"))?.focus?.();
  }

  modal.hidden = true;
  modal.innerHTML = "";
}

async function apiFetch(url, options={}) {
  const headers = new Headers(options.headers || {}); headers.set("accept","application/json");
  if (options.method && options.method !== "GET") headers.set("content-type","application/json");
  const token = window.TokenManager?.getToken?.(); if (token) headers.set("authorization",`Bearer ${token}`);
  const res = await fetch(url,{...options,headers,credentials:"include"});
  let body={}; try{body=await res.json();}catch(_e){}
  if(!res.ok || body.status === "notok") throw new Error(body.error || body.message || `Request failed (${res.status})`);
  return body;
}

function setBusy(btn,busy){ if(!btn)return; if(busy){btn.dataset.label=btn.textContent;btn.disabled=true;btn.textContent="Working…";}else{btn.disabled=false;if(btn.dataset.label)btn.textContent=btn.dataset.label;} }
function toast(message,type="info"){ const el=document.getElementById("sv2-toast"); if(!el)return; el.textContent=message;el.className=`sv2-toast ${type}`;el.hidden=false;clearTimeout(el._t);el._t=setTimeout(()=>el.hidden=true,5000); }
function copy(text){ navigator.clipboard?.writeText(text||""); toast("Copied","success"); }
function short(v){ const s=String(v||""); return s.length>20?`${s.slice(0,10)}…${s.slice(-6)}`:s; }
function cleanFeatureTitle(v){ return String(v||"").replace(/^Feature:\s*/i,""); }
function formatDamage(v){ return `${formatDamageNumber(v)} DAMAGE`; }
function formatDamageNumber(v){ return (Number(v||0)/10**TOKEN_DECIMALS).toLocaleString(undefined,{maximumFractionDigits:8}); }
function parseDamage(v){ const n=Number(String(v).replace(/,/g,"")); return Number.isFinite(n)?Math.round(n*10**TOKEN_DECIMALS):0; }
function formatDuration(ms){ const n=Number(ms||0); return n<1000?`${Math.round(n)} ms`:`${(n/1000).toFixed(1)} s`; }
function formatDateTime(epoch){ if(!epoch)return "—"; return new Date(Number(epoch)*1000).toLocaleString(); }
function formatDate(epoch){ if(!epoch)return "—"; return new Date(Number(epoch)*1000).toLocaleDateString(); }
function formatRelative(epoch){ if(!epoch)return "—"; const d=Number(epoch)*1000-Date.now(), a=Math.abs(d); const future=d>0; let n,u; if(a<60000){n=Math.max(1,Math.round(a/1000));u="sec";}else if(a<3600000){n=Math.round(a/60000);u="min";}else if(a<86400000){n=Math.round(a/3600000);u="hr";}else{n=Math.round(a/86400000);u="day";}return future?`in ${n} ${u}${n===1?"":"s"}`:`${n} ${u}${n===1?"":"s"} ago`; }
function statusSymbol(s){ return String(s)==="success"?"✓":String(s).includes("fail")?"✕":"•"; }
function lastStatusClass(last){ return !last?"":String(last.status)==="success"?"good":"bad"; }
function windowLabel(s){ const start=formatDate(s.start_at), end=s.end_at?formatDate(s.end_at):"no end"; return `${start} → ${end}`; }
function browserTimezone(){ return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; }
function localDateTimeValue(d){ const p=n=>String(n).padStart(2,"0"); return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; }
function setDefaultCustomRange(){ const to=new Date(), from=new Date(Date.now()-30*86400000); host.querySelector("#sv2-range-from").value=from.toISOString().slice(0,10);host.querySelector("#sv2-range-to").value=to.toISOString().slice(0,10); }
function dateInputEpoch(v,end){ if(!v)return null; const d=new Date(`${v}T${end?"23:59:59":"00:00:00"}`); return Math.floor(d.getTime()/1000); }
function escapeHtml(v){ return String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c])); }
function escapeAttr(v){ return escapeHtml(v); }
