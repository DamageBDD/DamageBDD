// Private enterprise receivables. No invoice data is persisted in browser storage.
// All user/customer text is rendered with textContent, never as executable HTML.
const root = document.getElementById("enterprise-billing");
const $ = (id) => document.getElementById(id);
const BASE = "/api/billing";
const limit = 50;
let authEpoch = 0, writeInFlight = false, invoiceReadSequence = 0, detailReadSequence = 0;
let state = {session: null, customers: [], plans: [], invoices: [], total: 0, offset: 0, selected: null};
const edits = {};
const accessToken = () => window.TokenManager?.getToken?.() || localStorage.getItem("access_token") || "";

function el(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = String(text);
    if (className) node.className = className;
    return node;
}
function button(label, action, id) {
    const b = el("button", label); b.type = "button"; b.dataset.billingAction = action;
    if (id) b.dataset.id = id;
    return b;
}
function badge(value) {
    const b = el("span", String(value || "—").replaceAll("_", " "), "billing-badge"); b.dataset.state = value; return b;
}
function amount(minor, currency = "AUD") {
    if (!Number.isSafeInteger(minor)) return "Invalid amount";
    return `${currency} ${Math.floor(minor / 100).toLocaleString("en-AU")}.${String(minor % 100).padStart(2, "0")}`;
}
export function decimalMinor(value) {
    const text = String(value).trim();
    if (!/^\d{1,10}(\.\d{1,2})?$/.test(text)) throw new Error("Use a non-negative amount with at most two decimal places.");
    const [whole, fraction = ""] = text.split(".");
    const result = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
    if (!Number.isSafeInteger(result)) throw new Error("Amount is too large.");
    return result;
}
const decimal = (minor = 0) => `${Math.floor(minor / 100)}.${String(minor % 100).padStart(2, "0")}`;
function notice(message, error = false) {
    const node = $("billing-notice"); node.textContent = message; node.hidden = !message; node.dataset.error = String(error);
}
function formError(form, message = "") {
    const p = form.querySelector(".billing-form-error"); if (!p) return;
    p.textContent = message; p.hidden = !message;
}
async function api(path, {method = "GET", body, pdf = false} = {}) {
    const epoch = authEpoch, token = accessToken();
    if (!token) throw new Error("Sign in to administer invoices.");
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 30000);
    try {
        const response = await fetch(BASE + path, {method, headers: {Authorization: `Bearer ${token}`,
            Accept: pdf ? "application/pdf" : "application/json", ...(body === undefined ? {} : {"Content-Type": "application/json"})},
            body: body === undefined ? undefined : JSON.stringify(body), signal: controller.signal,
            credentials: "omit", mode: "same-origin", redirect: "error", cache: "no-store", referrerPolicy: "no-referrer"});
        const data = pdf && response.ok ? await response.blob() : await response.json().catch(() => ({}));
        if (epoch !== authEpoch || token !== accessToken()) throw new Error("Session changed; response discarded.");
        if (!response.ok) {
            const error = new Error(data.message || `Billing request failed (${response.status}).`);
            error.status = response.status;
            if (response.status === 401 || response.status === 403) clearPrivate();
            throw error;
        }
        return pdf ? data : data.data;
    } catch (error) {
        if (error.name === "AbortError") throw new Error("Request timed out. Refresh before retrying; it may already have been saved.");
        throw error;
    } finally { clearTimeout(timeout); }
}
async function write(task, form = null) {
    if (writeInFlight) return;
    writeInFlight = true;
    const buttons = [...root.querySelectorAll("button")].map(b => [b, b.disabled]);
    buttons.forEach(([b]) => {b.disabled = true;});
    root.setAttribute("aria-busy", "true");
    if (form) formError(form);
    try { await task(); }
    catch (error) { if (form) formError(form, error.message); else notice(error.message, true); }
    finally { buttons.forEach(([b, disabled]) => {if (b.isConnected) b.disabled = disabled;}); root.removeAttribute("aria-busy"); writeInFlight = false; pagination(); }
}
function clearPrivate() {
    authEpoch++; invoiceReadSequence++; detailReadSequence++;
    state = {session: null, customers: [], plans: [], invoices: [], total: 0, offset: 0, selected: null};
    Object.keys(edits).forEach(k => delete edits[k]);
    ["billing-invoice-rows", "billing-customer-rows", "billing-plan-rows", "billing-admin-rows", "billing-admin-audit", "billing-detail", "billing-plan-lines", "billing-draft-lines"].forEach(id => $(id)?.replaceChildren());
    root.querySelectorAll("dialog").forEach(d => {if (d.open) d.close(); d.querySelector("form")?.reset();});
    $("billing-customer-filter")?.replaceChildren(new Option("All customers", ""));
    const planForm = $("billing-plan-form");
    if (planForm) {field(planForm, "customer_id").replaceChildren(); field(planForm, "payment_profile").replaceChildren();}
    notice("");
    root.hidden = true; $("billing-nav").hidden = true;
}
async function authenticate() {
    clearPrivate();
    const epoch = authEpoch;
    if (!accessToken()) return;
    try {
        const session = await api("/session");
        if (epoch !== authEpoch) return;
        state.session = session;
        root.hidden = false; $("billing-nav").hidden = false;
        $("billing-role").textContent = state.session.role.replaceAll("_", " ");
        $("billing-admins-nav").hidden = !state.session.can_manage_admins;
        $("billing-clock").textContent = `Schedule clock: ${state.session.clock === "node_local" ? "node local time (configure TZ on the billing node)" : "UTC"}, from ${String(state.session.send_hour).padStart(2, "0")}:00. Global auto-send: ${state.session.auto_send_enabled ? "enabled" : "off — drafts require approval"}.`;
        pane("invoices"); await refresh();
    } catch (error) { if (root && !root.hidden) notice(error.message, true); }
}
function pane(name) {
    if (name === "admins" && !state.session?.can_manage_admins) return;
    root.querySelectorAll("[data-billing-content]").forEach(p => p.hidden = p.dataset.billingContent !== name);
    root.querySelectorAll("[data-billing-pane]").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.billingPane === name)));
    if (name === "admins") loadAdmins().catch(e => notice(e.message, true));
}
async function refresh() {
    const epoch = authEpoch;
    const [customers, plans] = await Promise.all([api("/customers"), api("/plans")]);
    if (epoch !== authEpoch) return;
    state.customers = customers.items; state.plans = plans.items;
    renderCustomers(); renderPlans();
    const filter = $("billing-customer-filter"), prior = filter.value;
    filter.replaceChildren(new Option("All customers", ""), ...state.customers.map(c => new Option(c.name, c.id)));
    filter.value = prior;
    await loadInvoices();
    if (state.selected) await viewInvoice(state.selected.id, false);
}
async function loadInvoices() {
    const sequence = ++invoiceReadSequence;
    const q = new URLSearchParams({limit: String(limit), offset: String(state.offset), status: $("billing-status-filter").value, customer_id: $("billing-customer-filter").value});
    const page = await api(`/invoices?${q}`);
    if (sequence !== invoiceReadSequence) return;
    state.invoices = page.items; state.total = page.total;
    const rows = $("billing-invoice-rows"); rows.replaceChildren();
    if (!page.items.length) empty(rows, 7, "No invoices in this view. Add a customer and recurring plan, then create a draft.");
    for (const i of page.items) {
        const tr = el("tr"); tr.append(el("td", i.number || "Draft"));
        const customer = el("td", i.customer.name); customer.append(el("span", `${i.period_start} → ${i.period_end}`, "billing-muted")); tr.append(customer);
        tr.append(el("td", amount(i.total_minor, i.currency), "billing-money"), el("td", i.due_on || "Not issued"));
        const status = el("td"); status.append(badge(i.status)); const delivery = el("td"); delivery.append(badge(i.delivery.status));
        const action = el("td"); action.append(button("View", "view", i.id)); tr.append(status, delivery, action); rows.append(tr);
    }
    $("billing-page-summary").textContent = `${page.total} matching invoice${page.total === 1 ? "" : "s"}`;
    $("billing-page-label").textContent = page.total ? `${state.offset + 1}–${state.offset + page.items.length} of ${page.total}` : "0 invoices";
    pagination();
}
function pagination() {
    root.querySelector('[data-billing-action="previous"]').disabled = state.offset === 0;
    root.querySelector('[data-billing-action="next"]').disabled = state.offset + limit >= state.total;
}
function empty(tbody, count, text) { const tr = el("tr"), td = el("td", text, "billing-empty"); td.colSpan = count; tr.append(td); tbody.append(tr); }
function renderCustomers() {
    const rows = $("billing-customer-rows"); rows.replaceChildren();
    if (!state.customers.length) empty(rows, 4, "Add your enterprise customers or import the supplied paused seed file.");
    for (const c of state.customers) {
        const tr = el("tr"), status = el("td"), action = el("td");
        status.append(badge(c.enabled ? "active" : "paused")); action.append(button("Edit", "edit-customer", c.id));
        tr.append(el("td", c.name), el("td", c.email || "Email required"), status, action); rows.append(tr);
    }
}
function renderPlans() {
    const rows = $("billing-plan-rows"); rows.replaceChildren();
    if (!state.plans.length) empty(rows, 6, "No recurring plans yet.");
    for (const p of state.plans) {
        const tr = el("tr"), name = el("td", p.name);
        name.append(el("span", state.customers.find(c => c.id === p.customer_id)?.name || p.customer_id, "billing-muted"));
        const active = el("td"); active.append(badge(p.enabled ? "active" : "paused"));
        const actions = el("td", null, "billing-actions"); actions.append(button("Edit", "edit-plan", p.id));
        const generate = button("Create draft", "generate", p.id); generate.disabled = !p.next_date; actions.append(generate);
        tr.append(name, el("td", p.cadence === "monthly" ? "Monthly" : "Every 14 days"), el("td", p.next_date || "Commencement required"), active,
            el("td", p.auto_send ? (state.session.auto_send_enabled ? "On-time only" : "Blocked by node setting") : "Off"), actions); rows.append(tr);
    }
}
async function viewInvoice(id, scroll = true) {
    const epoch = authEpoch, sequence = ++detailReadSequence;
    const i = await api(`/invoices/${encodeURIComponent(id)}`);
    if (epoch !== authEpoch || sequence !== detailReadSequence) return;
    state.selected = i;
    const detail = $("billing-detail"); detail.replaceChildren(); detail.hidden = false;
    const header = el("header"), title = el("div"); title.append(el("h3", i.number || "Draft — not issued"), badge(i.status));
    const actions = el("div", null, "billing-header-actions");
    if (i.status === "draft") actions.append(button("Edit draft", "edit-draft", id), button("Approve & issue", "issue", id));
    if (i.status === "issue_failed") actions.append(button("Retry issuance", "issue", id));
    if (i.pdf_sha256) actions.append(button("Download PDF", "pdf", id));
    if (i.status === "issued") {
        const send = button(i.delivery.status === "sent" ? "Resend email" : "Send email", "send", id);
        send.disabled = ["queued", "sending"].includes(i.delivery.status); actions.append(send, button("Record payment", "payment", id));
    }
    if (["draft", "issued", "issue_failed"].includes(i.status)) actions.append(button("Void", "void", id));
    header.append(title, actions); detail.append(header);
    const dl = el("dl");
    const fields = [["Customer", `${i.customer.name}\n${i.customer.email}\n${i.customer.address}`], ["Service", i.title],
        ["Period", `${i.period_start} to ${i.period_end}`], ["Issued / due", i.issued_on ? `${i.issued_on} / ${i.due_on}` : "Dates assigned on approval"],
        ["Delivery", i.delivery.status.replaceAll("_", " ")], ["Total due", amount(i.total_minor, i.currency)]];
    if (i.paid_on) fields.push(["Payment recorded", `${i.paid_on} — ${i.payment_reference}`]);
    fields.forEach(([k, v]) => dl.append(el("dt", k), el("dd", v))); detail.append(dl);
    const error = i.delivery.last_error || (i.status === "issue_failed" ? i.last_error : "");
    if (error) detail.append(el("p", error, "billing-form-error"));
    const wrap = el("div", null, "billing-table-scroll"), table = el("table"), thead = el("thead"), thr = el("tr");
    ["Description", "Qty", "Unit price", "Discount", "Tax", "Total"].forEach(v => thr.append(el("th", v))); thead.append(thr); table.append(thead);
    const tbody = el("tbody");
    i.items.forEach(line => {const tr = el("tr"); tr.append(el("td", line.description, "billing-description"), el("td", line.quantity));
        [line.unit_price_minor, line.discount_minor, line.tax_minor, line.total_minor].forEach(v => tr.append(el("td", amount(v, i.currency), "billing-money"))); tbody.append(tr);});
    table.append(tbody); wrap.append(table); detail.append(wrap);
    if (i.notes) detail.append(el("p", i.notes, "billing-description"));
    const audit = el("details"), summary = el("summary", "Invoice audit trail"); audit.append(summary);
    i.audit.forEach(a => audit.append(el("div", `${new Date(a.at * 1000).toLocaleString()} · ${a.action} · ${a.actor}${a.note ? ` — ${a.note}` : ""}`, "billing-audit")));
    detail.append(audit);
    if (scroll) detail.scrollIntoView({behavior: "smooth", block: "start"});
}
const field = (form, name) => form.elements.namedItem(name);
function fill(form, record) {
    form.reset(); formError(form);
    for (const [key, value] of Object.entries(record)) {
        const input = field(form, key); if (!input || !("value" in input)) continue;
        if (input.type === "checkbox") input.checked = Boolean(value); else input.value = value ?? "";
    }
}
function openCustomer(customer = null) {
    const form = $("billing-customer-form"); edits.customer = customer;
    fill(form, customer || {id: "", name: "", email: "", abn: "", address: "", enabled: false});
    field(form, "id").readOnly = Boolean(customer); $("billing-customer-dialog").showModal();
}
function addLine(containerId, data = {}) {
    const row = el("div", null, "billing-line");
    const defaults = {description: "", quantity: 1, unit_price_minor: 0, discount_minor: 0, tax_bps: 0, ...data};
    for (const [key, label] of [["description", "Description"], ["quantity", "Qty"], ["unit_price_minor", "Unit price"], ["discount_minor", "Discount"], ["tax_bps", "Tax %"]]) {
        const wrap = el("label", label), input = el(key === "description" ? "textarea" : "input"); input.dataset.lineField = key;
        if (key === "description") {input.rows = 2; input.maxLength = 1500; input.value = defaults[key];}
        else if (key === "quantity") {input.type = "number"; input.min = "1"; input.max = "10000"; input.step = "1"; input.value = String(defaults[key]);}
        else {input.type = "text"; input.inputMode = "decimal"; input.value = decimal(defaults[key]);}
        input.required = true; wrap.append(input); row.append(wrap);
    }
    const remove = button("×", "remove-line"); remove.setAttribute("aria-label", "Remove line item"); row.append(remove); $(containerId).append(row);
}
function readLines(containerId) {
    return [...$(containerId).querySelectorAll(".billing-line")].map(row => {
        const result = {};
        row.querySelectorAll("[data-line-field]").forEach(input => {
            const k = input.dataset.lineField;
            result[k] = k === "description" ? input.value.trim() : k === "quantity" ? Number(input.value) : decimalMinor(input.value);
        });
        if (!Number.isInteger(result.quantity) || result.quantity < 1) throw new Error("Quantity must be a positive whole number.");
        return result;
    });
}
function openPlan(plan = null) {
    if (!state.customers.length) {notice("Add a customer before creating a recurring plan.", true); return;}
    const form = $("billing-plan-form"); edits.plan = plan;
    field(form, "customer_id").replaceChildren(...state.customers.map(c => new Option(c.name, c.id)));
    field(form, "payment_profile").replaceChildren(...(state.session.payment_profiles || ["default"]).map(p => new Option(p, p)));
    fill(form, plan || {id: "", name: "", customer_id: state.customers[0].id, cadence: "monthly", start_date: "", currency: "AUD", payment_profile: "default", terms_days: 7, notes: "", enabled: false, auto_send: false});
    field(form, "id").readOnly = Boolean(plan);
    ["customer_id", "cadence", "start_date"].forEach(k => field(form, k).disabled = Boolean(plan?.generated_count));
    $("billing-plan-lines").replaceChildren(); (plan?.items.length ? plan.items : [{}]).forEach(line => addLine("billing-plan-lines", line));
    $("billing-plan-dialog").showModal();
}
function openDraft() {
    const i = state.selected; if (!i || i.status !== "draft") return;
    edits.draft = i; const form = $("billing-draft-form"); fill(form, i);
    $("billing-draft-lines").replaceChildren(); i.items.forEach(line => addLine("billing-draft-lines", line));
    $("billing-draft-dialog").showModal();
}
async function loadAdmins() {
    const epoch = authEpoch;
    const data = await api("/admins");
    if (epoch !== authEpoch) return;
    const rows = $("billing-admin-rows"); rows.replaceChildren();
    if (!data.items.length) empty(rows, 3, "No delegated invoice administrators. Node administrators retain access.");
    data.items.forEach(a => {const tr = el("tr"), actions = el("td"), revoke = button("Revoke", "revoke-admin", a.account);
        revoke.disabled = a.source === "config"; actions.append(revoke); tr.append(el("td", a.account), el("td", a.source), actions); rows.append(tr);});
    $("billing-admin-audit").replaceChildren(...data.audit.slice(-100).reverse().map(a => el("div", `${new Date(a.at * 1000).toLocaleString()} · ${a.action} · ${a.actor} · ${a.target}`, "billing-audit")));
}
async function downloadPDF(id) {
    const invoice = state.selected?.id === id ? state.selected : await api(`/invoices/${encodeURIComponent(id)}`);
    const blob = await api(`/invoices/${encodeURIComponent(id)}/pdf`, {pdf: true}), url = URL.createObjectURL(blob);
    const link = el("a"); link.href = url; link.download = `${invoice.number}.pdf`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 10000);
}
async function invoiceAction(action, id) {
    const i = state.selected?.id === id ? state.selected : await api(`/invoices/${encodeURIComponent(id)}`);
    let body = {revision: i.revision};
    if (action === "issue" && !confirm(`Issue ${amount(i.total_minor, i.currency)} to ${i.customer.name}? Issued amounts and PDF contents cannot be edited.`)) return;
    if (action === "send") {
        const duplicate = ["sent", "unknown"].includes(i.delivery.status);
        if (!confirm(`${duplicate ? "This may send a duplicate. Check relay history first.\n\n" : ""}Email invoice ${i.number} and its PDF to ${i.customer.email}?`)) return;
        body.confirm_resend = duplicate;
    }
    if (action === "void") {const note = prompt("Reason for voiding (retained in the audit trail):"); if (!note?.trim()) return; body.note = note.trim();}
    await api(`/invoices/${encodeURIComponent(id)}/${action}`, {method: "POST", body});
    notice(action === "issue" ? "Issuance queued. The PDF is generated before email can be sent." : action === "send" ? "Email queued. “Sent” means the SMTP relay accepted it, not confirmed inbox delivery." : "Invoice voided; its number and audit history are retained.");
    await refresh();
}
async function importSeed(file) {
    if (!file) return;
    if (file.size > 262144) throw new Error("Seed file exceeds 256 KiB.");
    const data = JSON.parse(await file.text());
    if (data.version !== 1 || !Array.isArray(data.customers) || !Array.isArray(data.plans) || data.customers.length + data.plans.length > 100) throw new Error("Expected version 1 seed JSON with customers and plans arrays (maximum 100 records).");
    if (!confirm(`Import ${data.customers.length} customers and ${data.plans.length} plans as paused records? Existing IDs will be skipped. No invoices or emails will be created.`)) return;
    let added = 0;
    const existingC = new Set(state.customers.map(c => c.id)), existingP = new Set(state.plans.map(p => p.id));
    for (const c of data.customers) {if (existingC.has(c.id)) continue; await api("/customers", {method: "POST", body: {...c, enabled: false}}); existingC.add(c.id); added++;}
    for (const p of data.plans) {if (existingP.has(p.id)) continue; await api("/plans", {method: "POST", body: {...p, enabled: false, auto_send: false}}); existingP.add(p.id); added++;}
    notice(`Imported ${added} paused records. Review recipients, prices, commencement dates and tax settings before activating.`); await refresh();
}
function localDate() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function bind() {
    root.addEventListener("click", event => {
        const b = event.target.closest("button"); if (!b || !root.contains(b)) return;
        if (b.hasAttribute("data-billing-close")) {b.closest("dialog").close(); return;}
        if (b.dataset.billingPane) {pane(b.dataset.billingPane); return;}
        if (b.dataset.billingAddLine) {addLine(b.dataset.billingAddLine); return;}
        const action = b.dataset.billingAction, id = b.dataset.id;
        if (!action) return;
        if (action === "remove-line") {b.closest(".billing-line").remove(); return;}
        if (action === "new-customer") return openCustomer();
        if (action === "edit-customer") return openCustomer(state.customers.find(c => c.id === id));
        if (action === "new-plan") return openPlan();
        if (action === "edit-plan") return openPlan(state.plans.find(p => p.id === id));
        if (action === "edit-draft") return openDraft();
        if (action === "payment") {
            edits.payment = state.selected; const form = $("billing-payment-form"); fill(form, {paid_on: localDate(), payment_reference: "", note: ""});
            $("billing-payment-dialog").showModal(); return;
        }
        write(async () => {
            if (action === "refresh") return refresh();
            if (action === "view") return viewInvoice(id);
            if (action === "pdf") return downloadPDF(id);
            if (action === "previous" || action === "next") {state.offset = action === "previous" ? Math.max(0, state.offset - limit) : state.offset + limit; return loadInvoices();}
            if (["issue", "send", "void"].includes(action)) return invoiceAction(action, id);
            if (action === "generate") {
                const p = state.plans.find(p => p.id === id);
                if (!confirm(`Create a draft for ${p.name}, service period starting ${p.next_date}? No email will be sent.`)) return;
                const invoice = await api(`/plans/${encodeURIComponent(id)}/generate`, {method: "POST", body: {period_start: p.next_date}});
                await refresh(); pane("invoices"); await viewInvoice(invoice.id); notice("Draft created. Review it before approval.");
            }
            if (action === "revoke-admin" && confirm(`Revoke invoice administration for ${id}?`)) {
                await api("/admins", {method: "POST", body: {account: id, enabled: false}}); await loadAdmins();
            }
        });
    });
    ["billing-status-filter", "billing-customer-filter"].forEach(id => $(id).addEventListener("change", () => {state.offset = 0; loadInvoices().catch(e => notice(e.message, true));}));
    $("billing-customer-form").addEventListener("submit", event => {
        event.preventDefault(); const form = event.target;
        write(async () => {
            const body = {}; ["id", "name", "email", "abn", "address"].forEach(k => body[k] = field(form, k).value.trim()); body.enabled = field(form, "enabled").checked;
            if (edits.customer) body.revision = edits.customer.revision;
            await api(edits.customer ? `/customers/${encodeURIComponent(body.id)}` : "/customers", {method: edits.customer ? "PUT" : "POST", body});
            $("billing-customer-dialog").close(); await refresh(); notice("Customer saved.");
        }, form);
    });
    $("billing-plan-form").addEventListener("submit", event => {
        event.preventDefault(); const form = event.target;
        write(async () => {
            const body = {}; ["id", "name", "customer_id", "cadence", "currency", "notes", "payment_profile"].forEach(k => body[k] = field(form, k).value.trim());
            body.start_date = field(form, "start_date").value || null; body.terms_days = Number(field(form, "terms_days").value);
            body.enabled = field(form, "enabled").checked; body.auto_send = field(form, "auto_send").checked; body.items = readLines("billing-plan-lines");
            if (edits.plan) body.revision = edits.plan.revision;
            if (body.auto_send && body.enabled && !confirm("Enable on-time automatic issuance and email for this plan? The global node opt-in must also be enabled.")) return;
            await api(edits.plan ? `/plans/${encodeURIComponent(body.id)}` : "/plans", {method: edits.plan ? "PUT" : "POST", body});
            $("billing-plan-dialog").close(); await refresh(); notice("Recurring plan saved.");
        }, form);
    });
    $("billing-draft-form").addEventListener("submit", event => {
        event.preventDefault(); const form = event.target;
        write(async () => {
            const body = {revision: edits.draft.revision, items: readLines("billing-draft-lines"), notes: field(form, "notes").value, terms_days: Number(field(form, "terms_days").value)};
            await api(`/invoices/${encodeURIComponent(edits.draft.id)}`, {method: "PUT", body});
            $("billing-draft-dialog").close(); await refresh(); notice("Draft saved.");
        }, form);
    });
    $("billing-payment-form").addEventListener("submit", event => {
        event.preventDefault(); const form = event.target;
        write(async () => {
            const body = {revision: edits.payment.revision, paid_on: field(form, "paid_on").value, payment_reference: field(form, "payment_reference").value.trim(), note: field(form, "note").value.trim()};
            await api(`/invoices/${encodeURIComponent(edits.payment.id)}/paid`, {method: "POST", body});
            $("billing-payment-dialog").close(); await refresh(); notice("Verified payment recorded.");
        }, form);
    });
    $("billing-admin-form").addEventListener("submit", event => {event.preventDefault(); const form = event.target;
        write(async () => {await api("/admins", {method: "POST", body: {account: field(form, "account").value.trim(), enabled: true}}); form.reset(); await loadAdmins(); notice("Invoice administrator granted.");});});
    $("billing-import").addEventListener("change", event => {const file = event.target.files[0]; write(async () => {try {await importSeed(file);} finally {event.target.value = "";}});});
    document.addEventListener("auth:changed", authenticate);
    document.addEventListener("tabby", event => {if (event.detail?.tab?.getAttribute("href") === "#billing-tab" && state.session) refresh().catch(e => notice(e.message, true));});
    setInterval(() => {
        if (state.session && document.visibilityState === "visible" && root.offsetParent !== null && !writeInFlight && !root.querySelector("dialog[open]")) {
            loadInvoices().then(() => state.selected ? viewInvoice(state.selected.id, false) : undefined).catch(e => notice(e.message, true));
        }
    }, 15000);
    authenticate();
}
if (root) {if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bind, {once: true}); else bind();}
