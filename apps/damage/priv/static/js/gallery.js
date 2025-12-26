(function () {
	"use strict";

	// Mainnet MDW
	const MDW_BASE = "https://mainnet.aeternity.io/mdw";

	// Default node address (replace with your actual node / operator address)
	const DEFAULT_NODE_ADDRESS = "ak_2NgBkrcLxww49XuJAEa4sA3WFb6c3TbcinDptJGuwxyFRtWWwp";

	// If your app already knows the connected wallet address, expose it:
	// window.getConnectedAeAddress = async () => "ak_....";
	async function getConnectedWalletAddress() {

		return window.TokenManager.getAddress();
	}

	const qs = (s, r=document) => r.querySelector(s);
	const addrTagsEl = () => qs("#addrTags");
	const statusEl = () => qs("#nftStatus");

	function setStatus(msg){ statusEl().textContent = msg || ""; }

	function normalizeImageUrl(u) {
		if (!u || typeof u !== "string") return null;
		if (u.startsWith("ipfs://")) return "https://ipfs.io/ipfs/" + u.slice("ipfs://".length);
		return u;
	}

	function pickMeta(token) {
		const md = token?.metadata || token?.meta || token?.token_metadata || {};
		const name = md.name || token?.name || token?.token_name || token?.token_id || token?.tokenId || "Untitled";
		const desc = md.description || token?.description || md.desc || "—";
		const image = normalizeImageUrl(md.image || md.image_url || md.imageUrl || token?.image || null);
		const contract = token?.contract_id || token?.contractId || token?.contract || token?.contract_address;
		const tokenId = token?.token_id || token?.tokenId || token?.token || token?.id;
		return { name, desc, image, contract, tokenId };
	}

	async function fetchJSON(url) {
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
		if (!res.ok) throw new Error(`HTTP ${res.status}`);
		return res.json();
	}

	async function loadAllOwnedAex141(owner, { limit=50, maxPages=8 } = {}) {
		let url = `${MDW_BASE}/v3/accounts/${encodeURIComponent(owner)}/aex141/tokens?limit=${encodeURIComponent(limit)}`;
		const out = [];
		for (let i = 0; i < maxPages && url; i++) {
			const page = await fetchJSON(url);
			const items = Array.isArray(page?.data) ? page.data
                  : Array.isArray(page?.tokens) ? page.tokens
                  : Array.isArray(page) ? page
                  : [];
			out.push(...items);

			const nextPath = page?.next;
			if (typeof nextPath === "string" && nextPath.startsWith("/")) url = MDW_BASE + nextPath;
			else url = null;
		}
		return out;
	}

	function renderCards(rows) {
		const grid = qs("#nftGrid");
		grid.innerHTML = "";

		if (!rows.length) {
			grid.innerHTML = `<div style="color:#9aa3b2; padding:.75rem 0;">No AEX-141 tokens found.</div>`;
			return;
		}

		for (const row of rows) {
			const t = row.token;
			const owner = row.owner;
			const { name, desc, image, contract, tokenId } = pickMeta(t);

			const card = document.createElement("article");
			card.className = "nft-card";

			const thumb = document.createElement("div");
			thumb.className = "nft-thumb";
			if (image) {
				const img = document.createElement("img");
				img.alt = name;
				img.loading = "lazy";
				img.src = image;
				thumb.appendChild(img);
			} else {
				const no = document.createElement("div");
				no.style.color = "#9aa3b2";
				no.style.fontSize = ".9rem";
				no.textContent = "No image";
				thumb.appendChild(no);
			}

			const body = document.createElement("div");
			body.className = "nft-body";

			const title = document.createElement("div");
			title.className = "nft-title";
			title.textContent = name;

			const d = document.createElement("div");
			d.className = "nft-desc";
			d.textContent = desc;

			const meta = document.createElement("div");
			meta.className = "nft-meta";

			const ownerPill = document.createElement("span");
			ownerPill.className = "pill";
			ownerPill.title = owner;
			ownerPill.textContent = `ak… ${String(owner).slice(-8)}`;
			meta.appendChild(ownerPill);

			if (contract) {
				const p = document.createElement("span");
				p.className = "pill";
				p.title = contract;
				p.textContent = `ct… ${String(contract).slice(-8)}`;
				meta.appendChild(p);
			}
			if (tokenId !== undefined && tokenId !== null) {
				const p = document.createElement("span");
				p.className = "pill";
				p.textContent = `#${tokenId}`;
				meta.appendChild(p);
			}

			body.appendChild(title);
			body.appendChild(d);
			body.appendChild(meta);

			card.appendChild(thumb);
			card.appendChild(body);
			qs("#nftGrid").appendChild(card);
		}
	}

	// --- Tag filter model ---
	// tags: { addr, label, selected, locked }
	const tags = [];
	const tagIndex = new Map(); // addr -> tag

	function isValidAk(a){ return typeof a === "string" && /^ak_[A-Za-z0-9]+$/.test(a.trim()); }

	function addTag(addr, { label=null, selected=false, locked=false } = {}) {
		addr = String(addr || "").trim();
		if (!isValidAk(addr)) return { ok: false, reason: "Invalid ak_ address" };

		if (tagIndex.has(addr)) {
			const t = tagIndex.get(addr);
			if (label && !t.label) t.label = label;
			if (selected) t.selected = true;
			renderTags();
			return { ok: true, existed: true };
		}

		const t = { addr, label: label || "", selected: !!selected, locked: !!locked };
		tags.push(t);
		tagIndex.set(addr, t);
		renderTags();
		return { ok: true, existed: false };
	}

	function removeTag(addr) {
		const t = tagIndex.get(addr);
		if (!t || t.locked) return;
		tagIndex.delete(addr);
		const idx = tags.findIndex(x => x.addr === addr);
		if (idx >= 0) tags.splice(idx, 1);
		renderTags();
	}

	function toggleTag(addr) {
		const t = tagIndex.get(addr);
		if (!t) return;
		t.selected = !t.selected;
		renderTags();
	}

	function clearSelection() {
		for (const t of tags) if (!t.locked) t.selected = false;
		// keep locked ones selected
		for (const t of tags) if (t.locked) t.selected = true;
		renderTags();
	}

	function getSelectedAddrs() {
		return tags.filter(t => t.selected).map(t => t.addr);
	}

	function shortAk(addr){ return addr.slice(0, 6) + "…" + addr.slice(-6); }

	function renderTags() {
		const host = addrTagsEl();
		host.innerHTML = "";

		for (const t of tags) {
			const tag = document.createElement("button");
			tag.type = "button";
			tag.className = "addr-tag";
			tag.setAttribute("aria-pressed", t.selected ? "true" : "false");
			tag.title = t.addr;

			const label = document.createElement("span");
			label.className = "addr-tag__label";
			label.textContent = t.label ? t.label : "Address";

			const addr = document.createElement("span");
			addr.className = "addr-tag__addr";
			addr.textContent = shortAk(t.addr);

			tag.appendChild(label);
			tag.appendChild(addr);

			if (!t.locked) {
				const x = document.createElement("span");
				x.className = "addr-tag__x";
				x.textContent = "×";
				x.title = "Remove address";
				x.addEventListener("click", (e) => { e.stopPropagation(); removeTag(t.addr); });
				tag.appendChild(x);
			}

			tag.addEventListener("click", () => toggleTag(t.addr));
			host.appendChild(tag);
		}
	}

	// --- UI actions ---
	function setBusy(isBusy) {
		const btn = qs("#loadNftsBtn");
		btn.disabled = isBusy;
		btn.textContent = isBusy ? "Loading…" : "Load NFTs";
		qs("#addrAddBtn").disabled = isBusy;
		qs("#clearBtn").disabled = isBusy;
	}

	async function onLoadNfts() {
		const addrs = getSelectedAddrs();
		qs("#nftGrid").innerHTML = "";
		if (!addrs.length) { setStatus("Select at least one address tag."); return; }

		setBusy(true);
		setStatus(`Fetching AEX-141 tokens for ${addrs.length} address(es)…`);

		try {
			const rows = [];
			let total = 0;

			for (const a of addrs) {
				const tokens = await loadAllOwnedAex141(a);
				total += tokens.length;
				for (const t of tokens) rows.push({ owner: a, token: t });
			}

			renderCards(rows);
			setStatus(`Loaded ${total} token(s) from ${addrs.length} address(es).`);
		} catch (e) {
			setStatus(`Failed to load NFTs: ${e && e.message ? e.message : String(e)}`);
		} finally {
			setBusy(false);
		}
	}

	function onAddAddress() {
		const input = qs("#addrInput");
		const addr = (input.value || "").trim();
		if (!isValidAk(addr)) { setStatus("Invalid address. Must start with ak_."); return; }
		addTag(addr, { label: "Custom", selected: true, locked: false });
		input.value = "";
		setStatus(`Added ${addr}`);
	}

	function wireAddInput() {
		const input = qs("#addrInput");
		input.addEventListener("keydown", (e) => {
			if (e.key === "Enter") { e.preventDefault(); onAddAddress(); }
		});
		qs("#addrAddBtn").addEventListener("click", onAddAddress);
	}

	// --- init defaults: current wallet + node address selected ---
	async function initDefaults() {
		// Node address default
		if (isValidAk(DEFAULT_NODE_ADDRESS)) {
			addTag(DEFAULT_NODE_ADDRESS, { label: "Node", selected: true, locked: true });
		} else {
			// leave a visible hint if not set
			setStatus("Note: set DEFAULT_NODE_ADDRESS in the snippet to auto-select your node address.");
		}

		// Connected wallet default (selected)
		const wallet = await getConnectedWalletAddress();
		if (wallet && isValidAk(wallet)) {
			addTag(wallet, { label: "Wallet", selected: true, locked: true });
		} else {
			// Not fatal, just inform
			setStatus("Wallet not detected. Add an address or expose window.getConnectedAeAddress().");
		}
	}

	function init() {
		wireAddInput();
		qs("#loadNftsBtn").addEventListener("click", onLoadNfts);
		qs("#clearBtn").addEventListener("click", clearSelection);
		renderTags();
		initDefaults().catch(() => {});
	}

	init();
})();
