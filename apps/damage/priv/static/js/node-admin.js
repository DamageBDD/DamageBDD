// /static/js/node_admin.js
// DamageBDD node admin HTTP wrapper + rich table rendering

window.nodeAdmin = (() => {
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
		const payload = {
			ok: false,
			error: err?.message || "Unknown error",
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

	async function getTransactions() {
		return fetchJson("/api/node_admin/transactions");
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

	function amountWithTooltip(mainText, tooltip) {
		return `<span class="admin-amount" title="${escapeHtml(tooltip)}">${escapeHtml(mainText)}</span>`;
	}

	function formatMsat(value) {
		if (value === null || value === undefined || value === "") return "";
		const str = String(value).replace(/msat$/i, "");
		const n = Number(str);
		if (!Number.isFinite(n)) return String(value);

		const sats = n / 1000;
		const btc = btcFromSats(sats);
		const satsText = `${sats.toLocaleString(undefined, { maximumFractionDigits: 3 })} sats`;
		const tip = `${btc} BTC`;
		return amountWithTooltip(satsText, tip);
	}

	function formatSats(value) {
		if (value === null || value === undefined || value === "") return "";
		const n = Number(value);
		if (!Number.isFinite(n)) return String(value);

		const satsText = `${n.toLocaleString()} sats`;
		const tip = `${btcFromSats(n)} BTC`;
		return amountWithTooltip(satsText, tip);
	}

	function formatUnix(value) {
		if (value === null || value === undefined || value === "") return "";
		const n = Number(value);
		if (!Number.isFinite(n)) return String(value);
		const d = new Date(n * 1000);
		if (Number.isNaN(d.getTime())) return String(value);
		return `${d.toLocaleString()} (${n})`;
	}

	function formatDateish(value) {
		if (value === null || value === undefined || value === "") return "";
		if (typeof value === "number") return formatUnix(value);

		const n = Number(value);
		if (Number.isFinite(n) && String(value).length >= 9) {
			return formatUnix(n);
		}

		const d = new Date(value);
		if (!Number.isNaN(d.getTime())) {
			return `${d.toLocaleString()} (${value})`;
		}

		return String(value);
	}

	function truncateMiddle(value, left = 12, right = 10) {
		const s = String(value ?? "");
		if (s.length <= left + right + 3) return s;
		return `${s.slice(0, left)}…${s.slice(-right)}`;
	}

	function copyButton(value, label = "Copy") {
		const encoded = encodeURIComponent(String(value ?? ""));
		return `<button type="button" class="pure-button admin-copy-btn" data-copy="${encoded}" title="${escapeHtml(label)}">${escapeHtml(label)}</button>`;
	}

	function copyableValue(value, opts = {}) {
		const full = String(value ?? "");
		const display = opts.truncate ? truncateMiddle(full, opts.left ?? 12, opts.right ?? 10) : full;
		return `
      <div class="admin-copy-cell">
        <code class="admin-code" title="${escapeHtml(full)}">${escapeHtml(display)}</code>
        ${copyButton(full, opts.copyLabel || "Copy")}
      </div>
    `;
	}

	function formatValue(value) {
		if (value === null || value === undefined) return "";
		if (typeof value === "object") return `<code class="admin-code">${escapeHtml(JSON.stringify(value))}</code>`;
		return escapeHtml(String(value));
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
			"created_index",
			"updated_index",
			"created_at",
			"paid_at",
			"received_at",
			"updated_at",
			"timestamp",
			"blockheight"
		];

		for (const key of keys) {
			const av = toSortNumber(a?.[key]);
			const bv = toSortNumber(b?.[key]);

			if (av !== null || bv !== null) {
				return (bv ?? -Infinity) - (av ?? -Infinity);
			}
		}

		const aId = String(a?.channel_id || a?.txid || a?.payment_hash || a?.label || "");
		const bId = String(b?.channel_id || b?.txid || b?.payment_hash || b?.label || "");
		return bId.localeCompare(aId);
	}

	function sortNewest(rows) {
		return [...(rows || [])].sort(compareNewestFirst);
	}

	function renderTable(columns, rows, emptyMessage = "No data") {
		if (!Array.isArray(rows) || rows.length === 0) {
			return `<div class="admin-empty">${escapeHtml(emptyMessage)}</div>`;
		}

		const thead = `
      <thead>
        <tr>
          ${columns.map((c) => `<th>${escapeHtml(c.label)}</th>`).join("")}
        </tr>
      </thead>
    `;

		const tbody = `
      <tbody>
        ${rows.map((row) => `
			  <tr>
              ${columns.map((c) => {
				  const raw = c.render ? c.render(row) : formatValue(row[c.key]);
				  return `<td>${raw}</td>`;
              }).join("")}
        </tr>
			`).join("")}
      </tbody>
    `;

		return `<div class="admin-table-wrap"><table class="admin-table">${thead}${tbody}</table></div>`;
	}

	function renderJsonBlock(title, data) {
		return `
      <details class="admin-details">
        <summary>${escapeHtml(title)}</summary>
        <pre class="admin-pre">${escapeHtml(JSON.stringify(data ?? {}, null, 2))}</pre>
      </details>
    `;
	}

	function renderOnchain(data) {
		const onchain = data?.onchain || {};
		const outputs = sortNewest(Array.isArray(onchain.outputs) ? onchain.outputs : []);
		const channels = sortNewest(Array.isArray(onchain.channels) ? onchain.channels : []);

		const outputsHtml = renderTable(
			[
				{
					label: "Txid",
					render: (r) => copyableValue(r.txid, { truncate: true, copyLabel: "Copy txid" })
				},
				{ key: "output", label: "Vout" },
				{
					label: "Amount",
					render: (r) => formatMsat(r.amount_msat)
				},
				{ key: "status", label: "Status" },
				{
					label: "Address",
					render: (r) => r.address ? copyableValue(r.address, { truncate: true, copyLabel: "Copy addr" }) : ""
				},
				{ key: "scriptpubkey_type", label: "Type" },
				{ key: "reserved", label: "Reserved" },
				{ key: "blockheight", label: "Block" }
			],
			outputs,
			"No on-chain outputs found"
		);

		const channelsHtml = renderTable(
			[
				{
					label: "Peer",
					render: (r) => copyableValue(r.peer_id, { truncate: true, copyLabel: "Copy peer" })
				},
				{
					label: "Channel ID",
					render: (r) => copyableValue(r.channel_id, { truncate: true, copyLabel: "Copy chan" })
				},
				{ key: "short_channel_id", label: "Short Channel ID" },
				{ key: "state", label: "State" },
				{
					label: "Capacity",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Our amount",
					render: (r) => formatMsat(r.our_amount_msat)
				},
				{
					label: "Funding txid",
					render: (r) => copyableValue(r.funding_txid, { truncate: true, copyLabel: "Copy txid" })
				},
				{ key: "connected", label: "Connected" }
			],
			channels,
			"No channel funding records found"
		);

		return `
      <div class="admin-section-block">
        <h4>On-chain outputs</h4>
        ${outputsHtml}
      </div>
      <div class="admin-section-block">
        <h4>Channel funding records</h4>
        ${channelsHtml}
      </div>
      ${renderJsonBlock("Raw on-chain response", onchain)}
    `;
	}

	function renderLightning(data) {
		const lightning = data?.lightning || {};
		const pays = sortNewest(Array.isArray(lightning?.pays?.pays) ? lightning.pays.pays : []);
		const sendpays = sortNewest(Array.isArray(lightning?.sendpays?.payments) ? lightning.sendpays.payments : []);
		const invoices = sortNewest(Array.isArray(lightning?.invoices?.invoices) ? lightning.invoices.invoices : []);

		const invoicesHtml = renderTable(
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
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, copyLabel: "Copy hash" })
				},
				{
					label: "Bolt11",
					render: (r) => copyableValue(r.bolt11, { truncate: true, left: 18, right: 12, copyLabel: "Copy invoice" })
				},
				{
					label: "Created",
					render: (r) => r.created_at ? formatDateish(r.created_at) : (r.created_index ?? "")
				}
			],
			invoices,
			"No invoices found"
		);

		const paysHtml = renderTable(
			[
				{ key: "status", label: "Status" },
				{
					label: "Amount",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Sent",
					render: (r) => formatMsat(r.amount_sent_msat)
				},
				{
					label: "Destination",
					render: (r) => r.destination ? copyableValue(r.destination, { truncate: true, copyLabel: "Copy dest" }) : ""
				},
				{
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, copyLabel: "Copy hash" })
				},
				{
					label: "Bolt11",
					render: (r) => r.bolt11 ? copyableValue(r.bolt11, { truncate: true, left: 18, right: 12, copyLabel: "Copy invoice" }) : ""
				}
			],
			pays,
			"No pays found"
		);

		const sendpaysHtml = renderTable(
			[
				{ key: "status", label: "Status" },
				{
					label: "Amount",
					render: (r) => formatMsat(r.amount_msat)
				},
				{
					label: "Sent",
					render: (r) => formatMsat(r.amount_sent_msat)
				},
				{
					label: "Destination",
					render: (r) => r.destination ? copyableValue(r.destination, { truncate: true, copyLabel: "Copy dest" }) : ""
				},
				{
					label: "Payment hash",
					render: (r) => copyableValue(r.payment_hash, { truncate: true, copyLabel: "Copy hash" })
				},
				{
					label: "Created",
					render: (r) => r.created_at ? formatUnix(r.created_at) : ""
				}
			],
			sendpays,
			"No sent payments found"
		);

		return `
      <div class="admin-section-block">
        <h4>Invoices</h4>
        ${invoicesHtml}
      </div>
      <div class="admin-section-block">
        <h4>Pays</h4>
        ${paysHtml}
      </div>
      <div class="admin-section-block">
        <h4>Sendpays</h4>
        ${sendpaysHtml}
      </div>
      ${renderJsonBlock("Raw lightning response", lightning)}
    `;
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

	async function refreshTransactions() {
		const onchainEl = byId("node-onchain-json");
		const lightningEl = byId("node-lightning-json");

		setLoading(onchainEl, "Loading on-chain...");
		setLoading(lightningEl, "Loading lightning...");

		try {
			const data = await getTransactions();
			if (onchainEl) onchainEl.innerHTML = renderOnchain(data);
			if (lightningEl) lightningEl.innerHTML = renderLightning(data);
			return data;
		} catch (err) {
			setError(onchainEl, err);
			setError(lightningEl, err);
			throw err;
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
		bindButton("refresh-node-onchain", refreshTransactions);
		bindButton("refresh-node-lightning", refreshTransactions);
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

		await Promise.allSettled([
			refreshTransactions(),
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
		getChannels,
		getBestPeers,
		connectPeer,
		openChannel,
		openBestChannels,
		refreshTransactions,
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
		refreshRecentInvoices,
		refreshUnpaidInvoices,
		refreshInvoiceStatusCounts,
		refreshAccountEvents,
		refreshAccountSummary,
		refreshPeerchannelSummary,
		bindDefaultUi
	};
})();
