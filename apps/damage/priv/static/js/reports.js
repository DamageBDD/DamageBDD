/* /static/js/reports.js
 * Modern activity list -> #run-reports-list (inside #activity-tab)
 * Supports: address display, copy, filter-by-type, limit, refresh, and pagination.
 * When "All" is selected, we fetch all account activities (no type= param),
 * and only fetch tx details for likely contract_call records to keep it fast.
 */

(function () {
	"use strict";

	const MDW_BASE = "https://mainnet.aeternity.io/mdw";
	const IPFS_FIRSTLINE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

	// ------------- tiny TTL cache -------------
	const cache = {
		get(k) {
			try {
				const raw = localStorage.getItem(k);
				if (!raw) return null;
				const { v, e } = JSON.parse(raw);
				if (e && Date.now() > e) { localStorage.removeItem(k); return null; }
				return v;
			} catch { return null; }
		},
		set(k, v, ttlMs) {
			try {
				localStorage.setItem(k, JSON.stringify({ v, e: ttlMs ? Date.now() + ttlMs : null }));
			} catch {}
		}
	};

	// ------------- utils -------------
	const qs = (sel, root=document) => root.querySelector(sel);
	const el = (tag, attrs={}, html="") => {
		const e = document.createElement(tag);
		Object.entries(attrs).forEach(([k,v])=>{
			if (k==="style" && v && typeof v==="object") Object.assign(e.style, v);
			else e.setAttribute(k,v);
		});
		if (html) e.innerHTML = html;
		return e;
	};
	const fmtDate = ms => (!ms ? "—" : new Date(ms).toLocaleString());

	function prettyType(t){
		const v = (t || "").toLowerCase();
		if (v === "aex9") return "AEX-9";
		if (v === "aex141") return "AEX-141";
		if (v === "contract_call") return "Contract";
		if (v === "transactions") return "Tx";
		if (!v) return "Activity";
		return v.replace(/_/g, " ");
	}

	function safeText(s){
		return String(s ?? "").replace(/[&<>\"']/g, (c) => ({
			"&": "&amp;",
			"<": "&lt;",
			">": "&gt;",
			'"': "&quot;",
			"'": "&#39;"
		}[c]));
	}

	async function fetchJSON(url, { retries=2, backoff=300 } = {}) {
		for (let i=0;;i++){
			try{
				const res = await fetch(url, {
					method: "GET",
					cache: "no-store",
					headers: {
						Accept: "application/json",
						"Cache-Control": "no-cache, no-store, max-age=0, must-revalidate",
						Pragma: "no-cache",
						Expires: "0"
					}
				});
				if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
				return await res.json();
			} catch (e){
				if (i>=retries) throw e;
				await new Promise(r=>setTimeout(r, backoff*(i+1)));
			}
		}
	}

	async function fetchTEXT(url, { retries=1, backoff=250 } = {}) {
		for (let i=0;;i++){
			try{
				const res = await fetch(url, {
					method: "GET",
					cache: "no-store",
					headers: { "Cache-Control": "no-cache, no-store, max-age=0, must-revalidate" }
				});
				if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
				return await res.text();
			} catch (e){
				if (i>=retries) throw e;
				await new Promise(r=>setTimeout(r, backoff*(i+1)));
			}
		}
	}

	async function pMap(items, fn, { concurrency=3 } = {}) {
		const ret=[], inflight=new Set();
		for (const it of items){
			const p=Promise.resolve().then(()=>fn(it));
			ret.push(p); inflight.add(p);
			const done=()=>inflight.delete(p); p.then(done,done);
			if (inflight.size>=concurrency) await Promise.race(inflight);
		}
		return Promise.all(ret);
	}

	function deepFindCall(node){
		if (node && typeof node==="object"){
			if ("arguments" in node) return node;
			for (const k of Object.keys(node)){
				const f=deepFindCall(node[k]); if (f) return f;
			}
		}
		return null;
	}

	function isIpfsCid(str){
		if (typeof str!=="string") return false;
		const v0=/^Qm[1-9A-HJ-NP-Za-km-z]{44}$/;   // base58
		const v1=/^baf[0-9a-z]{20,}$/i;            // base32
		return v0.test(str) || v1.test(str);
	}

	const aescanTxUrl = (txHash) => `https://aescan.io/transactions/${encodeURIComponent(txHash)}`;

	// ------------- data -------------
	async function getAccountActivities({ accountId, limit=10, type="all", bypassCache=false, ttlMs=60_000, pagePath=null } = {}) {
		// Support either constructed URL or server-provided cursor path
		const key = pagePath
			  ? `ae:act:url:${pagePath}`
			  : `ae:act:${accountId}:${type}:backward:${limit}`;
		if (!bypassCache){
			const c=cache.get(key); if (c) return c;
		}
		const url = pagePath
			  ? `${MDW_BASE}${pagePath}`
			  : `${MDW_BASE}/v3/accounts/${encodeURIComponent(accountId)}/activities?direction=backward${type && type !== "all" ? `&type=${encodeURIComponent(type)}` : ""}&limit=${encodeURIComponent(limit)}`;
		const page = await fetchJSON(url);
		cache.set(key, page, ttlMs);
		return page;
	}
	function normalizeTxContent(tx) {
		const rows = [];

		// AEX-9 Transfer
		if (tx.type === "Aex9TransferEvent" || tx.payload?.type === "Aex9TransferEvent") {
			const p = tx.payload ?? tx;
			rows.push(
				{ k: "Token", v: p.token_symbol || "AEX-9" },
				{ k: "Amount", v: (p.payload?.amount ?? p.amount) / 10 ** (p.payload?.decimals ?? 0) },
				{ k: "From", v: p.sender_id },
				{ k: "To", v: p.recipient_id }
			);
			return rows;
		}

		// Contract call
		if (tx.type === "ContractCallTx" || tx.contract_id) {
			rows.push(
				{ k: "Contract", v: tx.contract_id },
				{ k: "Function", v: tx.function || "call" }
			);

			if (Array.isArray(tx.arguments)) {
				tx.arguments.forEach((arg, i) => {
					rows.push({ k: `arg[${i}]`, v: JSON.stringify(arg.value ?? arg) });
				});
			}

			return rows;
		}

		// Fallback
		rows.push(
			{ k: "Type", v: tx.type },
			{ k: "Block", v: tx.block_height },
			{ k: "Tx", v: tx.hash }
		);

		return rows;
	}


	async function getTxDetail(txHash, { bypassCache=false, ttlMs=3600_000 } = {}) {
		const key = `ae:mdwtx:${txHash}`;
		if (!bypassCache){
			const c=cache.get(key); if (c) return c;
		}
		const url = `${MDW_BASE}/v3/transactions/${encodeURIComponent(txHash)}`;
		const data = await fetchJSON(url);
		const call = deepFindCall(data);
		const args = Array.isArray(call?.arguments) ? call.arguments : [];
		const normalized = {
			tx_hash: data.hash || txHash,
			micro_time: data.micro_time ?? null,
			// Contract convention: args[2] = feature CID, args[3] = report CID
			featureCid: isIpfsCid(args[2]?.value) ? args[2].value : null,
			reportCid:  isIpfsCid(args[3]?.value) ? args[3].value : null
		};
		cache.set(key, normalized, ttlMs);
		return normalized;
	}

	async function getFeatureFirstLine(cid){
		if (!cid) return "—";
		const k = `ipfs:firstline:${cid}`;
		const cached = cache.get(k);
		if (cached) return cached;

		// Your app should serve raw feature text at this route
		const url = `/features/${encodeURIComponent(cid)}`;
		try {
			const text = await fetchTEXT(url);
			const firstLine = (text || "").split(/\r?\n/)[0] || "—";
			cache.set(k, firstLine, IPFS_FIRSTLINE_TTL_MS);
			return firstLine;
		} catch {
			cache.set(k, cid, 5 * 60 * 1000);
			return cid;
		}
	}

	// ------------- rendering + pagination -------------
	const state = {
		accountId: null,
		limit: 10,
		type: "all",
		bypassCache: false,
		pagePath: null,
		nextPath: null,
		prevPath: null
	};

	function ensureScaffold() {
		const container = qs("#activity-tab");
		if (!container) return null;

		// Address display
		const acctNode = qs("#activity-account", container);
		if (acctNode) acctNode.textContent = state.accountId || "—";

		// Copy address
		const copyBtn = qs("#activity-copy", container);
		if (copyBtn && !copyBtn.dataset.bound){
			copyBtn.dataset.bound = "1";
			copyBtn.addEventListener("click", async () => {
				try{
					await navigator.clipboard.writeText(state.accountId || "");
					copyBtn.textContent = "✓";
					setTimeout(()=>{ copyBtn.textContent = "⧉"; }, 800);
				} catch {}
			});
		}

		// Filter
		const typeSel = qs("#activity-type", container);
		if (typeSel) {
			typeSel.value = state.type;
			if (!typeSel.dataset.bound){
				typeSel.dataset.bound = "1";
				typeSel.addEventListener("change", () => {
					state.type = typeSel.value || "all";
					state.pagePath = null;
					renderPage();
				});
			}
		}

		// Limit
		const limitSel = qs("#activity-limit", container);
		if (limitSel) {
			limitSel.value = String(state.limit);
			if (!limitSel.dataset.bound){
				limitSel.dataset.bound = "1";
				limitSel.addEventListener("change", () => {
					const n = parseInt(limitSel.value, 10);
					state.limit = Number.isFinite(n) ? n : 10;
					state.pagePath = null;
					renderPage();
				});
			}
		}

		// Refresh
		const refreshBtn = qs("#activity-refresh", container);
		if (refreshBtn && !refreshBtn.dataset.bound){
			refreshBtn.dataset.bound = "1";
			refreshBtn.addEventListener("click", () => {
				state.bypassCache = true;
				state.pagePath = null;
				renderPage().finally(()=>{ state.bypassCache = false; });
			});
		}

		// List
		let ul = qs("#run-reports-list", container);
		if (!ul) {
			ul = el("ul", { id: "run-reports-list", class: "activity-list" });
			container.appendChild(ul);
		}

		// Pager
		let pager = qs("#run-reports-pager", container);
		if (!pager) {
			pager = el("div", { id: "run-reports-pager", class: "activity-pager" });
			const btnPrev = el("button", { id: "run-reports-prev", type: "button", class: "activity-btn" }, "◀ Prev");
			const btnNext = el("button", { id: "run-reports-next", type: "button", class: "activity-btn" }, "Next ▶");
			const spanInfo = el("span", { id: "run-reports-info", class: "activity-pagerinfo" }, "");
			pager.appendChild(btnPrev);
			pager.appendChild(btnNext);
			pager.appendChild(spanInfo);
			container.appendChild(pager);
		}

		const btnPrev = qs("#run-reports-prev", container);
		const btnNext = qs("#run-reports-next", container);
		if (btnPrev && !btnPrev.dataset.bound){
			btnPrev.dataset.bound = "1";
			btnPrev.addEventListener("click", () => {
				if (!state.prevPath) return;
				state.pagePath = state.prevPath;
				renderPage();
			});
		}
		if (btnNext && !btnNext.dataset.bound){
			btnNext.dataset.bound = "1";
			btnNext.addEventListener("click", () => {
				if (!state.nextPath) return;
				state.pagePath = state.nextPath;
				renderPage();
			});
		}

		return { container, ul, pager };
	}

	function setPagerEnabled() {
		const btnPrev = qs("#run-reports-prev");
		const btnNext = qs("#run-reports-next");
		const spanInfo = qs("#run-reports-info");

		if (btnPrev) btnPrev.disabled = !state.prevPath;
		if (btnNext) btnNext.disabled = !state.nextPath;

		if (spanInfo) {
			spanInfo.textContent = `Showing ${state.limit} • ${state.type === "all" ? "All" : prettyType(state.type)} • newest first`;
		}
	}
	function isTruthyArray(x){ return Array.isArray(x) && x.length > 0; }
	function isIpfsCid(str){
		if (typeof str !== "string") return false;
		const v0 = /^Qm[1-9A-HJ-NP-Za-km-z]{44}$/;   // base58
		const v1 = /^baf[0-9a-z]{20,}$/i;            // base32
		return v0.test(str) || v1.test(str);
	}

	function extractCallInfo(txFull){
		// MDW shape (as in your screenshot): { hash, ... , tx: { function, arguments, contract_id, caller_id, ... } }
		const inner = txFull?.tx || txFull?.payload?.tx || null;
		if (!inner) return null;

		const fn = inner.function || "call";
		const args = Array.isArray(inner.arguments) ? inner.arguments : [];
		return {
			function: fn,
			contract_id: inner.contract_id,
			caller_id: inner.caller_id,
			aexn_type: inner.aexn_type,
			arguments: args
		};
	}

	async function fetchTextFirstLine(url, cacheKey, ttlMs) {
		const cached = cache.get(cacheKey);
		if (cached) return cached;
		const text = await fetchTEXT(url);
		const firstLine = (text || "").split(/\r?\n/)[0] || "—";
		cache.set(cacheKey, firstLine, ttlMs);
		return firstLine;
	}

	async function fetchFeaturePreview(cid) {
		if (!cid) return null;
		return fetchTextFirstLine(
			`/features/${encodeURIComponent(cid)}`,
			`ipfs:firstline:feature:${cid}`,
			7 * 24 * 60 * 60 * 1000
		);
	}

	async function fetchReportPreview(cid) {
		if (!cid) return null;
		return fetchTextFirstLine(
			`/reports/${encodeURIComponent(cid)}`,
			`ipfs:firstline:report:${cid}`,
			7 * 24 * 60 * 60 * 1000
		);
	}
	function extractTxArguments(txFull) {
		// Exact nesting you showed:
		// txFull.tx.tx.tx.arguments
		const args =
			  txFull?.tx?.tx?.tx?.arguments ||
			  txFull?.tx?.tx?.arguments ||      // fallback (older MDW shapes)
			  txFull?.tx?.arguments ||
			  [];

		return Array.isArray(args) ? args : [];
	}

	async function normalizeTxContent(txFull) {
		const rows = [];

		// Identify contract call
		const inner =
			  txFull?.tx?.tx?.tx ||
			  txFull?.tx?.tx ||
			  txFull?.tx ||
			  null;

		if (!inner) {
			rows.push(
				{ k: "Type", v: txFull?.type || "—" },
				{ k: "Tx", v: txFull?.hash || "—" }
			);
			return rows;
		}

		const fn = inner.function || "call";
		const contractId = inner.contract_id;
		const callerId = inner.caller_id;

		rows.push(
			{ k: "Type", v: "Contract Call" },
			{ k: "Function", v: fn },
			{ k: "Contract", v: contractId || "—" },
			{ k: "Caller", v: callerId || "—" }
		);

		// 🔑 Extract arguments (correct path)
		const args = extractTxArguments(txFull);

		args.forEach((a, i) => {
			rows.push({ k: `arg[${i}]`, v: a?.value ?? "—" });
		});

		// 🔐 DAMAGE spend ABI (based on your screenshot)
		// arg0 = recipient (address)
		// arg1 = amount (int)
		// arg2 = feature CID (string)
		// arg3 = report CID (string)

		const featureCid = typeof args[2]?.value === "string" ? args[2].value : null;
		const reportCid  = typeof args[3]?.value === "string" ? args[3].value : null;

		if (featureCid) {
			const featureLine = await fetchFeaturePreview(featureCid).catch(() => "—");
			rows.push({ k: "Feature CID", v: featureCid });
			rows.push({ k: "Feature", v: featureLine });
		}

		if (reportCid) {
			const reportLine = await fetchReportPreview(reportCid).catch(() => "—");
			rows.push({ k: "Report CID", v: reportCid });
			rows.push({ k: "Report", v: reportLine });
		}

		return rows;
	}





	async function renderPage() {
		const parts = ensureScaffold();
		if (!parts) { console.warn("reports.js: #activity-tab not found"); return; }
		const { ul } = parts;

		ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">Loading…</div></div></li>`;
		setPagerEnabled();

		const page = await getAccountActivities({
			accountId: state.accountId,
			limit: state.limit,
			type: state.type,
			bypassCache: state.bypassCache,
			pagePath: state.pagePath
		});

		state.nextPath = page?.next || null;
		state.prevPath = page?.prev || null;
		setPagerEnabled();

		const items = Array.isArray(page?.data) ? page.data.slice(0, state.limit) : [];

		// Base rows (fast)
		const baseRows = items.map((it) => {
			const rawType = it?.type || it?.payload?.type || it?.payload?.tx?.type || "activity";
			const txHash = it?.payload?.tx_hash || null;
			const time = it?.payload?.micro_time || null;
			return { time, type: rawType, txHash, featureCid: null, reportCid: null, firstLine: null };
		});

		// Enrich only when it looks like our contract-call based record (feature/report links)
		const interesting = (row) => {
			if (!row?.txHash) return false;
			const t = String(row.type || "").toLowerCase();
			if (state.type === "aex9" || state.type === "contract_call") return true;
			return t === "contract_call" || t === "contract";
		};

		const toEnrich = baseRows.filter(interesting).map(r => r.txHash);
		const detailList = await pMap(
			toEnrich,
			h => getTxDetail(h, { bypassCache: state.bypassCache }).catch(() => null),
			{ concurrency: 3 }
		);
		const detailByHash = new Map(detailList.filter(Boolean).map(d => [d.tx_hash, d]));

		const rows = await pMap(baseRows.map((r)=>({ r })), async ({ r }) => {
			const d = r.txHash ? detailByHash.get(r.txHash) : null;
			if (d){
				r.time = r.time || d.micro_time;
				r.featureCid = d.featureCid;
				r.reportCid = d.reportCid;
				if (r.featureCid) r.firstLine = await getFeatureFirstLine(r.featureCid);
			}
			return r;
		}, { concurrency: 3 });

		if (rows.length === 0){
			ul.innerHTML = `<li class="activity-item"><div class="activity-main"><div class="activity-title">No activity found.</div></div></li>`;
			return;
		}
		ul.innerHTML = "";

		// Prefetch tx details for all rows in the list (shown page only)
		const rowsWithDetails = await pMap(
			rows.filter(Boolean).map((r) => ({ r })),
			async ({ r }) => {
				if (!r.txHash) return r;
				try {
					const txFull = await fetchTxDetails(r.txHash);
					r.detailRows = await normalizeTxContent(txFull); // async; fetches feature/report previews too
				} catch (e) {
					r.detailRows = [{ k: "Details", v: "Failed to fetch transaction details" }];
				}
				return r;
			},
			{ concurrency: 3 }
		);

		rowsWithDetails.forEach(row => {
			const li = el("li", { class: "activity-item" });

			const left = el("div", { class: "activity-left" });
			left.appendChild(el("div", { class: "activity-time" }, safeText(fmtDate(row.time))));
			left.appendChild(el("div", { class: "activity-badge" }, safeText(prettyType(row.type))));

			const main = el("div", { class: "activity-main" });
			const title = row.featureCid ? row.firstLine : (row.txHash ? row.txHash : "Activity");
			main.appendChild(el("div", { class: "activity-title" }, safeText(title)));

			const meta = el("div", { class: "activity-meta" });
			if (row.featureCid) {
				meta.appendChild(el("a", { class: "activity-link", href: `/features/${encodeURIComponent(row.featureCid)}`, target: "_blank", rel: "noopener" }, "feature"));
			}
			if (row.reportCid) {
				meta.appendChild(el("a", { class: "activity-link", href: `/reports/${encodeURIComponent(row.reportCid)}`, target: "_blank", rel: "noopener" }, "report"));
			}
			if (row.txHash) {
				meta.appendChild(el("a", { class: "activity-link", href: aescanTxUrl(row.txHash), target: "_blank", rel: "noopener" }, "aescan"));
			}
			main.appendChild(meta);

			// ✅ Render details by default (no toggle)
			if (row.txHash) {
				const detailsWrap = el("div", { class: "activity-details" });
				const body = el("div", { class: "activity-details-body open" });

				// If details not ready, show loading (should be rare because we prefetched)
				if (!isTruthyArray(row.detailRows)) {
					body.innerHTML = `<div class="activity-details-loading">Loading transaction details…</div>`;
				} else {
					renderTxDetailsInto(body, row.detailRows);

					// Add quick links if Feature/Report CIDs were extracted from ABI args
					const featureCid = row.detailRows.find(r => r.k === "Feature CID")?.v;
					const reportCid  = row.detailRows.find(r => r.k === "Report CID")?.v;

					if (featureCid || reportCid) {
						const links = el("div", { class: "activity-meta" });
						if (featureCid) {
							links.appendChild(el("a", { class: "activity-link", href: `/features/${encodeURIComponent(featureCid)}`, target: "_blank", rel: "noopener" }, "open feature"));
						}
						if (reportCid) {
							links.appendChild(el("a", { class: "activity-link", href: `/reports/${encodeURIComponent(reportCid)}`, target: "_blank", rel: "noopener" }, "open report"));
						}
						body.appendChild(links);
					}
				}

				detailsWrap.appendChild(body);
				main.appendChild(detailsWrap);
			}

			li.appendChild(left);
			li.appendChild(main);
			ul.appendChild(li);
		});


	}


	async function fetchTxDetails(txHash) {
		const cacheKey = `ae:tx:${txHash}`;
		const cached = cache.get(cacheKey);
		if (cached) return cached;

		const url = `${MDW_BASE}/v3/transactions/${txHash}`;
		const data = await fetchJSON(url);

		cache.set(cacheKey, data, 5 * 60 * 1000); // 5 min
		return data;
	}

	function renderTxDetailsInto(containerEl, rows) {
		const table = document.createElement("div");
		table.className = "activity-tx-table";

		rows.forEach(({ k, v }) => {
			const row = document.createElement("div");
			row.className = "activity-tx-row";

			const keyEl = document.createElement("span");
			keyEl.className = "tx-key";
			keyEl.textContent = k;

			const valEl = document.createElement("span");
			valEl.className = "tx-value";
			valEl.textContent = v === undefined || v === null ? "—" : String(v);

			row.appendChild(keyEl);
			row.appendChild(valEl);
			table.appendChild(row);
		});

		containerEl.appendChild(table);
	}


	// ------------- public API -------------
	async function renderRunReports(accountId, { limit=10, type="all", bypassCache=false } = {}) {
		state.accountId = accountId;
		state.limit = limit;
		state.type = type;
		state.bypassCache = bypassCache;
		state.pagePath = null;
		await renderPage();
	}

	window.Reports = { renderRunReports };

	document.addEventListener("DOMContentLoaded", () => {
		const acct = window.TokenManager?.getAddress?.();
		if (acct) renderRunReports(acct, { limit: 10, type: "all", bypassCache: true });
	});
})();

