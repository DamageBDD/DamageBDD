// schedules.js (MERGED)
//
// Merged from:
// - damage-scheduler-ui.js (scheduler form + schedule-spec generator + auto-init)
// - schedules.js (schedules table renderer)
// Plus:
// - IPFS-firstline fetch/cache mechanism for feature title preview (first line)
//
// NOTE: This module assumes TokenManager and MicroModal exist globally (as your original schedules.js did).
// If they don't, it will still work with localStorage.access_token fallback.

//////////////////////////////
// Auth + headers
//////////////////////////////

function getAccessToken() {
	try {
		if (typeof TokenManager !== "undefined" && TokenManager.getToken) {
			return TokenManager.getToken();
		}
	} catch (_) {}
	return localStorage.access_token || null;
}

function buildJsonAuthHeaders(token) {
	const headers = new Headers();
	headers.set("Content-Type", "application/json");
	if (token) {
		headers.set("Authorization", "Bearer " + token);
	}
	return headers;
}

//////////////////////////////
// Tiny TTL cache + text fetch
// (same style/pattern as reports.js / previous update)
//////////////////////////////

const IPFS_FIRSTLINE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const FirstLineCache = {
	get(k) {
		try {
			const raw = localStorage.getItem(k);
			if (!raw) return null;
			const { v, e } = JSON.parse(raw);
			if (e && Date.now() > e) {
				localStorage.removeItem(k);
				return null;
			}
			return v;
		} catch {
			return null;
		}
	},
	set(k, v, ttlMs) {
		try {
			localStorage.setItem(
				k,
				JSON.stringify({
					v,
					e: ttlMs ? Date.now() + ttlMs : null
				})
			);
		} catch {}
	}
};

async function fetchTEXT(url, { headers, retries = 1, backoff = 250 } = {}) {
	for (let i = 0; ; i++) {
		try {
			const res = await fetch(url, {
				method: "GET",
				cache: "no-store",
				credentials: "include",
				headers
			});
			if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
			return await res.text();
		} catch (e) {
			if (i >= retries) throw e;
			await new Promise((r) => setTimeout(r, backoff * (i + 1)));
		}
	}
}

async function fetchTextFirstLine(url, cacheKey, ttlMs, headers) {
	const cached = FirstLineCache.get(cacheKey);
	if (cached) return cached;

	const text = await fetchTEXT(url, { headers });
	const firstLine = (text || "").split(/\r?\n/)[0] || "—";
	FirstLineCache.set(cacheKey, firstLine, ttlMs);
	return firstLine;
}

async function fetchFeatureFirstLine(featureHash, headers) {
	if (!featureHash) return "—";
	const cid = String(featureHash).trim();
	const cacheKey = `ipfs:firstline:feature:${cid}`;
	return fetchTextFirstLine(`/features/${encodeURIComponent(cid)}`, cacheKey, IPFS_FIRSTLINE_TTL_MS, headers)
		.catch(() => cid);
}

//////////////////////////////
// Schedules table
//////////////////////////////

function formatCell(obj, cell, value, type) {
	if (type === "start_time" || type === "end_time") {
		const date = new Date(value * 1000);
		const today = new Date();
		if (date.toDateString() === today.toDateString()) {
			cell.textContent = date.toLocaleTimeString();
		} else {
			cell.textContent = date.toLocaleString();
		}
		return cell;
	}

	if (type === "execution_time") {
		cell.textContent = `${value} seconds`;
		return cell;
	}

	if (type === "feature_title") {
		// This will be set asynchronously (first-line from /features/<hash>)
		// but we still render a link placeholder now.
		const link = document.createElement("a");
		link.href = obj && obj.hash ? `/features/${obj.hash}` : "#";
		link.textContent = value || "…";
		link.target = "_blank";
		cell.appendChild(link);
		cell.className = "feature_title";
		return cell;
	}

	if (type === "feature_hash") {
		const link = document.createElement("a");
		link.href = `/features/${value}`;
		link.textContent = value;
		link.target = "_blank";
		cell.appendChild(link);
		cell.className = "hash";
		return cell;
	}

	if (type === "hash") {
		const link = document.createElement("a");
		link.href = `/features/${value}`;
		link.textContent = value;
		link.target = "_blank";
		cell.appendChild(link);
		cell.className = "hash";
		return cell;
	}

	if (type === "contract_address") {
		const link = document.createElement("a");
		link.href = `https://www.aeknow.org/index.php/contract/detail/${value}`;
		link.textContent = value;
		link.target = "_blank";
		cell.appendChild(link);
		cell.className = "hash";
		return cell;
	}

	if (type === "delete") {
		const link = document.createElement("a");
		link.href = "#";
		link.textContent = "delete";
		link.className = "hash";
		link.addEventListener("click", (e) => {
			e.preventDefault();
			deleteSchedule(obj && obj.hash);
		});
		cell.appendChild(link);
		return cell;
	}

	if (type === "clone") {
		const link = document.createElement("a");
		link.href = "#";
		link.textContent = "clone";
		link.className = "hash";
		link.addEventListener("click", (e) => {
			e.preventDefault();
			cloneSchedule(obj && obj.hash);
		});
		cell.appendChild(link);
		return cell;
	}

	cell.textContent = value ?? "";
	return cell;
}

