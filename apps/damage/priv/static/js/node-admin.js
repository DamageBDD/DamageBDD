// /static/js/node_admin.js
// DamageBDD node admin HTTP wrapper + rich table rendering

window.nodeAdmin = (() => {
	const transactionState = { core: null, aeternity: null, lastUpdated: null };

	function byId(id) {
		return document.getElementById(id);
	}

	function escapeHtml(value) {
		return String(value ?? "")
			.replaceAll("&", "&amp;")
			.replaceAll("<", "&lt;")
			.replaceAll(">", "&gt;")
			.replaceAll('"', "&quot;")
			.replaceAll("'", "&#39;");
	}

	function setLoading(el, text = "Loading...") {
		if (!el) return;
		el.innerHTML = `<div class="admin-loading">${escapeHtml(text)}</div>`;
	}

	function setError(el, err) {
		if (!el) return;
		const message = err?.message || "Unknown error";
		if (el.closest?.(".transactions-workspace")) {
			el.innerHTML = `<div class="transaction-callout" data-tone="bad"><strong>Could not load transactions.</strong><span>${escapeHtml(message)}</span></div>`;
			return;
		}
		const payload = {
			ok: false,
			error: message,
			status: err?.status || null,
			data: err?.data || null
		};
		el.innerHTML = `<pre class="admin-pre">${escapeHtml(JSON.stringify(payload, null, 2))}</pre>`;
	}

	function getValue(id, fallback = "") {
		const el = byId(id);
		return el ? el.value : fallback;
	}

	function getIntValue(id, fallback = 0) {
		const raw = getValue(id, "");
		const n = parseInt(raw, 10);
		return Number.isFinite(n) ? n : fallback;
	}

	async function fetchJson(url, opts = {}) {
		const res = await fetch(url, {
			method: opts.method || "GET",
			headers: {
				accept: "application/json",
				...(opts.headers || {})
			},
			body: opts.body ? JSON.stringify(opts.body) : undefined,
			credentials: "same-origin"
		});

		const text = await res.text();
		let data = {};

		try {
			data = text ? JSON.parse(text) : {};
		} catch (_err) {
			data = { ok: false, raw: text };
		}

		if (!res.ok) {
			const err = new Error(data?.message || `Request failed: ${res.status}`);
			err.status = res.status;
			err.data = data;
			throw err;
		}

		return data;
	}

	async function getTransactions(limit = 50) {
		return fetchJson(`/api/node_admin/transactions?limit=${encodeURIComponent(limit)}`);
	}

	async function getAeternityTransactions(limit = 50) {
		return fetchJson(`/api/node_admin/aeternity/transactions?limit=${encodeURIComponent(limit)}`);
	}

	async function getChannels() {
		return fetchJson("/api/node_admin/channels");
	}

	async function getBestPeers(amountMsat = 200000000) {
		return fetchJson(
			`/api/node_admin/best_peers?amount_msat=${encodeURIComponent(amountMsat)}`
		);
	}

	async function connectPeer(peer) {
		return fetchJson("/api/node_admin/connect_peer", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: { peer }
		});
	}

	async function openChannel(peer, amountSats = 200000) {
		return fetchJson("/api/node_admin/open_channel", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: { peer, amount_sats: amountSats }
		});
	}

	async function openBestChannels(opts = {}) {
		return fetchJson("/api/node_admin/open_best_channels", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: opts
		});
	}
	async function getRecentInvoices(labelPrefix = "", limit = 50) {
		return fetchJson(
			`/api/node_admin/invoices/recent?label_prefix=${encodeURIComponent(labelPrefix)}&limit=${encodeURIComponent(limit)}`
		);
	}

	async function getUnpaidInvoices(labelPrefix = "", limit = 50) {
		return fetchJson(
			`/api/node_admin/invoices/unpaid?label_prefix=${encodeURIComponent(labelPrefix)}&limit=${encodeURIComponent(limit)}`
		);
	}

	async function getInvoiceStatusCounts() {
		return fetchJson("/api/node_admin/invoices/status_counts");
	}

	async function getAccountEvents(account, tag = "", limit = 100) {
		const qs = new URLSearchParams({
			account: account || "",
			limit: String(limit)
		});
		if (tag) qs.set("tag", tag);
		return fetchJson(`/api/node_admin/accounts/events?${qs.toString()}`);
	}

	async function getAccountSummary(account, tag = "") {
		const qs = new URLSearchParams({
			account: account || ""
		});
		if (tag) qs.set("tag", tag);
		return fetchJson(`/api/node_admin/accounts/summary?${qs.toString()}`);
	}

	async function getPeerchannelSummary() {
		return fetchJson("/api/node_admin/peerchannels/summary");
	}
	function btcFromSats(sats) {
		return (sats / 100000000).toFixed(8);
	}

	function scalarValue(value) {
		if (value === null || value === undefined) return value;
		if (typeof value !== "object") return value;
		for (const key of ["msat", "millisatoshis", "amount_msat", "amount", "value"]) {
			if (value[key] !== undefined) return value[key];
		}
		return value;
	}

	function amountWithTooltip(mainText, tooltip) {
		return `<span class="admin-amount" title="${escapeHtml(tooltip)}">${escapeHtml(mainText)}</span>`;
	}

	function formatMsat(value) {
		if (value === null || value === undefined || value === "") return "—";
		const raw = scalarValue(value);
		const str = String(raw).replace(/msat$/i, "").trim();
		const n = Number(str);
		if (!Number.isFinite(n)) return escapeHtml(String(raw));

		const sats = n / 1000;
		const btc = btcFromSats(sats);
		const satsText = `${sats.toLocaleString(undefined, { maximumFractionDigits: 3 })} sats`;
		return amountWithTooltip(satsText, `${btc} BTC · ${n.toLocaleString()} msat`);
	}

	function formatSats(value) {
		if (value === null || value === undefined || value === "") return "—";
		const n = Number(scalarValue(value));
		if (!Number.isFinite(n)) return escapeHtml(String(value));

		const satsText = `${n.toLocaleString()} sats`;
		return amountWithTooltip(satsText, `${btcFromSats(n)} BTC`);
	}

	function normalizeEpochMs(value) {
		const n = Number(value);
		if (!Number.isFinite(n) || n <= 0) return null;
		if (n >= 1e14) return Math.floor(n / 1000);
		if (n >= 1e11) return Math.floor(n);
		if (n >= 1e9) return Math.floor(n * 1000);
		return null;
	}

	function formatTimestampMs(ms, raw = ms) {
		if (!Number.isFinite(ms)) return escapeHtml(String(raw ?? ""));
		const d = new Date(ms);
		if (Number.isNaN(d.getTime())) return escapeHtml(String(raw ?? ""));
		return `<time datetime="${escapeHtml(d.toISOString())}" title="${escapeHtml(`Unix/time value: ${raw}`)}">${escapeHtml(d.toLocaleString())}</time>`;
	}

	function formatUnix(value) {
		if (value === null || value === undefined || value === "") return "—";
		const ms = normalizeEpochMs(value);
		return ms === null ? escapeHtml(String(value)) : formatTimestampMs(ms, value);
	}

	function formatDateish(value) {
		if (value === null || value === undefined || value === "") return "—";
		const ms = normalizeEpochMs(value);
		if (ms !== null) return formatTimestampMs(ms, value);

		const d = new Date(value);
		if (!Number.isNaN(d.getTime())) return formatTimestampMs(d.getTime(), value);
		return escapeHtml(String(value));
	}

	function truncateMiddle(value, left = 12, right = 10) {
		const s = String(value ?? "");
		if (s.length <= left + right + 3) return s;
		return `${s.slice(0, left)}…${s.slice(-right)}`;
	}

	function copyButton(value, label = "Copy") {
		const full = String(value ?? "");
		if (!full) return "";
		const encoded = encodeURIComponent(full);
		return `<button type="button" class="workspace-button admin-copy-btn" data-copy="${encoded}" title="${escapeHtml(label)}">${escapeHtml(label)}</button>`;
	}

	function copyableValue(value, opts = {}) {
		const full = String(value ?? "");
		if (!full) return `<span class="transaction-muted">—</span>`;
		const display = opts.truncate ? truncateMiddle(full, opts.left ?? 12, opts.right ?? 10) : full;
		return `
      <div class="admin-copy-cell">
        <code class="admin-code" title="${escapeHtml(full)}">${escapeHtml(display)}</code>
        ${copyButton(full, opts.copyLabel || "Copy")}
      </div>
    `;
	}

	function formatValue(value) {
		if (value === null || value === undefined || value === "") return `<span class="transaction-muted">—</span>`;
		if (typeof value === "boolean") return value ? "Yes" : "No";
		if (typeof value === "object") return `<code class="admin-code">${escapeHtml(JSON.stringify(value))}</code>`;
		return escapeHtml(String(value));
	}

	function humanize(value) {
		const raw = String(value ?? "").trim();
		if (!raw) return "Unknown";
		const mapped = {
			complete: "Complete", paid: "Paid", unpaid: "Unpaid", pending: "Pending",
			failed: "Failed", expired: "Expired", offered: "Offered", available: "Available",
			confirmed: "Confirmed", active: "Active", inactive: "Inactive",
			CHANNELD_NORMAL: "Active", CHANNELD_AWAITING_LOCKIN: "Opening"
		};
		if (mapped[raw] !== undefined) return mapped[raw];
		return raw
			.replace(/Tx$/i, "")
			.replace(/[_-]+/g, " ")
			.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
			.replace(/\b\w/g, (c) => c.toUpperCase());
	}

	function statusTone(value) {
		const v = String(value ?? "").toLowerCase();
		if (/(complete|paid|confirmed|available|active|normal|settled|success)/.test(v)) return "good";
		if (/(pending|offered|unpaid|opening|await|reserved|inflight)/.test(v)) return "warn";
		if (/(fail|error|expired|closed|disabled)/.test(v)) return "bad";
		return "neutral";
	}

	function badge(value, tone = statusTone(value)) {
		return `<span class="transaction-badge" data-tone="${escapeHtml(tone)}">${escapeHtml(humanize(value))}</span>`;
	}

	function stackedCell(primary, secondary = "", opts = {}) {
		return `<div class="transaction-cell-stack${opts.numeric ? " is-numeric" : ""}">
			<span class="transaction-cell-primary">${primary || '<span class="transaction-muted">—</span>'}</span>
			${secondary ? `<span class="transaction-cell-secondary">${secondary}</span>` : ""}
		</div>`;
	}

	function toSortNumber(value) {
		if (value === null || value === undefined || value === "") return null;

		const n = Number(value);
		if (Number.isFinite(n)) return n;

		const d = new Date(value).getTime();
		if (!Number.isNaN(d)) return d;

		return null;
	}

	function compareNewestFirst(a, b) {
		const keys = [
			"micro_time",
			"block_time",
			"created_index",
			"updated_index",
			"created_at",
			"paid_at",
			"received_at",
			"updated_at",
			"timestamp",
			"blockheight",
			"height"
		];

		for (const key of keys) {
			const av = toSortNumber(a?.[key]);
			const bv = toSortNumber(b?.[key]);

			if (av !== null || bv !== null) {
				return (bv ?? -Infinity) - (av ?? -Infinity);
			}
		}

		const aId = String(a?.channel_id || a?.txid || a?.payment_hash || a?.hash || a?.label || "");
		const bId = String(b?.channel_id || b?.txid || b?.payment_hash || b?.hash || b?.label || "");
		return bId.localeCompare(aId);
	}

	function sortNewest(rows) {
		return [...(rows || [])].sort(compareNewestFirst);
	}

	function renderTable(columns, rows, emptyMessage = "No data", opts = {}) {
		if (!Array.isArray(rows) || rows.length === 0) {
			return `<div class="admin-empty">${escapeHtml(emptyMessage)}</div>`;
		}

		const tableClass = ["admin-table", opts.className].filter(Boolean).join(" ");
		const thead = `
      <thead>
        <tr>
          ${columns.map((c) => `<th scope="col"${c.className ? ` class="${escapeHtml(c.className)}"` : ""}>${escapeHtml(c.label)}</th>`).join("")}
        </tr>
      </thead>
    `;

		const tbody = `
      <tbody>
        ${rows.map((row) => `
			  <tr>
              ${columns.map((c) => {
				  const raw = c.render ? c.render(row) : formatValue(row[c.key]);
				  const className = c.className ? ` class="${escapeHtml(c.className)}"` : "";
				  return `<td data-label="${escapeHtml(c.label)}"${className}>${raw}</td>`;
              }).join("")}
        </tr>
			`).join("")}
      </tbody>
    `;

		return `<div class="admin-table-wrap"><table class="${tableClass}">${thead}${tbody}</table></div>`;
	}

	function renderJsonBlock(title, data) {
		return `
      <details class="admin-details">
        <summary>${escapeHtml(title)}</summary>
        <pre class="admin-pre">${escapeHtml(JSON.stringify(data ?? {}, null, 2))}</pre>
      </details>
    `;
	}

	function msatNumber(value) {
		const raw = scalarValue(value);
		const n = Number(String(raw ?? "").replace(/msat$/i, "").trim());
		return Number.isFinite(n) ? n : 0;
	}

	function renderOnchain(data) {
		const onchain = data?.onchain || {};
		const outputs = sortNewest(Array.isArray(onchain.outputs) ? onchain.outputs : []);
		const channels = sortNewest(Array.isArray(onchain.channels) ? onchain.channels : []);

		const outputsHtml = renderTable(
			[
				{
					label: "Transaction",
					render: (r) => stackedCell(
						copyableValue(r.txid, { truncate: true, left: 10, right: 8, copyLabel: "Copy" }),
						r.output !== undefined ? `Output #${escapeHtml(r.output)}` : ""
					)
				},
				{
					label: "Amount",
					className: "transaction-number",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Status",
					render: (r) => stackedCell(
						badge(r.status || "unknown"),
						r.reserved === true ? "Reserved by wallet" : (r.scriptpubkey_type ? escapeHtml(humanize(r.scriptpubkey_type)) : "")
					)
				},
				{
					label: "Address",
					render: (r) => copyableValue(r.address, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{
					label: "Block",
					className: "transaction-number",
					render: (r) => r.blockheight ? escapeHtml(Number(r.blockheight).toLocaleString()) : `<span class="transaction-muted">Unconfirmed</span>`
				}
			],
			outputs,
			"No on-chain outputs reported by Core Lightning",
			{ className: "transaction-table transaction-table-bitcoin" }
		);

		const channelsHtml = renderTable(
			[
				{
					label: "Peer",
					render: (r) => copyableValue(r.peer_id, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{
					label: "Channel",
					render: (r) => stackedCell(
						copyableValue(r.channel_id, { truncate: true, left: 10, right: 8, copyLabel: "Copy" }),
						r.short_channel_id ? escapeHtml(r.short_channel_id) : ""
					)
				},
				{
					label: "Capacity",
					className: "transaction-number",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Local share",
					className: "transaction-number",
					render: (r) => formatMsat(r.our_amount_msat)
				},
				{
					label: "State",
					render: (r) => stackedCell(
						badge(r.state || (r.connected ? "active" : "inactive")),
						r.connected === true ? "Peer connected" : (r.connected === false ? "Peer disconnected" : "")
					)
				},
				{
					label: "Funding transaction",
					render: (r) => copyableValue(r.funding_txid, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				}
			],
			channels,
			"No channel funding records found",
			{ className: "transaction-table transaction-table-bitcoin" }
		);

		return `
      <div class="admin-section-block transaction-section-block">
        <div class="transaction-section-heading">
          <div><h3>On-chain outputs</h3><p>${outputs.length} output${outputs.length === 1 ? "" : "s"} currently reported by the node wallet.</p></div>
        </div>
        ${outputsHtml}
      </div>
      <div class="admin-section-block transaction-section-block">
        <div class="transaction-section-heading">
          <div><h3>Channel funding</h3><p>${channels.length} funding record${channels.length === 1 ? "" : "s"} linked to Lightning channels.</p></div>
        </div>
        ${channelsHtml}
      </div>
      ${renderJsonBlock("Raw Bitcoin / listfunds response", onchain)}
    `;
	}

	function paymentFeeMsat(row) {
		return Math.max(0, msatNumber(row?.amount_sent_msat) - msatNumber(row?.amount_msat));
	}

	function renderLightning(data) {
		const lightning = data?.lightning || {};
		const pays = sortNewest(Array.isArray(lightning?.pays?.pays) ? lightning.pays.pays : []);
		const sendpays = sortNewest(Array.isArray(lightning?.sendpays?.payments) ? lightning.sendpays.payments : []);
		const invoices = sortNewest(Array.isArray(lightning?.invoices?.invoices) ? lightning.invoices.invoices : []);

		const invoicesHtml = renderTable(
			[
				{
					label: "Invoice",
					render: (r) => stackedCell(
						escapeHtml(r.label || "Unlabelled invoice"),
						r.bolt11 ? copyableValue(r.bolt11, { truncate: true, left: 14, right: 10, copyLabel: "Copy BOLT11" }) : ""
					)
				},
				{ label: "Status", render: (r) => badge(r.status || "unknown") },
				{ label: "Amount", className: "transaction-number", render: (r) => formatMsat(r.amount_msat) },
				{ label: "Received", className: "transaction-number", render: (r) => formatMsat(r.amount_received_msat) },
				{
					label: "Created",
					render: (r) => r.created_at ? formatDateish(r.created_at) : (r.created_index !== undefined ? `Index ${escapeHtml(r.created_index)}` : "—")
				},
				{
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				}
			],
			invoices,
			"No Lightning invoices found",
			{ className: "transaction-table transaction-table-lightning" }
		);

		const paysHtml = renderTable(
			[
				{
					label: "Payment",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{ label: "Status", render: (r) => badge(r.status || "unknown") },
				{ label: "Amount", className: "transaction-number", render: (r) => formatMsat(r.amount_msat) },
				{
					label: "Fee",
					className: "transaction-number",
					render: (r) => formatMsat(paymentFeeMsat(r))
				},
				{
					label: "Destination",
					render: (r) => copyableValue(r.destination, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{
					label: "Created",
					render: (r) => r.created_at ? formatDateish(r.created_at) : `<span class="transaction-muted">—</span>`
				}
			],
			pays,
			"No outgoing Lightning payments found",
			{ className: "transaction-table transaction-table-lightning" }
		);

		const sendpaysHtml = renderTable(
			[
				{ label: "Status", render: (r) => badge(r.status || "unknown") },
				{ label: "Amount", className: "transaction-number", render: (r) => formatMsat(r.amount_msat) },
				{ label: "Sent", className: "transaction-number", render: (r) => formatMsat(r.amount_sent_msat) },
				{
					label: "Destination",
					render: (r) => copyableValue(r.destination, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				},
				{ label: "Created", render: (r) => r.created_at ? formatUnix(r.created_at) : "—" }
			],
			sendpays,
			"No payment attempts found",
			{ className: "transaction-table transaction-table-lightning" }
		);

		return `
      <div class="admin-section-block transaction-section-block">
        <div class="transaction-section-heading">
          <div><h3>Invoices</h3><p>${invoices.length} incoming invoice${invoices.length === 1 ? "" : "s"}, newest first.</p></div>
        </div>
        ${invoicesHtml}
      </div>
      <div class="admin-section-block transaction-section-block">
        <div class="transaction-section-heading">
          <div><h3>Outgoing payments</h3><p>${pays.length} payment${pays.length === 1 ? "" : "s"} with routing fee shown separately.</p></div>
        </div>
        ${paysHtml}
      </div>
      <details class="transaction-subdetails">
        <summary>Payment attempts <span>${sendpays.length}</span></summary>
        <p class="transaction-subdetails-copy">Low-level sendpay attempts are kept available for debugging without crowding the primary ledger.</p>
        ${sendpaysHtml}
      </details>
      ${renderJsonBlock("Raw Lightning response", lightning)}
    `;
	}

	function aeScalar(value) {
		if (value && typeof value === "object" && !Array.isArray(value) && Object.hasOwn(value, "value")) return value.value;
		if (Array.isArray(value) && value.length === 2 && typeof value[0] === "string") return value[1];
		return value;
	}

	function aeText(value) {
		const v = aeScalar(value);
		if (v === null || v === undefined) return "";
		return String(v).trim();
	}

	function aeCandidates(root) {
		const pending = [root];
		const seen = new Set();
		const out = [];
		while (pending.length && out.length < 28) {
			const value = pending.shift();
			if (!value || typeof value !== "object" || seen.has(value)) continue;
			seen.add(value);
			out.push(value);
			for (const key of ["payload", "tx", "transaction", "inner_tx", "internal_tx", "call_info", "call"]) {
				if (value[key] && typeof value[key] === "object") pending.push(value[key]);
			}
		}
		return out;
	}

	function aeFirst(candidates, keys, predicate = () => true) {
		for (const candidate of candidates) {
			for (const key of keys) {
				const value = aeScalar(candidate?.[key]);
				if (value !== undefined && value !== null && value !== "" && predicate(value, candidate)) return value;
			}
		}
		return undefined;
	}

	function aeAddress(value) {
		const text = aeText(value);
		return /^(ak|ct|ok|ch)_[1-9A-HJ-NP-Za-km-z]{10,}$/.test(text) ? text : "";
	}

	function aeTxHash(row) {
		return aeText(aeFirst(aeCandidates(row), ["hash", "tx_hash", "call_tx_hash"], (v) => String(v).startsWith("th_")));
	}

	function aeTypes(row) {
		return aeCandidates(row)
			.flatMap((candidate) => [candidate?.type, candidate?.tx_type, candidate?.kind])
			.map(aeText)
			.filter(Boolean);
	}

	function aeMethod(row) {
		return aeText(aeFirst(aeCandidates(row), ["function", "function_name", "entrypoint", "call_name", "func"]));
	}

	function aeTypeLabel(row) {
		const types = aeTypes(row);
		const method = aeMethod(row);
		const payingFor = types.some((v) => /paying.?for/i.test(v));
		const contractCall = types.some((v) => /contract.?call/i.test(v));
		const spend = types.some((v) => /^spend.?tx$/i.test(v));
		if (payingFor && contractCall) return { primary: "Sponsored contract call", secondary: method ? humanize(method) : "Fee paid by sponsor" };
		if (contractCall) return { primary: "Contract call", secondary: method ? humanize(method) : "Smart contract" };
		if (spend) return { primary: "AE transfer", secondary: "Spend transaction" };
		const type = types.find((v) => /Tx$/i.test(v)) || types[0] || "Transaction";
		return { primary: humanize(type), secondary: method ? humanize(method) : "" };
	}

	function aeRole(row, account) {
		const candidates = aeCandidates(row);
		const accountText = String(account || "");
		for (const candidate of candidates) {
			for (const key of ["caller_id", "sender_id", "account_id", "owner_id"]) {
				if (aeText(candidate?.[key]) === accountText) return "outgoing";
			}
		}
		for (const candidate of candidates) {
			for (const key of ["recipient_id", "beneficiary_id"]) {
				if (aeText(candidate?.[key]) === accountText) return "incoming";
			}
		}
		for (const candidate of candidates) {
			if (aeText(candidate?.payer_id) === accountText) return "sponsored";
		}
		return "related";
	}

	function aeCounterparty(row, account, role) {
		const candidates = aeCandidates(row);
		const keys = role === "incoming"
			? ["sender_id", "caller_id", "payer_id", "owner_id"]
			: ["recipient_id", "contract_id", "beneficiary_id", "caller_id", "sender_id"];
		for (const candidate of candidates) {
			for (const key of keys) {
				const address = aeAddress(candidate?.[key]);
				if (address && address !== account) return address;
			}
		}
		return "";
	}

	function aeNumeric(row, keys) {
		const value = aeFirst(aeCandidates(row), keys, (v) => /^-?\d+(?:\.\d+)?$/.test(String(v)));
		return value === undefined ? null : aeText(value);
	}

	function formatAettos(value) {
		if (value === null || value === undefined || value === "") return `<span class="transaction-muted">—</span>`;
		const text = String(value).trim();
		try {
			if (/^-?\d+$/.test(text)) {
				const n = BigInt(text);
				const sign = n < 0n ? "-" : "";
				const abs = n < 0n ? -n : n;
				const unit = 1000000000000000000n;
				const whole = abs / unit;
				const remainder = abs % unit;
				const fraction = ((remainder * 1000000n) / unit).toString().padStart(6, "0").replace(/0+$/, "");
				const display = `${sign}${whole.toString()}${fraction ? `.${fraction}` : ""} AE`;
				return amountWithTooltip(display, `${text} aettos`);
			}
		} catch (_err) {
		}
		const n = Number(text);
		if (Number.isFinite(n)) return amountWithTooltip(`${(n / 1e18).toLocaleString(undefined, { maximumFractionDigits: 6 })} AE`, `${text} aettos`);
		return escapeHtml(text);
	}

	function normalizeAeActivity(row, account) {
		const candidates = aeCandidates(row);
		const role = aeRole(row, account);
		const type = aeTypeLabel(row);
		const timeRaw = aeFirst(candidates, ["micro_time", "block_time", "time", "created_at"]);
		const height = aeFirst(candidates, ["height", "block_height"]);
		return {
			raw: row,
			txHash: aeTxHash(row),
			type,
			role,
			counterparty: aeCounterparty(row, account, role),
			amount: aeNumeric(row, ["amount"]),
			fee: aeNumeric(row, ["fee"]),
			timeRaw,
			height: height === undefined ? "" : aeText(height)
		};
	}

	function renderAeternity(data) {
		const account = String(data?.account || "");
		const rawRows = sortNewest(Array.isArray(data?.transactions) ? data.transactions : []);
		const rows = rawRows.map((row) => normalizeAeActivity(row, account));
		const accountHtml = account
			? copyableValue(account, { truncate: true, left: 13, right: 10, copyLabel: "Copy account" })
			: `<span class="transaction-muted">Node account unavailable</span>`;
		const warning = data?.ok === false
			? `<div class="transaction-callout" data-tone="warn"><strong>Aeternity middleware unavailable.</strong><span>${escapeHtml(data?.error || "Could not load node account activity")}</span></div>`
			: "";

		const table = renderTable(
			[
				{
					label: "Type",
					render: (r) => stackedCell(escapeHtml(r.type.primary), r.type.secondary ? escapeHtml(r.type.secondary) : "")
				},
				{
					label: "Direction",
					render: (r) => badge(r.role, r.role === "incoming" ? "good" : (r.role === "sponsored" ? "warn" : "neutral"))
				},
				{
					label: "Counterparty",
					render: (r) => copyableValue(r.counterparty, { truncate: true, left: 11, right: 9, copyLabel: "Copy" })
				},
				{
					label: "Value",
					className: "transaction-number",
					render: (r) => stackedCell(
						formatAettos(r.amount),
						r.fee !== null ? `Fee ${formatAettos(r.fee)}` : "",
						{ numeric: true }
					)
				},
				{
					label: "When",
					render: (r) => stackedCell(
						r.timeRaw !== undefined ? formatUnix(r.timeRaw) : `<span class="transaction-muted">Unknown time</span>`,
						r.height ? `Block ${escapeHtml(Number(r.height).toLocaleString())}` : ""
					)
				},
				{
					label: "Transaction",
					render: (r) => copyableValue(r.txHash, { truncate: true, left: 10, right: 8, copyLabel: "Copy" })
				}
			],
			rows,
			"No recent Aeternity transactions found for the node account",
			{ className: "transaction-table transaction-table-aeternity" }
		);

		return `
      ${warning}
      <div class="transaction-context">
        <span>Node account</span>
        ${accountHtml}
        <small>${rows.length} recent transaction${rows.length === 1 ? "" : "s"}</small>
      </div>
      <div class="admin-section-block transaction-section-block">
        ${table}
      </div>
      ${renderJsonBlock("Raw Aeternity middleware response", data)}
    `;
	}

	function transactionSummaryCard(label, value, detail, tone = "neutral") {
		return `<article class="transaction-stat" data-tone="${escapeHtml(tone)}">
			<span class="transaction-stat-label">${escapeHtml(label)}</span>
			<strong>${value}</strong>
			<small>${detail}</small>
		</article>`;
	}

	function renderTransactionSummary() {
		const el = byId("node-transaction-summary");
		if (!el) return;
		const core = transactionState.core;
		const ae = transactionState.aeternity;
		const outputs = Array.isArray(core?.onchain?.outputs) ? core.onchain.outputs : [];
		const invoices = Array.isArray(core?.lightning?.invoices?.invoices) ? core.lightning.invoices.invoices : [];
		const pays = Array.isArray(core?.lightning?.pays?.pays) ? core.lightning.pays.pays : [];
		const aeRows = Array.isArray(ae?.transactions) ? ae.transactions : [];
		const onchainMsat = outputs.reduce((sum, row) => sum + msatNumber(row?.amount_msat), 0);
		const paidInvoices = invoices.filter((row) => String(row?.status || "").toLowerCase() === "paid").length;
		const completePays = pays.filter((row) => /complete|paid/i.test(String(row?.status || ""))).length;

		const coreFailed = core?.ok === false;
		const aeFailed = ae?.ok === false;
		const bitcoinValue = coreFailed
			? `<span class="transaction-muted">Unavailable</span>`
			: core ? formatMsat(onchainMsat) : `<span class="transaction-muted">Loading…</span>`;
		const lightningValue = coreFailed
			? `<span class="transaction-muted">Unavailable</span>`
			: core ? `${invoices.length.toLocaleString()} <span>invoices</span>` : `<span class="transaction-muted">Loading…</span>`;
		const aeValue = aeFailed
			? `<span class="transaction-muted">Unavailable</span>`
			: ae ? `${aeRows.length.toLocaleString()} <span>transactions</span>` : `<span class="transaction-muted">Loading…</span>`;

		el.innerHTML = [
			transactionSummaryCard(
				"Bitcoin", bitcoinValue,
				coreFailed ? "Core Lightning transaction API unavailable" : `${outputs.length} UTXO${outputs.length === 1 ? "" : "s"} reported`,
				coreFailed ? "bad" : (core ? "good" : "neutral")
			),
			transactionSummaryCard(
				"Lightning", lightningValue,
				coreFailed ? "Core Lightning transaction API unavailable" : `${paidInvoices} paid in · ${completePays} completed out`,
				coreFailed ? "bad" : (core ? "good" : "neutral")
			),
			transactionSummaryCard(
				"Aeternity", aeValue,
				ae?.account ? truncateMiddle(ae.account, 13, 10) : (aeFailed ? "Middleware unavailable" : "Node account activity"),
				aeFailed ? "warn" : (ae ? "good" : "neutral")
			)
		].join("");
	}

	function renderChannels(data) {
		const balance = data?.balance ?? {};
		const channels = sortNewest(
			Array.isArray(data?.channels?.channels)
				? data.channels.channels
				: Array.isArray(data?.channels)
				? data.channels
				: []
		);

		const balanceHtml = `
      <div class="admin-kv">
        <div><strong>On-chain total:</strong> ${balance?.onchain_msat ? formatMsat(balance.onchain_msat) : ""}</div>
		<div><strong>Channel total:</strong> ${formatMsat(balance?.channels_msat ?? balance?.channel_msat)}</div>
        <div><strong>Spendable:</strong> ${balance?.spendable_msat ? formatMsat(balance.spendable_msat) : ""}</div>
        <div><strong>Receivable:</strong> ${balance?.receivable_msat ? formatMsat(balance.receivable_msat) : ""}</div>
      </div>
    `;

		const channelsHtml = renderTable(
			[
				{
					label: "Peer",
					render: (r) => copyableValue(r.peer_id, { truncate: true, copyLabel: "Copy peer" })
				},
				{ key: "short_channel_id", label: "Short Channel ID" },
				{
					label: "Channel ID",
					render: (r) => copyableValue(r.channel_id, { truncate: true, copyLabel: "Copy chan" })
				},
				{ key: "state", label: "State" },
				{
					label: "Total",
					render: (r) => formatMsat(r.total_msat)
				},
				{
					label: "To us",
					render: (r) => formatMsat(r.to_us_msat)
				},
				{
					label: "Spendable",
					render: (r) => formatMsat(r.spendable_msat)
				},
				{
					label: "Receivable",
					render: (r) => formatMsat(r.receivable_msat)
				},
				{ key: "private", label: "Private" }
			],
			channels,
			"No open channels found"
		);

		return `
      <div class="admin-section-block">
        <h4>Balance</h4>
        ${balanceHtml}
      </div>
      <div class="admin-section-block">
        <h4>Existing channels</h4>
        ${channelsHtml}
      </div>
      ${renderJsonBlock("Raw channels response", data)}
    `;
	}

	function renderResultBox(el, data) {
		if (!el) return;
		el.innerHTML = `<pre class="admin-pre">${escapeHtml(JSON.stringify(data, null, 2))}</pre>`;
	}
	function renderInvoiceRows(data, emptyMessage = "No invoices found") {
		const rows = sortNewest(Array.isArray(data?.invoices) ? data.invoices : []);
		return renderTable(
			[
				{ key: "label", label: "Label" },
				{ key: "status", label: "Status" },
				{
					label: "Amount",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Received",
					render: (r) => formatMsat(r.amount_received_msat)
				},
				{
					label: "Expires",
					render: (r) => formatUnix(r.expires_at)
				},
				{ key: "created_index", label: "Created Index" },
				{
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, copyLabel: "Copy hash" })
				},
				{
					label: "Bolt11",
					render: (r) => r.bolt11
						? copyableValue(r.bolt11, { truncate: true, left: 18, right: 12, copyLabel: "Copy invoice" })
						: ""
				}
			],
			rows,
			emptyMessage
		);
	}

	function renderInvoiceCounts(data) {
		const rows = Array.isArray(data?.counts) ? data.counts : [];
		return renderTable(
			[
				{ key: "status", label: "Status" },
				{ key: "count", label: "Count" },
				{
					label: "Total amount",
					render: (r) => formatMsat(r.total_amount_msat)
				},
				{
					label: "Total received",
					render: (r) => formatMsat(r.total_received_msat)
				}
			],
			rows,
			"No invoice counts found"
		);
	}

	function renderAccountEvents(data) {
		const rows = sortNewest(Array.isArray(data?.events) ? data.events : Array.isArray(data) ? data : []);
		return renderTable(
			[
				{ key: "account", label: "Account" },
				{ key: "type", label: "Type" },
				{ key: "tag", label: "Tag" },
				{
					label: "Credit",
					render: (r) => formatMsat(r.credit_msat)
				},
				{
					label: "Debit",
					render: (r) => formatMsat(r.debit_msat)
				},
				{
					label: "Fees",
					render: (r) => formatMsat(r.fees_msat)
				},
				{ key: "currency", label: "Currency" },
				{
					label: "Timestamp",
					render: (r) => formatUnix(r.timestamp)
				},
				{ key: "description", label: "Description" },
				{ key: "origin", label: "Origin" },
				{ key: "is_rebalance", label: "Rebalance" }
			],
			rows,
			"No account events found"
		);
	}

	function renderAccountSummary(data) {
		const rows = Array.isArray(data?.summary) ? data.summary : Array.isArray(data) ? data : [];
		return renderTable(
			[
				{ key: "account", label: "Account" },
				{ key: "event_count", label: "Events" },
				{
					label: "Total credit",
					render: (r) => formatMsat(r.total_credit_msat)
				},
				{
					label: "Total debit",
					render: (r) => formatMsat(r.total_debit_msat)
				},
				{
					label: "Total fees",
					render: (r) => formatMsat(r.total_fees_msat)
				}
			],
			rows,
			"No account summary found"
		);
	}

	function renderPeerchannelSummary(data) {
		const rows = Array.isArray(data?.summary) ? data.summary : [];
		return renderTable(
			[
				{ key: "status", label: "Status" },
				{ key: "channel_count", label: "Channels" },
				{
					label: "To us",
					render: (r) => formatMsat(r.total_to_us_msat)
				},
				{
					label: "Capacity",
					render: (r) => formatMsat(r.total_capacity_msat)
				}
			],
			rows,
			"No peerchannel summary found"
		);
	}

	function getTransactionLimit() {
		const requested = getIntValue("node-transaction-limit", 50);
		return Math.min(100, Math.max(1, requested));
	}

	function updateTransactionTimestamp() {
		const el = byId("node-transactions-updated");
		if (!el || !transactionState.lastUpdated) return;
		el.textContent = `Updated ${transactionState.lastUpdated.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
	}

	function setTransactionRefreshBusy(busy) {
		const button = byId("refresh-node-transactions");
		if (!button) return;
		button.disabled = busy;
		button.textContent = busy ? "Refreshing…" : "Refresh all";
	}

	async function refreshTransactions() {
		const onchainEl = byId("node-onchain-json");
		const lightningEl = byId("node-lightning-json");
		const limit = getTransactionLimit();

		setLoading(onchainEl, "Loading Bitcoin activity…");
		setLoading(lightningEl, "Loading Lightning activity…");

		try {
			const data = await getTransactions(limit);
			transactionState.core = data;
			if (onchainEl) onchainEl.innerHTML = renderOnchain(data);
			if (lightningEl) lightningEl.innerHTML = renderLightning(data);
			renderTransactionSummary();
			return data;
		} catch (err) {
			transactionState.core = { ok: false, error: err?.message || "Unavailable" };
			setError(onchainEl, err);
			setError(lightningEl, err);
			renderTransactionSummary();
			throw err;
		}
	}

	async function refreshAeternityTransactions() {
		const el = byId("node-aeternity-json");
		const limit = getTransactionLimit();
		setLoading(el, "Loading Aeternity activity…");

		try {
			const data = await getAeternityTransactions(limit);
			transactionState.aeternity = data;
			if (el) el.innerHTML = renderAeternity(data);
			renderTransactionSummary();
			return data;
		} catch (err) {
			transactionState.aeternity = { ok: false, transactions: [], error: err?.message || "Unavailable" };
			setError(el, err);
			renderTransactionSummary();
			throw err;
		}
	}

	async function refreshAllTransactions() {
		setTransactionRefreshBusy(true);
		try {
			const results = await Promise.allSettled([
				refreshTransactions(),
				refreshAeternityTransactions()
			]);
			transactionState.lastUpdated = new Date();
			updateTransactionTimestamp();
			renderTransactionSummary();
			return results;
		} finally {
			setTransactionRefreshBusy(false);
		}
	}

	function activateTransactionTab(name, { focus = false } = {}) {
		const tabs = [...document.querySelectorAll("[data-transaction-tab]")];
		const panels = [...document.querySelectorAll("[data-transaction-panel]")];
		const selected = tabs.find((tab) => tab.dataset.transactionTab === name);
		if (!selected) return;
		for (const tab of tabs) {
			const active = tab === selected;
			tab.classList.toggle("is-active", active);
			tab.setAttribute("aria-selected", String(active));
			tab.tabIndex = active ? 0 : -1;
		}
		for (const panel of panels) {
			const active = panel.dataset.transactionPanel === name;
			panel.hidden = !active;
			panel.classList.toggle("is-active", active);
		}
		if (focus) selected.focus();
	}

	function bindTransactionTabs() {
		const tabs = [...document.querySelectorAll("[data-transaction-tab]")];
		if (!tabs.length) return;
		for (const tab of tabs) {
			tab.addEventListener("click", () => activateTransactionTab(tab.dataset.transactionTab));
			tab.addEventListener("keydown", (event) => {
				if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
				event.preventDefault();
				const index = tabs.indexOf(tab);
				let next = index;
				if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
				if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
				if (event.key === "Home") next = 0;
				if (event.key === "End") next = tabs.length - 1;
				activateTransactionTab(tabs[next].dataset.transactionTab, { focus: true });
			});
		}
	}

	async function refreshChannels() {
		const channelsEl = byId("cln-channels-json");
		setLoading(channelsEl, "Loading channels...");

		try {
			const data = await getChannels();
			if (channelsEl) channelsEl.innerHTML = renderChannels(data);
			return data;
		} catch (err) {
			setError(channelsEl, err);
			throw err;
		}
	}
	async function refreshRecentInvoices() {
	const el = byId("cln-invoices-recent-json");
	const prefix = getValue("cln-invoices-prefix", "").trim();
	const limit = getIntValue("cln-invoices-limit", 50);

	setLoading(el, "Loading recent invoices...");
	try {
		const data = await getRecentInvoices(prefix, limit);
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderInvoiceRows(data, "No recent invoices found")}
				</div>
				${renderJsonBlock("Raw recent invoices response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

async function refreshUnpaidInvoices() {
	const el = byId("cln-invoices-unpaid-json");
	const prefix = getValue("cln-unpaid-prefix", "").trim();
	const limit = getIntValue("cln-unpaid-limit", 50);

	setLoading(el, "Loading unpaid invoices...");
	try {
		const data = await getUnpaidInvoices(prefix, limit);
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderInvoiceRows(data, "No unpaid invoices found")}
				</div>
				${renderJsonBlock("Raw unpaid invoices response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

async function refreshInvoiceStatusCounts() {
	const el = byId("cln-invoice-counts-json");
	setLoading(el, "Loading invoice counts...");
	try {
		const data = await getInvoiceStatusCounts();
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderInvoiceCounts(data)}
				</div>
				${renderJsonBlock("Raw invoice counts response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

async function refreshAccountEvents() {
	const el = byId("cln-account-events-json");
	const account = getValue("cln-account-name", "").trim();
	const tag = getValue("cln-account-tag", "").trim();
	const limit = getIntValue("cln-account-events-limit", 100);

	if (!account) {
		renderResultBox(el, { ok: false, error: "Account is required" });
		return;
	}

	setLoading(el, "Loading account events...");
	try {
		const data = await getAccountEvents(account, tag, limit);
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderAccountEvents(data)}
				</div>
				${renderJsonBlock("Raw account events response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

async function refreshAccountSummary() {
	const el = byId("cln-account-summary-json");
	const account = getValue("cln-account-summary-name", "").trim();
	const tag = getValue("cln-account-summary-tag", "").trim();

	if (!account) {
		renderResultBox(el, { ok: false, error: "Account is required" });
		return;
	}

	setLoading(el, "Loading account summary...");
	try {
		const data = await getAccountSummary(account, tag);
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderAccountSummary(data)}
				</div>
				${renderJsonBlock("Raw account summary response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

async function refreshPeerchannelSummary() {
	const el = byId("cln-peerchannel-summary-json");
	setLoading(el, "Loading peerchannel summary...");
	try {
		const data = await getPeerchannelSummary();
		if (el) {
			el.innerHTML = `
				<div class="admin-section-block">
					${renderPeerchannelSummary(data)}
				</div>
				${renderJsonBlock("Raw peerchannel summary response", data)}
			`;
		}
		return data;
	} catch (err) {
		setError(el, err);
		throw err;
	}
}

	async function runBestPeerSuggestion() {
		const resultEl = byId("cln-best-peer-result");
		const targetMsat = getIntValue("cln-target-msat", 200000000);

		setLoading(resultEl, "Loading best peers...");

		try {
			const data = await getBestPeers(targetMsat);
			renderResultBox(resultEl, data);
			return data;
		} catch (err) {
			setError(resultEl, err);
			throw err;
		}
	}

	async function runConnectPeer() {
		const resultEl = byId("cln-open-peer-result");
		const peer = getValue("cln-peer-id", "").trim();

		if (!peer) {
			renderResultBox(resultEl, { ok: false, error: "Peer is required" });
			return;
		}

		setLoading(resultEl, "Connecting peer...");

		try {
			const data = await connectPeer(peer);
			renderResultBox(resultEl, data);
			return data;
		} catch (err) {
			setError(resultEl, err);
			throw err;
		}
	}

	async function runOpenChannel() {
		const resultEl = byId("cln-open-peer-result");
		const peer = getValue("cln-peer-id", "").trim();
		const amountSats = getIntValue("cln-open-amount", 200000);

		if (!peer) {
			renderResultBox(resultEl, { ok: false, error: "Peer is required" });
			return;
		}

		setLoading(resultEl, "Opening channel...");

		try {
			const data = await openChannel(peer, amountSats);
			renderResultBox(resultEl, data);
			await refreshChannels().catch(() => {});
			await refreshTransactions().catch(() => {});
			return data;
		} catch (err) {
			setError(resultEl, err);
			throw err;
		}
	}

	async function runOpenBestChannels() {
		const resultEl = byId("cln-best-peer-result");

		const payload = {
			amount_msat: getIntValue("cln-target-msat", 200000000),
			min_channel_msat: getIntValue("cln-min-channel-msat", 100000000),
			reserve_sats: getIntValue("cln-reserve-sats", 50000)
		};

		setLoading(resultEl, "Opening best channels...");

		try {
			const data = await openBestChannels(payload);
			renderResultBox(resultEl, data);
			await refreshChannels().catch(() => {});
			await refreshTransactions().catch(() => {});
			return data;
		} catch (err) {
			setError(resultEl, err);
			throw err;
		}
	}

	function bindButton(id, handler) {
		const el = byId(id);
		if (!el) return;
		el.addEventListener("click", async (event) => {
			event.preventDefault();
			try {
				await handler();
			} catch (_err) {
			}
		});
	}

	function bindCopyHandlers() {
		document.addEventListener("click", async (event) => {
			const btn = event.target.closest("[data-copy]");
			if (!btn) return;

			const value = decodeURIComponent(btn.getAttribute("data-copy") || "");
			try {
				await navigator.clipboard.writeText(value);
				const old = btn.textContent;
				btn.textContent = "Copied";
				setTimeout(() => {
					btn.textContent = old;
				}, 900);
			} catch (_err) {
				const old = btn.textContent;
				btn.textContent = "Failed";
				setTimeout(() => {
					btn.textContent = old;
				}, 900);
			}
		});
	}

	async function bindDefaultUi() {
		bindButton("refresh-node-transactions", refreshAllTransactions);
		bindButton("refresh-node-onchain", refreshTransactions);
		bindButton("refresh-node-lightning", refreshTransactions);
		bindButton("refresh-node-aeternity", refreshAeternityTransactions);
		bindButton("refresh-cln-channels", refreshChannels);
		bindButton("cln-best-peer-btn", runBestPeerSuggestion);
		bindButton("cln-connect-peer-btn", runConnectPeer);
		bindButton("cln-open-peer-btn", runOpenChannel);
		bindButton("cln-open-best-btn", runOpenBestChannels);
		bindButton("refresh-cln-invoices-recent", refreshRecentInvoices);
		bindButton("refresh-cln-invoices-unpaid", refreshUnpaidInvoices);
		bindButton("refresh-cln-invoice-counts", refreshInvoiceStatusCounts);
		bindButton("refresh-cln-account-events", refreshAccountEvents);
		bindButton("refresh-cln-account-summary", refreshAccountSummary);
		bindButton("refresh-cln-peerchannel-summary", refreshPeerchannelSummary);
		bindCopyHandlers();
		bindTransactionTabs();
		const limitSelect = byId("node-transaction-limit");
		if (limitSelect) {
			limitSelect.addEventListener("change", () => {
				refreshAllTransactions().catch(() => {});
			});
		}

		await Promise.allSettled([
			refreshAllTransactions(),
			refreshChannels(),
			refreshRecentInvoices(),
			refreshUnpaidInvoices(),
			refreshInvoiceStatusCounts(),
			refreshPeerchannelSummary()
		]);
	}

	return {
		fetchJson,
		getTransactions,
		getAeternityTransactions,
		getChannels,
		getBestPeers,
		connectPeer,
		openChannel,
		openBestChannels,
		refreshTransactions,
		refreshAeternityTransactions,
		refreshAllTransactions,
		refreshChannels,
		runBestPeerSuggestion,
		runConnectPeer,
		runOpenChannel,
		runOpenBestChannels,
		getUnpaidInvoices,
		getInvoiceStatusCounts,
		getAccountEvents,
		getAccountSummary,
		getPeerchannelSummary,
		renderOnchain,
		renderLightning,
		renderAeternity,
		refreshRecentInvoices,
		refreshUnpaidInvoices,
		refreshInvoiceStatusCounts,
		refreshAccountEvents,
		refreshAccountSummary,
		refreshPeerchannelSummary,
		bindDefaultUi
	};
})();
