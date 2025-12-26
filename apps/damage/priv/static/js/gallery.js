(function () {
  "use strict";

  const MDW_BASE = "https://mainnet.aeternity.io/mdw";

  // ---- known addresses (mainnet) ----
  // Replace these with your real list (or populate from your server).
  const KNOWN_ADDRESSES = [
      "ak_2NgBkrcLxww49XuJAEa4sA3WFb6c3TbcinDptJGuwxyFRtWWwp",
    // "ak_....",
  ];

  const qs = (s, r=document) => r.querySelector(s);

  function setStatus(msg){ qs("#nftStatus").textContent = msg || ""; }

  function normalizeImageUrl(u) {
    if (!u || typeof u !== "string") return null;
    if (u.startsWith("ipfs://")) return "https://ipfs.io/ipfs/" + u.slice("ipfs://".length);
    return u;
  }

  function pickMeta(token) {
    const md = token?.metadata || token?.meta || token?.token_metadata || {};
    const name =
      md.name || token?.name || token?.token_name || token?.token_id || token?.tokenId || "Untitled";
    const desc =
      md.description || token?.description || md.desc || "—";
    const image =
      normalizeImageUrl(md.image || md.image_url || md.imageUrl || token?.image || null);

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
    // MDW v3: /accounts/{accountId}/aex141/tokens
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

  function getSelectedAddresses() {
    const sel = qs("#nftAddresses");
    return Array.from(sel.selectedOptions).map(o => o.value).filter(Boolean);
  }

  function addAddressOption(addr, { selected=false, label=null } = {}) {
    const sel = qs("#nftAddresses");
    const existing = Array.from(sel.options).find(o => o.value === addr);
    if (existing) { existing.selected = existing.selected || selected; return; }
    const opt = document.createElement("option");
    opt.value = addr;
    opt.textContent = label ? label : addr;
    opt.selected = !!selected;
    sel.appendChild(opt);
  }

  // ---- connected wallet address detection ----
  async function getConnectedWalletAddress() {
	  window.TokenManager.getAddress();
  }

  async function onUseConnected() {
    const addr = await getConnectedWalletAddress();
    if (!addr) { setStatus("No connected wallet address detected."); return; }
    addAddressOption(addr, { selected: true, label: `Connected: ${addr}` });
    setStatus(`Connected wallet: ${addr}`);
  }

  async function onLoadNfts() {
    const addrs = getSelectedAddresses();
    qs("#nftGrid").innerHTML = "";
    if (!addrs.length) { setStatus("Select at least one address."); return; }

    const btn = qs("#loadNftsBtn");
    btn.disabled = true;
    btn.textContent = "Loading…";
    setStatus(`Fetching AEX-141 tokens for ${addrs.length} address(es)…`);

    try {
      // Fetch sequentially (minimal JS + avoids hammering MDW)
      const rows = [];
      let total = 0;

      for (const a of addrs) {
        if (!a.startsWith("ak_")) continue;
        const tokens = await loadAllOwnedAex141(a);
        total += tokens.length;
        for (const t of tokens) rows.push({ owner: a, token: t });
      }

      renderCards(rows);
      setStatus(`Loaded ${total} token(s) from ${addrs.length} address(es).`);
    } catch (e) {
      setStatus(`Failed to load NFTs: ${e && e.message ? e.message : String(e)}`);
    } finally {
      btn.disabled = false;
      btn.textContent = "Load NFTs";
    }
  }

  function init() {
    // Populate known addresses
    for (const a of KNOWN_ADDRESSES) {
      if (typeof a === "string" && a.startsWith("ak_")) addAddressOption(a, { selected: false });
    }

    qs("#useConnectedBtn").addEventListener("click", onUseConnected);
    qs("#loadNftsBtn").addEventListener("click", onLoadNfts);

    // nice default: try to auto-add connected wallet silently
    onUseConnected().catch(()=>{});
  }

  init();
})();