async function deleteSchedule(hash) {
	// Best-effort: endpoint shape may vary in your backend.
	// If your API expects something else, adjust here.
	if (!hash) return;
	if (!confirm(`Delete schedule for feature: ${hash}?`)) return;

	const token = getAccessToken();
	const headers = buildJsonAuthHeaders(token);

	const res = await fetch(`/schedules/${encodeURIComponent(hash)}`, {
		method: "DELETE",
		credentials: "include",
		headers
	});

	if (!res.ok) {
		console.error("Delete schedule failed:", res.status);
		alert(`Delete failed: HTTP ${res.status}`);
		return;
	}

	await updateSchedulesTable({});
}

function cloneSchedule(hash) {
	// UI convenience: if scheduler form exists, prefill featureCid.
	if (!hash) return;
	const el = document.querySelector("#featureCid");
	if (el) {
		el.value = hash;
		el.focus();
	}
	alert("Cloned feature hash into scheduler form.");
}

export async function updateSchedulesTable(opts = {}) {
	const token = getAccessToken();
	const headers = buildJsonAuthHeaders(token);

	const request = {
		method: "GET",
		credentials: "include",
		headers
	};

	const response = await fetch("/schedules/", request);
	let data = {};
	if (response.status === 200) {
		data = await response.json();
	} else if (response.status === 401) {
		try {
			if (typeof MicroModal !== "undefined") MicroModal.show("login-modal");
		} catch (_) {}
		return;
	} else {
		console.error("Error schedules fetching failed: ", response);
		return;
	}

	if (!(data && data.status === "ok")) return;

	const schedulesDiv = document.getElementById("schedules");
	if (!schedulesDiv) return;

	const table = document.createElement("table");
	const headerRow = document.createElement("tr");
	const cols = [
		"Delete",
		"Clone",
		"Feature Title",
		"CronSpec",
		"Created Time",
		"Last Excution",
		"Execution Counter",
		"Concurrency",
		"Feature Hash",
		"Contract Address"
	];

	cols.forEach((h) => {
		const th = document.createElement("th");
		th.textContent = h;
		headerRow.appendChild(th);
	});
	table.appendChild(headerRow);

	// Reverse sort by created time
	data.results.sort((a, b) => new Date(b.created) - new Date(a.created));

	// Render rows with placeholders, then enrich Feature Title asynchronously.
	for (const obj of data.results) {
		const row = document.createElement("tr");

		const props = [
			"delete",
			"clone",
			"feature_title",
			"cronspec",
			"created",
			"last_execution_timestamp",
			"execution_counter",
			"concurrency",
			"hash",
			"contract_address"
		];

		const cells = props.map((prop) => {
			const td = document.createElement("td");
			// Feature title placeholder: show hash until we fetch first line
			const v = prop === "feature_title" ? (obj.feature_title || obj.hash || "…") : obj[prop];
			const cell = formatCell(obj, td, v, prop);

			// Mark the feature_title cell so we can update it
			if (prop === "feature_title") {
				cell.dataset.featureHash = obj.hash || "";
			}
			return cell;
		});

		cells.forEach((c) => row.appendChild(c));
		table.appendChild(row);
	}

	schedulesDiv.innerHTML = "";
	schedulesDiv.appendChild(table);

	// Enrich Feature Title cells with first-line fetched from /features/<hash>, cached with TTL
	const titleCells = schedulesDiv.querySelectorAll("td.feature_title[data-feature-hash]");
	for (const td of titleCells) {
		const h = td.dataset.featureHash;
		if (!h) continue;

		// If already cached, this returns fast
		const firstLine = await fetchFeatureFirstLine(h, headers);

		// Update link text only (keep link destination)
		const a = td.querySelector("a");
		if (a) {
			a.href = `/features/${encodeURIComponent(h)}`;
			a.textContent = firstLine;
		} else {
			td.textContent = firstLine;
		}
	}
}

//////////////////////////////
// Scheduler UI (merged)
//////////////////////////////

export function initDamageScheduler(config = {}) {
	const defaults = {
		apiBase: "/schedules",
		ipfsGateway: window.origin + "/ipfs",
		defaultConcurrency: 1,
		containerSelector: "#schedules-tab #schedules"
	};
	const opts = { ...defaults, ...config };

	// create UI root if missing
	let root = document.querySelector(opts.containerSelector);
	if (!root) {
		root = document.createElement("div");
		root.id = "schedules";
		document.body.appendChild(root);
	}

	const listEl = root.querySelector("#scheduleList");

	// If there is a schedules table container, update it. Otherwise fallback to scheduleList.
	async function refreshSchedulesView() {
		const schedulesDiv = document.getElementById("schedules");
		if (schedulesDiv) {
			await updateSchedulesTable({ apiBase: opts.apiBase });
			return;
		}
		// fallback: dump json
		const token = getAccessToken();
		const headers = buildJsonAuthHeaders(token);
		const r = await fetch(opts.apiBase, { headers, credentials: "include" });
		const data = await r.json();
		if (listEl) listEl.innerHTML = `<pre>${JSON.stringify(data, null, 2)}</pre>`;
	}

	// Schedule field toggle and generation
	window.toggleScheduleFields = function () {
		const frequency = root.querySelector("#scheduleFrequency")?.value;
		const weeklyFields = root.querySelector("#weeklyFields");
		const monthlyFields = root.querySelector("#monthlyFields");
		const datetimeFields = root.querySelector("#datetimeFields");
		const scheduleDate = root.querySelector("#scheduleDate");
		const scheduleTime = root.querySelector("#scheduleTime");

		if (!frequency) return;

		// Hide all optional fields first
		if (weeklyFields) weeklyFields.style.display = "none";
		if (monthlyFields) monthlyFields.style.display = "none";

		// Show relevant fields based on frequency
		if (frequency === "weekly") {
			if (weeklyFields) weeklyFields.style.display = "block";
			if (datetimeFields) datetimeFields.style.display = "block";
			if (scheduleDate) scheduleDate.required = false;
			if (scheduleTime) scheduleTime.required = true;
		} else if (frequency === "monthly") {
			if (monthlyFields) monthlyFields.style.display = "block";
			if (datetimeFields) datetimeFields.style.display = "block";
			if (scheduleDate) scheduleDate.required = false;
			if (scheduleTime) scheduleTime.required = true;
		} else if (frequency === "daily") {
			if (datetimeFields) datetimeFields.style.display = "block";
			if (scheduleDate) scheduleDate.required = false;
			if (scheduleTime) scheduleTime.required = true;
		} else if (frequency === "once") {
			if (datetimeFields) datetimeFields.style.display = "block";
			if (scheduleDate) scheduleDate.required = true;
			if (scheduleTime) scheduleTime.required = true;
		} else {
			if (datetimeFields) datetimeFields.style.display = "none";
		}

		generateScheduleString(root);
	};

	function generateScheduleString(rootNode) {
		const frequency = rootNode.querySelector("#scheduleFrequency")?.value;
		const date = rootNode.querySelector("#scheduleDate")?.value;
		const time = rootNode.querySelector("#scheduleTime")?.value;
		const dayOfWeek = rootNode.querySelector("#scheduleDayOfWeek")?.value;
		const dayOfMonth = rootNode.querySelector("#scheduleDayOfMonth")?.value;
		const scheduleSpecInput = rootNode.querySelector("#scheduleSpec");

		if (!scheduleSpecInput) return;

		if (!frequency) {
			scheduleSpecInput.value = "";
			return;
		}

		let scheduleString = "";

		switch (frequency) {
			case "once":
				if (date && time) scheduleString = `once/${date}/${time}`;
				break;
			case "daily":
				if (time) {
					const [hours, minutes] = time.split(":");
					scheduleString = `daily/${hours}:${minutes}`;
				}
				break;
			case "weekly":
				if (time && dayOfWeek) {
					const [hours, minutes] = time.split(":");
					scheduleString = `weekly/${dayOfWeek}/${hours}:${minutes}`;
				}
				break;
			case "monthly":
				if (time && dayOfMonth) {
					const [hours, minutes] = time.split(":");
					scheduleString = `monthly/${dayOfMonth}/${hours}:${minutes}`;
				}
				break;
		}

		scheduleSpecInput.value = scheduleString;
	}

	// Wire schedule input changes (if present)
	const scheduleInputs = root.querySelectorAll(
		"#scheduleDate, #scheduleTime, #scheduleDayOfWeek, #scheduleDayOfMonth"
	);
	scheduleInputs.forEach((input) => input.addEventListener("change", () => generateScheduleString(root)));

	// initial load
	refreshSchedulesView().catch(console.error);

	return { refresh: refreshSchedulesView };
}

// auto-init if loaded directly as a <script type="module">
if (typeof window !== "undefined") {
	window.addEventListener("DOMContentLoaded", () => {
		const DamageSchedulerConfig = {
			apiBase: "/schedules",
			ipfsGateway: window.origin + "/ipfs"
		};
		initDamageScheduler(DamageSchedulerConfig || {});
	});
}

